// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Box} from "../src/Box.sol";
import {IBox, IBoxFlashCallback} from "../src/interfaces/IBox.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import "../src/libraries/Constants.sol";

/**
 * @title FlashLoanSlippageTest
 * @notice Test to verify or refute the C-1 audit claim about flash loan slippage bypass
 */
contract FlashLoanSlippageTest is Test {
    Box public box;
    ERC20MockDecimals public asset;
    ERC20MockDecimals public token;
    MockOracle public oracle;
    MockSwapper public swapper;

    address public owner = address(0x1);
    address public curator = address(0x2);
    address public allocator = address(0x3);

    function setUp() public {
        // Deploy tokens
        asset = new ERC20MockDecimals(6);
        token = new ERC20MockDecimals(18);

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(1e36); // 1:1 price

        // Deploy box
        vm.prank(owner);
        box = new Box(
            address(asset),
            owner,
            curator,
            "Box",
            "BOX",
            0.01 ether, // 1% max slippage
            1 days, // slippage epoch
            7 days, // shutdown slippage duration
            1 days // shutdown warmup
        );

        // Setup box
        vm.startPrank(curator);
        bytes memory addTokenData = abi.encodeWithSelector(Box.addToken.selector, token, oracle);
        box.submit(addTokenData);
        vm.warp(block.timestamp + 1);
        box.addToken(token, oracle);

        box.setIsAllocator(allocator, true);
        vm.stopPrank();

        // Deploy swapper
        swapper = new MockSwapper();

        // Mint tokens
        asset.mint(address(this), 10_000_000e6); // 10M USDC
        token.mint(address(swapper), 10_000_000e18); // 10M tokens
        asset.mint(address(swapper), 10_000_000e6);
    }

    /**
     * @notice Test the claimed flash loan slippage bypass vulnerability
     *
     * AUDIT CLAIM (C-1):
     * "Flash loan caches NAV at beginning of flash operation. This creates a
     * vulnerability where an attacker can:
     * 1. Call flash() which caches the current NAV
     * 2. During callback, call allocate() which uses _navForSlippage()
     * 3. _navForSlippage() returns the cached (smaller) NAV
     * 4. Slippage is calculated as % of old NAV, not current NAV
     * 5. This allows extracting more value through slippage tolerance"
     *
     * Let's test if this is actually true.
     */
    function testFlashLoanSlippageClaim() public {
        console2.log("=== Testing Flash Loan Slippage Bypass Claim ===");
        console2.log("");

        // Setup: Deposit 1M USDC into box
        vm.startPrank(curator);
        bytes memory setFeederData = abi.encodeWithSelector(Box.setIsFeeder.selector, owner, true);
        box.submit(setFeederData);
        vm.warp(block.timestamp + 1);
        box.setIsFeeder(owner, true);
        vm.stopPrank();

        // Transfer tokens to owner
        asset.transfer(owner, 1_000_000e6);

        vm.startPrank(owner);
        asset.approve(address(box), 1_000_000e6);
        box.deposit(1_000_000e6, owner);
        vm.stopPrank();

        console2.log("Initial NAV:", box.totalAssets());
        console2.log("Initial slippage accumulated:", box.accumulatedSlippage());

        // Now let's try the attack as described
        FlashAttacker attacker = new FlashAttacker(box, asset, token, swapper);

        // Give attacker 9M USDC for flash loan
        asset.mint(address(attacker), 9_000_000e6);

        // Attacker attempts to exploit
        vm.prank(curator);
        box.setIsAllocator(address(attacker), true);

        console2.log("");
        console2.log("Attempting flash loan attack...");

        vm.prank(address(attacker));
        try attacker.attack() {
            console2.log("Attack executed");

            console2.log("");
            console2.log("Post-attack NAV:", box.totalAssets());
            console2.log("Post-attack slippage:", box.accumulatedSlippage());

            // Check if slippage was bypassed
            // With 1% max slippage on 1M NAV = 10k max loss
            // If attack worked, we'd see 10k loss on what should be 10M NAV
            // But let's see what actually happens...
        } catch Error(string memory reason) {
            console2.log("Attack FAILED with reason:", reason);
            console2.log("");
            console2.log("This suggests the vulnerability may not exist as described");
        } catch {
            console2.log("Attack FAILED with unknown error");
        }
    }

    /**
     * @notice Analyze what actually happens with flash loan NAV caching
     */
    function testActualFlashLoanBehavior() public {
        console2.log("=== Analyzing Actual Flash Loan Behavior ===");
        console2.log("");

        // Let's trace through what ACTUALLY happens in the code:
        console2.log("Code Flow in Box.flash():");
        console2.log("1. _cachedNavForFlash = _nav()  <- Caches CURRENT nav");
        console2.log("2. _isInFlash = true");
        console2.log("3. flashToken.safeTransferFrom(msg.sender, address(this), amount)");
        console2.log("   ^ This INCREASES box balance");
        console2.log("4. callback to msg.sender");
        console2.log("5. flashToken.safeTransfer(msg.sender, amount)");
        console2.log("   ^ This DECREASES box balance back");
        console2.log("6. _isInFlash = false");
        console2.log("");

        console2.log("Issue with audit claim:");
        console2.log("- Audit says: 'flashToken.safeTransferFrom increases NAV'");
        console2.log("- Audit says: 'But _cachedNavForFlash was set BEFORE transfer'");
        console2.log("");
        console2.log("Reality check:");
        console2.log("- Step 1: NAV = 1M, cache = 1M");
        console2.log("- Step 3: Transfer 9M in, balance = 10M");
        console2.log("- During callback: _navForSlippage() returns 1M (cached)");
        console2.log("- But _nav() would revert due to _isInFlash check!");
        console2.log("");
        console2.log("Key insight: _nav() reverts during flash:");
        console2.log("  require(_isInFlash == false, ErrorsLib.NoNavDuringFlash())");
        console2.log("");
        console2.log("So slippage calculation uses _navForSlippage() which:");
        console2.log("  return _isInFlash ? _cachedNavForFlash : _nav()");
        console2.log("");
        console2.log("Question: Is the cached NAV from BEFORE the flash transfer?");
        console2.log("Answer: YES - that's the bug!");
        console2.log("");
        console2.log("The vulnerability IS REAL if:");
        console2.log("- Flash loan transfers tokens TO box");
        console2.log("- Callback can call allocate/deallocate");
        console2.log("- Slippage % is calculated against OLD nav");
        console2.log("");
        console2.log("Let's verify with actual test...");
    }
}

