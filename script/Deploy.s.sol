// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BoxFactory} from "../src/BoxFactory.sol";
import {BoxAdapterFactory} from "../src/BoxAdapterFactory.sol";
import {MorphoVaultV1AdapterFactory} from "@vault-v2/src/adapters/MorphoVaultV1AdapterFactory.sol";
import {VaultV2Factory} from "@vault-v2/src/VaultV2Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IBoxAdapter} from "../src/interfaces/IBoxAdapter.sol";
import {Box} from "../src/Box.sol";
import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";
import {MorphoVaultV1AdapterLib} from "../src/lib/MorphoVaultV1Lib.sol";
import {VaultV2Lib} from "../src/lib/VaultV2Lib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {BoxAdapterFactory} from "../src/BoxAdapterFactory.sol";
import {BoxAdapterCachedFactory} from "../src/BoxAdapterCachedFactory.sol";

///@dev This script deploys the necessary contracts for the Peaty product on Base.
///@dev Default factories are hardcoded, but can be overridden using run() which will deploy fresh contracts.
contract DeployScript is Script {
    using BoxLib for Box;
    using VaultV2Lib for VaultV2;
    using MorphoVaultV1AdapterLib for MorphoVaultV1Adapter;

    VaultV2Factory vaultV2Factory = VaultV2Factory(0xCe2BD9abD6b79A29ed6f9dB1eec34eCAE5D1296f);
    MorphoVaultV1AdapterFactory mv1AdapterFactory = MorphoVaultV1AdapterFactory(0xCdFc890791404841efC4685b8217E7f210fE1df4);
    BoxFactory boxFactory = BoxFactory(0xDE01B5644CA6b176a092BC9e6316634104fd89c5);
    BoxAdapterFactory boxAdapterFactory = BoxAdapterFactory(0x6cfdD0448A93D50A4A886f1ca14aef3b70D2E5E8);
    BoxAdapterCachedFactory boxAdapterCachedFactory = BoxAdapterCachedFactory(0xB14b4A86aC5b80A175e1d379bf360D7A79c7e37d);

    address owner = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address curator = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address guardian = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address allocator1 = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address allocator2 = address(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IERC4626 bbqusdc = IERC4626(0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F); // bbqUSDC on Base
    
    IERC4626 stusd = IERC4626(0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776);
    IOracle stusdOracle = IOracle(0x2eede25066af6f5F2dfc695719dB239509f69915);
    
    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);
    

    ///@dev This script deploys the necessary contracts for the Peaty product on Base.
    function run() public {
        vaultV2Factory = deployVaultV2Factory();
        mv1AdapterFactory = deployMorphoVaultV1AdapterFactory();
        boxFactory = deployBoxFactory();
        boxAdapterFactory = deployBoxAdapterFactory();
        boxAdapterCachedFactory = deployBoxAdapterCachedFactory();
    }

    function deployBoxFactory() public returns (BoxFactory) {
        vm.startBroadcast();
        BoxFactory boxFactory = new BoxFactory();
        console.log("BoxFactory deployed at:", address(boxFactory));
        vm.stopBroadcast();
        return boxFactory;
    }

    function deployBoxAdapterFactory() public returns (BoxAdapterFactory) {
        vm.startBroadcast();
        BoxAdapterFactory boxAdapterFactory = new BoxAdapterFactory();
        console.log("BoxAdapterFactory deployed at:", address(boxAdapterFactory));
        vm.stopBroadcast();
        return boxAdapterFactory;
    }

    function deployBoxAdapterCachedFactory() public returns (BoxAdapterCachedFactory) {
        vm.startBroadcast();
        BoxAdapterCachedFactory boxAdapterCachedFactory = new BoxAdapterCachedFactory();
        console.log("BoxAdapterCachedFactory deployed at:", address(boxAdapterCachedFactory));
        vm.stopBroadcast();
        return boxAdapterCachedFactory;
    }

    function deployMorphoVaultV1AdapterFactory() public returns (MorphoVaultV1AdapterFactory) {
        vm.startBroadcast();
        MorphoVaultV1AdapterFactory mv1AdapterFactory = new MorphoVaultV1AdapterFactory();
        console.log("MorphoVaultV1AdapterFactory deployed at:", address(mv1AdapterFactory));
        vm.stopBroadcast();
        return mv1AdapterFactory;
    }

    function deployVaultV2Factory() public returns (VaultV2Factory) {
        vm.startBroadcast();
        VaultV2Factory vaultV2Factory = new VaultV2Factory();
        console.log("VaultV2Factory deployed at:", address(vaultV2Factory));
        vm.stopBroadcast();
        return vaultV2Factory;
    }

    function deployPeaty() public returns (IVaultV2) {
        vm.startBroadcast();

        bytes32 salt = "2";

        VaultV2 vault = VaultV2(vaultV2Factory.createVaultV2(address(tx.origin), address(usdc), salt));
        console.log("Peaty deployed at:", address(vault));

        vault.setCurator(address(tx.origin));

        vault.addAllocator(address(tx.origin)); 
        vault.addAllocator(address(allocator1)); 
        vault.addAllocator(address(allocator2)); 

        vault.setName("Peaty USDC");
        vault.setSymbol("ptUSDC");

        // Setting the vault to use bbqUSDC as the asset
        MorphoVaultV1Adapter bbqusdcAdapter = MorphoVaultV1Adapter(mv1AdapterFactory.createMorphoVaultV1Adapter(address(vault), address(bbqusdc)));

        vault.addCollateral(address(bbqusdcAdapter), bbqusdcAdapter.data(), 100_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 100% relative cap

        vault.setLiquidityAdapterAndData(address(bbqusdcAdapter), "");


        // Creating Box 1 which will invest in stUSD
        string memory name = "Box Angle";
        string memory symbol = "BOX_ANGLE";
        uint256 maxSlippage = 0.001 ether; // 0.1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        Box box1 = boxFactory.createBox(
            usdc, 
            address(tx.origin), 
            address(tx.origin), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            salt
        );
        console.log("Box Angle deployed at:", address(box1));

        // Creating the ERC4626 adapter between the vault and box1
        IBoxAdapter adapter1 = boxAdapterFactory.createBoxAdapter(address(vault), box1);

        // Allow box 1 to invest in stUSD
        box1.addCollateral(stusd, stusdOracle);
        box1.addAllocator(address(allocator1));
        box1.addAllocator(address(allocator2));
        box1.addFeeder(address(adapter1));
        box1.setCurator(address(curator));
        box1.transferOwnership(address(owner));
        vault.addCollateral(address(adapter1), adapter1.adapterData(), 10_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap


        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Resolv";
        symbol = "BOX_RESOLV";
        maxSlippage = 0.01 ether; // 1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        Box box2 = boxFactory.createBox(
            usdc, 
            address(tx.origin), 
            address(tx.origin), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            salt
        );
        console.log("Box Resolv deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        IBoxAdapter adapter2 = boxAdapterCachedFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addCollateral(ptusr25sep, ptusr25sepOracle);
        box2.addAllocator(address(allocator1));
        box2.addAllocator(address(allocator2));
        box2.addFeeder(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateral(address(adapter2), adapter2.adapterData(), 1_000_000 * 10**6, 0.5 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vault.setPenaltyFee(address(adapter2), 0.02 ether); // 2% penalty
        
        vault.removeAllocator(address(tx.origin));
        vault.setCurator(address(curator));
        vault.setOwner(address(owner));

        
        vm.stopBroadcast();
        return vault;
    }
}
