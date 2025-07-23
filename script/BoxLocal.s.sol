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
import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";

import {VaultV2Lib} from "../src/lib/VaultV2Lib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {MorphoVaultV1AdapterLib} from "../src/lib/MorphoVaultV1Lib.sol";



contract MockSwapper is ISwapper {
    uint256 public slippagePercent = 0; // 0% slippage by default
    bool public shouldRevert = false;

    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {
    }
}

contract BoxLocalScript is Script {
  using BoxLib for Box;
    using VaultV2Lib for VaultV2;
    using MorphoVaultV1AdapterLib for MorphoVaultV1Adapter;
    
    VaultV2 vault;
    Box box1;
    Box box2;
    MorphoVaultV1Adapter adapter1;
    MorphoVaultV1Adapter adapter2;
    MorphoVaultV1Adapter bbqusdcAdapter;

    address owner = address(0xfeed8591997D831f89BAF1089090918E669796C9);
    address curator = address(0xfeed8591997D831f89BAF1089090918E669796C9);
    address guardian = address(0xfeed8591997D831f89BAF1089090918E669796C9);
    address allocator = address(0xfeed8591997D831f89BAF1089090918E669796C9);
    address user = address(0xfeed8591997D831f89BAF1089090918E669796C9);

    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IERC4626 bbqusdc = IERC4626(0xBEeFFF209270748ddd194831b3fa287a5386f5bC); // bbqUSDC on Base
    
    IERC4626 stusd = IERC4626(0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776);
    IOracle stusdOracle = IOracle(0xd884fa9fe289EB06Cc22667252fA6Bea87A91CC3);
    
    IERC20 ptsusdejul = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptsusdejulOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);
    
    ISwapper swapper = ISwapper(0xCd0066EC3f96Afe3f6015539D16DeF2cE648Ab77);

    /// @notice Will setup Peaty Base investing in bbqUSDC, box1 (stUSD) and box2 (PTs)
   function setUp() public {
        // Fork base on June 12th, 2025
        uint256 forkId = vm.createFork(vm.rpcUrl("local"));
        vm.selectFork(forkId);
        vm.startBroadcast();

        bytes memory data;

        MockSwapper backupSwapper = new MockSwapper();

        vault = new VaultV2(address(owner), address(usdc));

        console.log("Vault address: ", address(vault));

        vault.setCurator(address(curator));
    
        vault.addAllocator(address(allocator)); 

        // Setting the vault to use bbqUSDC as the asset
        bbqusdcAdapter = new MorphoVaultV1Adapter(
            address(vault), 
            address(bbqusdc)
        );

        vault.addCollateral(address(bbqusdcAdapter), bbqusdcAdapter.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 100% relative cap


        vault.setLiquidityAdapterAndData(address(bbqusdcAdapter), "");

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
        adapter1 = new MorphoVaultV1Adapter(
            address(vault), 
            address(box1)
        );

        // Allow box 1 to invest in stUSD
        box1.addCollateral(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator), true);
        box1.addFeeder(address(adapter1));
        vault.addCollateral(address(adapter1), adapter1.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap



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
        adapter2 = new MorphoVaultV1Adapter(
            address(vault), 
            address(box2)
        );

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addCollateral(ptsusdejul, ptsusdejulOracle);
        box2.setIsAllocator(address(allocator), true);
        box2.addFeeder(address(adapter2));
        vault.addCollateral(address(adapter2), adapter2.data(), 1_000_000 * 10**6, 0.5 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vault.setPenaltyFee(address(adapter2), 0.02 ether); // 2% penalty

        vm.stopBroadcast();
    }
    
    function run() public {

        vm.startBroadcast();

        uint256 _10 = 10 * 10**6;
        uint256 _5 = 5 * 10**6;


        // Depositing 1000 USDC into the vault
        usdc.approve(address(vault), _10); // Approve the vault to spend USDC
        vault.deposit(_10, address(user)); // Deposit 1000 USDC into the vault
        console.log(box1.totalAssets());

        // Allocating 1000 USDC to the box1
        vault.deallocate(address(bbqusdcAdapter), "", _10 - 1);
        vault.allocate(address(adapter1), "", _5 -1);
        vault.allocate(address(adapter2), "", _5 -1);
        console.log(box1.totalAssets());


        vm.stopBroadcast();
        
    }
}