contract FlashAttacker is IBoxFlashCallback {
    Box public box;
    IERC20 public asset;
    IERC20 public token;
    MockSwapper public swapper;

    constructor(Box _box, IERC20 _asset, IERC20 _token, MockSwapper _swapper) {
        box = _box;
        asset = _asset;
        token = _token;
        swapper = _swapper;
    }

    function attack() external {
        // Flash loan 9M USDC from myself to the box
        asset.approve(address(box), 9_000_000e6);

        // Call flash
        bytes memory data = "";
        box.flash(asset, 9_000_000e6, data);
    }

    function onBoxFlash(IERC20, uint256, bytes calldata) external {
        console2.log("");
        console2.log("  [Inside flash callback]");

        // Now box has 10M USDC (1M original + 9M flash)
        // But _navForSlippage() will return 1M (cached before transfer)

        // Try to allocate 100k USDC to token
        // With 1% slippage on 1M = 10k allowed
        // With 1% slippage on 10M = 100k allowed
        // Let's see which applies...

        uint256 allocAmount = 100_000e6;
        asset.approve(address(box), allocAmount);

        console2.log("  Attempting to allocate with inflated slippage...");
        console2.log("  Amount:", allocAmount);
        console2.log("  Expected slippage limit on 1M NAV:", uint256(1_000_000e6 / 100));
        console2.log("  Expected slippage limit on 10M NAV:", uint256(10_000_000e6 / 100));

        try box.allocate(token, allocAmount, ISwapper(address(swapper)), "") {
            console2.log("  Allocate succeeded!");
        } catch Error(string memory reason) {
            console2.log("  Allocate failed:", reason);
        }
    }
}

contract MockOracle is IOracle {
    uint256 public price = 1e36;

    function setPrice(uint256 _price) external {
        price = _price;
    }
}

contract MockSwapper is ISwapper {
    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata) external {
        // Simple 1:1 swap with scaling for decimals
        input.transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn;
        // Scale for decimals if needed
        if (address(output) != address(input)) {
            // Assume input is 6 decimals (USDC) and output is 18 decimals (token)
            amountOut = amountIn * 1e12; // Scale up
        }

        output.transfer(msg.sender, amountOut);
    }
}
