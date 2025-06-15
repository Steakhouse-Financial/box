// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Box} from "../src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Errors} from "../src/lib/Errors.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {MetaMorphoAdapter} from "@vault-v2/src/adapters/MetaMorphoAdapter.sol";

import {VaultV2Lib} from "../src/lib/VaultV2Lib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {MetaMorphoAdapterLib} from "../src/lib/MetaMorphoAdapterLib.sol";



contract MockSwapper is ISwapper {
    uint256 public slippagePercent = 0; // 0% slippage by default
    bool public shouldRevert = false;

    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {
    }
}

contract BoxScript is Script {
  using BoxLib for Box;
    using VaultV2Lib for VaultV2;
    using MetaMorphoAdapterLib for MetaMorphoAdapter;
    
    VaultV2 vault;
    Box box1;
    Box box2;
    MetaMorphoAdapter adapter1;
    MetaMorphoAdapter adapter2;
    MetaMorphoAdapter bbqusdcAdapter;

    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IERC4626 bbqusdc = IERC4626(0xBeeFa74640a5f7c28966cbA82466EED5609444E0); // bbqUSDC on Base
    
    IERC4626 stusd = IERC4626(0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776);
    IOracle stusdOracle = IOracle(0x2eede25066af6f5F2dfc695719dB239509f69915);
    
    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);
    
    ISwapper swapper = ISwapper(0xFFF5082CE0E7C04BCc645984A94d4e4C0687Aa60);

    /// @notice Will setup Peaty Base investing in bbqUSDC, box1 (stUSD) and box2 (PTs)
   function setUp() public {
        // Fork base on June 12th, 2025
        uint256 forkId = vm.createFork(vm.rpcUrl("base"), 31463931);
        vm.selectFork(forkId);

        bytes memory data;

        MockSwapper backupSwapper = new MockSwapper();

        vault = new VaultV2(address(owner), address(usdc));

        vm.prank(owner);
        vault.setCurator(address(curator));

        vm.prank(curator);
        vault.addAllocator(address(allocator)); 

        // Setting the vault to use bbqUSDC as the asset
        bbqusdcAdapter = new MetaMorphoAdapter(
            address(vault), 
            address(bbqusdc)
        );

        vm.startPrank(curator);
        vault.addCollateral(address(bbqusdcAdapter), bbqusdcAdapter.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 100% relative cap
        vm.stopPrank();

        vm.startPrank(allocator);
        vault.setLiquidityAdapter(address(bbqusdcAdapter));
        vault.setLiquidityData("");
        vm.stopPrank();

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box 1";
        string memory symbol = "BOX1";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        box1 = new Box(
            usdc, 
            address(owner), 
            address(curator), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );

        // Creating the ERC4626 adapter between the vault and box1
        adapter1 = new MetaMorphoAdapter(
            address(vault), 
            address(box1)
        );

        // Allow box 1 to invest in stUSD
        vm.startPrank(curator);
        box1.addCollateral(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator), true);
        box1.addFeeder(address(adapter1));
        vault.addCollateral(address(adapter1), adapter1.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vm.stopPrank();


        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box 2";
        symbol = "BOX2";
        maxSlippage = 0.01 ether; // 1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        box2 = new Box(
            usdc, 
            address(owner), 
            address(curator), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );
        // Creating the ERC4626 adapter between the vault and box2
        adapter2 = new MetaMorphoAdapter(
            address(vault), 
            address(box2)
        );

        // Allow box 2 to invest in PT-USR-25SEP
        vm.startPrank(curator);
        box2.addCollateral(ptusr25sep, ptusr25sepOracle);
        box2.setIsAllocator(address(allocator), true);
        box2.addFeeder(address(adapter2));
        vault.addCollateral(address(adapter2), adapter2.data(), 1_000_000 * 10**6, 0.5 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vault.setPenaltyFee(address(adapter2), 0.02 ether); // 2% penalty
        vm.stopPrank();
    }
    
    function run() public {
        uint256 _1000 = 1000 * 10**6;

        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(user), _1000); // Transfer 1000 USDC to this contract


        // Depositing 1000 USDC into the vault
        vm.startPrank(user);
        usdc.approve(address(vault), _1000); // Approve the vault to spend USDC
        vault.deposit(_1000, address(user)); // Deposit 1000 USDC into the vault
        console.log(box1.totalAssets());
        vm.stopPrank();

        // Allocating 1000 USDC to the box1
        vm.startPrank(allocator);
        vault.deallocate(address(bbqusdcAdapter), "", _1000 - 1);
        vault.allocate(address(adapter1), "", _1000 -1);
        console.log(box1.totalAssets());

        // Deallocating 1000 USDC from the box1
        // At this stage it wasn't invested so it is possible
        vault.deallocate(address(adapter1), "", _1000 -1);
        console.log(box1.totalAssets());


        // Alloctin 1000 USDC from the box1
        // And box 1 invest those in stUSD
        vault.allocate(address(adapter1), "", _1000 -1);
        box1.allocate(stusd, _1000 -1, swapper);

        console.log(box1.totalAssets());
        console.log(stusd.balanceOf(address(box1))); // Check stUSD balance after swap


        box1.deallocate(stusd, stusd.balanceOf(address(box1)), swapper);


        console.log(box1.totalAssets());
        console.log(usdc.balanceOf(address(box1))); // Check stUSD balance after swap


        vm.stopPrank();


        vm.startPrank(user);
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter1);
        bytes[] memory data = new bytes[](1);
        data[0] = "";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = box1.previewRedeem(box1.balanceOf(address(adapter1)));
        console.log("AMount that will be force deallocated");
        console.log(amounts[0]);
        vault.forceDeallocate(adapters, data, amounts, address(user));

        // doesn't work because vault is underwater due to rounding down
        //vault.redeem(vault.balanceOf(address(user)), address(user), address(user));

        console.log(usdc.balanceOf(address(user))); // Check stUSD balance after swap


        console.log(box1.totalAssets());
        console.log(usdc.balanceOf(address(box1))); // Check stUSD balance after swap
        vm.stopPrank();
        
    }
}
