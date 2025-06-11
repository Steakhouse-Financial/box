// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Box} from "../src/Box.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Errors} from "../src/lib/Errors.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";



contract MockSwapper is ISwapper {
    uint256 public slippagePercent = 0; // 0% slippage by default
    bool public shouldRevert = false;


    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {
    }
}

contract BoxScript is Script {
    
    VaultV2 vault;
    Box box1;
    ERC4626Adapter adapter1;

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // Base USDC address

    function setUp() public {
        uint256 forkId = vm.createFork("https://base-mainnet.g.alchemy.com/v2/nvuF54jCao6X3HeZr7h4qGFv-YoFKOoC");
        vm.selectFork(forkId);

        bytes memory data;

        MockSwapper backupSwapper = new MockSwapper();

        vault = new VaultV2(address(this), address(usdc));

        string memory name = "BoxA";
        string memory symbol = "BOXA";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        uint256[5] memory timelockDurations = [
            uint256(0 days), // setMaxSlippage
            uint256(0 days), // addInvestmentToken
            uint256(0 days), // removeInvestmentToken
            uint256(0 days), // setIsAllocator
            uint256(0 days)  // setIsFeeder
        ];
        box1 = new Box(
            usdc, 
            backupSwapper, 
            address(this), 
            address(this), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            timelockDurations
        );

        adapter1 = new ERC4626Adapter(
            address(vault), 
            address(box1)
        );
        data = abi.encodeWithSelector(
            box1.setIsFeeder.selector,
            address(adapter1),
            true
        );
        box1.submit(data);
        box1.setIsFeeder(address(adapter1), true);

        vault.setCurator(address(this));

        data = abi.encodeWithSelector(
            vault.setIsAllocator.selector,
            address(this),
            true
        );
        vault.submit(data);
        vault.setIsAllocator(address(this), true);

        data = abi.encodeWithSelector(
            vault.setIsAdapter.selector,
            address(adapter1),
            true
        );
        vault.submit(data);
        vault.setIsAdapter(address(adapter1), true);

        data = abi.encodeWithSelector(
            vault.increaseAbsoluteCap.selector,
            adapter1.data(),
            100_000 * 10**18 // 100,000 USDC
        );
        vault.submit(data);
        vault.increaseAbsoluteCap(adapter1.data(), 100_000 * 10**18);


        data = abi.encodeWithSelector(
            vault.increaseRelativeCap.selector, 
            adapter1.data(),
            1 ether // 100%
        );
        vault.submit(data);
        vault.increaseRelativeCap(adapter1.data(), 1 ether);
    }

    function run() public {
        uint256 _1000 = 1000 * 10**6;

        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(this), _1000); // Transfer 1000 USDC to this contract

        usdc.approve(address(vault), _1000); // Approve the vault to spend USDC
        vault.deposit(_1000, address(this)); // Deposit 1000 USDC into the vault


        console.log(box1.totalAssets());

        vault.allocate(address(adapter1), "", _1000);

        console.log(box1.totalAssets());
        
    }
}
