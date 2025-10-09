// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BoxFactory} from "../src/factories/BoxFactory.sol";
import {BoxAdapterFactory} from "../src/factories/BoxAdapterFactory.sol";
import {MorphoVaultV1AdapterFactory} from "@vault-v2/src/adapters/MorphoVaultV1AdapterFactory.sol";
import {MorphoMarketV1AdapterFactory} from "@vault-v2/src/adapters/MorphoMarketV1AdapterFactory.sol";
import {IMetaMorpho} from "@vault-v2/lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {MarketParams, IMorpho, Id} from "@vault-v2/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {Id as MetaId} from "@vault-v2/lib/metamorpho/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParams as MarketParamsBlue, IMorpho as IMorphoBlue} from "@morpho-blue/interfaces/IMorpho.sol";
import {VaultV2Factory} from "@vault-v2/src/VaultV2Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IBoxAdapter} from "../src/interfaces/IBoxAdapter.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {Box} from "../src/Box.sol";
import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";
import {MorphoMarketV1Adapter} from "@vault-v2/src/adapters/MorphoMarketV1Adapter.sol";
import {MorphoVaultV1AdapterLib} from "../src/periphery/MorphoVaultV1AdapterLib.sol";
import {VaultV2Lib} from "../src/periphery/VaultV2Lib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {FundingMorpho} from "../src/FundingMorpho.sol";
import {FundingAave, IPool} from "../src/FundingAave.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {BoxAdapterFactory} from "../src/factories/BoxAdapterFactory.sol";
import {BoxAdapterCachedFactory} from "../src/factories/BoxAdapterCachedFactory.sol";
import {FundingMorphoFactory} from "../src/factories/FundingMorphoFactory.sol";
import {FundingAaveFactory} from "../src/factories/FundingAaveFactory.sol";
import {FlashLoanMorpho} from "../src/periphery/FlashLoanMorpho.sol";
import "@vault-v2/src/libraries/ConstantsLib.sol";
import {RevokerFactory} from "../src/periphery/RevokerFactory.sol";
import {Revoker} from "../src/periphery/Revoker.sol";
import {VaultV2Helper} from "../src/periphery/VaultV2Helper.sol";

///@dev This script deploys the necessary contracts for the Peaty product on Base.
///@dev Default factories are hardcoded, but can be overridden using run() which will deploy fresh contracts.
contract DeployBaseScript is Script {
    using BoxLib for IBox;
    using VaultV2Lib for VaultV2;
    using MorphoVaultV1AdapterLib for MorphoVaultV1Adapter;

    VaultV2Factory vaultV2Factory = VaultV2Factory(0x4501125508079A99ebBebCE205DeC9593C2b5857);
    MorphoVaultV1AdapterFactory mv1AdapterFactory = MorphoVaultV1AdapterFactory(0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642);
    MorphoMarketV1AdapterFactory mm1AdapterFactory = MorphoMarketV1AdapterFactory(0x133baC94306B99f6dAD85c381a5be851d8DD717c);

    BoxFactory boxFactory = BoxFactory(0x4A84f097dFA9220Cc34bEaa9795468Ea75Bd8349);
    BoxAdapterFactory boxAdapterFactory = BoxAdapterFactory(0x808F9fcf09921a21aa5Cd71D87BE50c0F05A5203);
    BoxAdapterCachedFactory boxAdapterCachedFactory = BoxAdapterCachedFactory(0x09EA5EafbA623D9012124E05068ab884008f32BD);
    FundingMorphoFactory fundingMorphoFactory = FundingMorphoFactory(address(0));
    FundingAaveFactory fundingAaveFactory = FundingAaveFactory(address(0));
    VaultV2Helper vaultV2Helper = VaultV2Helper(address(0));

    address owner = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address curator = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address guardian = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address allocator1 = address(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
    address allocator2 = address(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IMetaMorpho bbqusdc = IMetaMorpho(0xBEEFA7B88064FeEF0cEe02AAeBBd95D30df3878F); // bbqUSDC on Base
    IMetaMorpho steakusdc = IMetaMorpho(0xBEEFE94c8aD530842bfE7d8B397938fFc1cb83b2); // steakUSDC on Base

    IERC4626 stusd = IERC4626(0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776);
    IOracle stusdOracle = IOracle(0x2eede25066af6f5F2dfc695719dB239509f69915);

    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);

    IERC20 ptusde11dec = IERC20(0x194b8FeD256C02eF1036Ed812Cae0c659ee6F7FD);
    IOracle ptusde11decOracle = IOracle(0x15af6e452Fe5C4B78c45f9DE02842a52E600A1cA);

    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);

    IERC20 wsteth = IERC20(0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452);
    IOracle wstethOracle = IOracle(0xEEE8AFd3950687d557A1c3222Dbc834C124B946f);

    IERC20 cbeth = IERC20(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22);
    IOracle cbethOracle = IOracle(0x8d5097dd48e8d8d20F2c51a6F188183FeC3E345b);

    ///@dev This script deploys the necessary contracts for the Peaty product on Base.
    function run() public {
        boxFactory = deployBoxFactory();
        boxAdapterFactory = deployBoxAdapterFactory();
        boxAdapterCachedFactory = deployBoxAdapterCachedFactory();
    }

    function deployBoxFactory() public returns (BoxFactory) {
        vm.startBroadcast();
        BoxFactory boxFactory_ = new BoxFactory();
        // Mock Box just for automating the decoding on Basescan
        Box box_ = new Box(
            address(usdc),
            address(tx.origin),
            address(tx.origin),
            "Box Test",
            "BOX_TEST",
            0.01 ether,
            7 days,
            10 days,
            7 days
        );
        console.log("BoxFactory deployed at:", address(boxFactory_));
        vm.stopBroadcast();
        return boxFactory_;
    }

    function deployBoxAdapterFactory() public returns (BoxAdapterFactory) {
        vm.startBroadcast();
        BoxAdapterFactory boxAdapterFactory_ = new BoxAdapterFactory();
        console.log("BoxAdapterFactory deployed at:", address(boxAdapterFactory_));
        vm.stopBroadcast();
        return boxAdapterFactory_;
    }

    function deployBoxAdapterCachedFactory() public returns (BoxAdapterCachedFactory) {
        vm.startBroadcast();
        BoxAdapterCachedFactory boxAdapterCachedFactory_ = new BoxAdapterCachedFactory();
        console.log("BoxAdapterCachedFactory deployed at:", address(boxAdapterCachedFactory_));
        vm.stopBroadcast();
        return boxAdapterCachedFactory_;
    }

    function deployFlashLoanMorpho() public {
        vm.startBroadcast();
        FlashLoanMorpho flm = new FlashLoanMorpho(address(morpho));
        console.log("FlashLoanMorpho deployed at:", address(flm));
        vm.stopBroadcast();
    }

    function deployVaultV2Helper() public returns (VaultV2Helper) {
        vm.startBroadcast();
        VaultV2Helper vaultV2Helper_ = new VaultV2Helper();
        new Revoker(IVaultV2(address(1)), address(2)); // For decoding purposes on basescan
        console.log("VaultV2Helper deployed at:", address(vaultV2Helper_));
        vm.stopBroadcast();
        return vaultV2Helper_;
    }

    function addMarketsToAdapterFromVault(VaultV2 vault, MorphoMarketV1Adapter mm1Adapter, IMetaMorpho vaultv1) public {
        uint256 length = vaultv1.withdrawQueueLength();
        vault.addCollateralInstant(
            address(mm1Adapter),
            abi.encode("this", address(mm1Adapter)),
            1_000_000_000 * 10 ** 6, // 1_000_000_000 USDC absolute cap
            1 ether // 100% relative cap
        );
        for (uint256 i = 0; i < length; i++) {
            Id id = Id.wrap(MetaId.unwrap(vaultv1.withdrawQueue(i)));
            MarketParams memory marketParams = morpho.idToMarketParams(id);
            // We skip Idle markets
            if (marketParams.collateralToken != address(0)) {
                continue;
            }
            vault.addCollateralInstant(
                address(mm1Adapter),
                abi.encode("collateralToken", marketParams.collateralToken),
                100_000_000 * 10 ** 6, // 100_000_000 USDC absolute cap
                1 ether // 100% relative cap
            );
            vault.addCollateralInstant(
                address(mm1Adapter),
                abi.encode("this/marketParams", address(mm1Adapter), marketParams),
                100_000_000 * 10 ** 6, // 100_000_000 USDC absolute cap
                1 ether // 100% relative cap
            );
        }
    }

    function _updateForMorphoAdapterRegistry(IVaultV2 vault) internal {
        // Set the correct adapter registry and abdicate
        vault.submit(abi.encodeWithSelector(vault.setAdapterRegistry.selector, 0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a));
        vault.setAdapterRegistry(0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a);
        vault.submit(abi.encodeWithSelector(vault.abdicate.selector, vault.setAdapterRegistry.selector));
        vault.abdicate(vault.setAdapterRegistry.selector);
    }

    function _updateTimelocks(IVaultV2 vault, uint256 capsDays) internal {
        // Morpho requires a lot of them to be 7 days, some are fine with 3 days
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setReceiveAssetsGate.selector, 7 days));
        vault.increaseTimelock(vault.setReceiveAssetsGate.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setReceiveSharesGate.selector, 7 days));
        vault.increaseTimelock(vault.setReceiveSharesGate.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setSendSharesGate.selector, 7 days));
        vault.increaseTimelock(vault.setSendSharesGate.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setSendAssetsGate.selector, 7 days));
        vault.increaseTimelock(vault.setSendAssetsGate.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.abdicate.selector, 7 days));
        vault.increaseTimelock(vault.abdicate.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setAdapterRegistry.selector, 7 days));
        vault.increaseTimelock(vault.setAdapterRegistry.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.removeAdapter.selector, 7 days));
        vault.increaseTimelock(vault.removeAdapter.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.setForceDeallocatePenalty.selector, 7 days));
        vault.increaseTimelock(vault.setForceDeallocatePenalty.selector, 7 days);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.abdicate.selector, 7 days));
        vault.increaseTimelock(vault.abdicate.selector, 7 days);

        // Those need to be 3-days to be accepted in the Morpho UI
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.addAdapter.selector, capsDays));
        vault.increaseTimelock(vault.addAdapter.selector, capsDays);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseRelativeCap.selector, capsDays));
        vault.increaseTimelock(vault.increaseRelativeCap.selector, capsDays);
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseAbsoluteCap.selector, capsDays));
        vault.increaseTimelock(vault.increaseAbsoluteCap.selector, capsDays);

        // Those need to be at least 7-days to be accepted in the Morpho UI, this should be the last increase
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseTimelock.selector, 7 days));
        vault.increaseTimelock(vault.increaseTimelock.selector, 7 days);
    }

    function deployPeaty() public returns (IVaultV2) {
        vm.startBroadcast();

        bytes32 salt = "12";

        VaultV2 vault = VaultV2(vaultV2Factory.createVaultV2(address(tx.origin), address(usdc), salt));
        console.log("Peaty deployed at:", address(vault));

        vault.setCurator(address(tx.origin));

        vault.addAllocatorInstant(address(tx.origin));
        vault.addAllocatorInstant(address(allocator1));
        vault.addAllocatorInstant(address(allocator2));

        vault.setName("Peaty USDC");
        vault.setSymbol("ptUSDC");

        vault.setMaxRate(MAX_MAX_RATE);

        // Setting the vault to use bbqUSDC as the asset
        MorphoMarketV1Adapter bbqusdcAdapter = MorphoMarketV1Adapter(
            mm1AdapterFactory.createMorphoMarketV1Adapter(address(vault), address(morpho))
        );

        addMarketsToAdapterFromVault(vault, bbqusdcAdapter, bbqusdc);

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box Angle";
        string memory symbol = "BOX_ANGLE";
        uint256 maxSlippage = 0.0001 ether; // 0.01%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        uint256 shutdownWarmup = 7 days;
        IBox box1 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Angle deployed at:", address(box1));

        // Creating the ERC4626 adapter between the vault and box1
        IBoxAdapter adapter1 = boxAdapterFactory.createBoxAdapter(address(vault), box1);

        // Allow box 1 to invest in stUSD
        box1.addTokenInstant(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator1), true);
        box1.setIsAllocator(address(allocator2), true);
        box1.addFeederInstant(address(adapter1));
        box1.setCurator(address(curator));
        box1.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter1), adapter1.adapterData(), 10_000_000 * 10 ** 6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap

        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Ethena";
        symbol = "BOX_ETHENA";
        maxSlippage = 0.01 ether; // 0.1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        shutdownWarmup = 7 days;
        IBox box2 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Ethena deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        IBoxAdapter adapter2 = boxAdapterFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addTokenInstant(ptusde11dec, ptusde11decOracle);

        box2.setIsAllocator(address(allocator1), true);
        box2.setIsAllocator(address(allocator2), true);
        box2.addFeederInstant(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter2), adapter2.adapterData(), 100_000_000 * 10 ** 6, 0.9 ether); // 1,000,000 USDC absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter2), 0.02 ether); // 2% penalty

        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Resolv";
        symbol = "BOX_RESOLV";
        maxSlippage = 0.001 ether; // 0.1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        shutdownWarmup = 7 days;
        box2 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Resolv deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        adapter2 = boxAdapterFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addTokenInstant(ptusr25sep, ptusr25sepOracle);

        box2.setIsAllocator(address(allocator1), true);
        box2.setIsAllocator(address(allocator2), true);
        box2.addFeederInstant(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter2), adapter2.adapterData(), 100_000_000 * 10 ** 6, 0.9 ether); // 1,000,000 USDC absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter2), 0.02 ether); // 2% penalty

        vault.removeAllocatorInstant(address(tx.origin));
        vault.setCurator(address(curator));
        vault.setOwner(address(owner));

        vm.stopBroadcast();
        return vault;
    }

    function deployPeatyTurbo() public returns (IVaultV2) {
        vm.startBroadcast();

        bytes32 salt = "12";

        VaultV2 vault = VaultV2(vaultV2Factory.createVaultV2(address(tx.origin), address(usdc), salt));
        console.log("Peaty deployed at:", address(vault));

        vault.setCurator(address(tx.origin));

        vault.addAllocatorInstant(address(tx.origin));
        vault.addAllocatorInstant(address(allocator1));
        vault.addAllocatorInstant(address(allocator2));

        vault.setName("Peaty USDC Turbo");
        vault.setSymbol("ptUSDCturbo");

        vault.setMaxRate(MAX_MAX_RATE);

        // Setting the vault to use bbqUSDC as the asset
        MorphoMarketV1Adapter bbqusdcAdapter = MorphoMarketV1Adapter(
            mm1AdapterFactory.createMorphoMarketV1Adapter(address(vault), address(morpho))
        );

        addMarketsToAdapterFromVault(vault, bbqusdcAdapter, bbqusdc);

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box Angle";
        string memory symbol = "BOX_ANGLE";
        uint256 maxSlippage = 0.001 ether; // 0.1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        uint256 shutdownWarmup = 7 days;
        IBox box1 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Angle deployed at:", address(box1));

        // Creating the ERC4626 adapter between the vault and box1
        IBoxAdapter adapter1 = boxAdapterFactory.createBoxAdapter(address(vault), box1);

        // Allow box 1 to invest in stUSD
        box1.addTokenInstant(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator1), true);
        box1.setIsAllocator(address(allocator2), true);
        box1.addFeederInstant(address(adapter1));
        box1.setCurator(address(curator));
        box1.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter1), adapter1.adapterData(), 10_000_000 * 10 ** 6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap

        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Ethena";
        symbol = "BOX_ETHENA";
        maxSlippage = 0.001 ether; // 0.1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        shutdownWarmup = 7 days;
        IBox box2 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Ethena deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        IBoxAdapter adapter2 = boxAdapterFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addTokenInstant(ptusde11dec, ptusde11decOracle);

        FundingMorpho fundingMorpho = new FundingMorpho(address(box2), address(morpho), 99e16);
        MarketParamsBlue memory fundingMarketParams = MarketParamsBlue({
            loanToken: address(usdc),
            collateralToken: address(ptusde11dec),
            oracle: address(ptusde11decOracle),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 915000000000000000
        });
        bytes memory facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box2.addFundingInstant(fundingMorpho);
        box2.addFundingCollateralInstant(fundingMorpho, ptusde11dec);
        box2.addFundingDebtInstant(fundingMorpho, usdc);
        box2.addFundingFacilityInstant(fundingMorpho, facilityData);

        box2.setIsAllocator(address(allocator1), true);
        box2.setIsAllocator(address(allocator2), true);
        box2.addFeederInstant(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter2), adapter2.adapterData(), 1_000_000 * 10 ** 6, 0.9 ether); // 1,000,000 USDC absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter2), 0.02 ether); // 2% penalty

        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Resolv";
        symbol = "BOX_RESOLV";
        maxSlippage = 0.001 ether; // 0.1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        shutdownWarmup = 7 days;
        box2 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Resolv deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        adapter2 = boxAdapterFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addTokenInstant(ptusr25sep, ptusr25sepOracle);

        fundingMorpho = new FundingMorpho(address(box2), address(morpho), 99e16);
        fundingMarketParams = MarketParamsBlue({
            loanToken: address(usdc),
            collateralToken: address(ptusr25sep),
            oracle: address(ptusr25sepOracle),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 915000000000000000
        });
        facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box2.addFundingInstant(fundingMorpho);
        box2.addFundingCollateralInstant(fundingMorpho, ptusr25sep);
        box2.addFundingDebtInstant(fundingMorpho, usdc);
        box2.addFundingFacilityInstant(fundingMorpho, facilityData);

        box2.setIsAllocator(address(allocator1), true);
        box2.setIsAllocator(address(allocator2), true);
        box2.addFeederInstant(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter2), adapter2.adapterData(), 1_000_000 * 10 ** 6, 0.9 ether); // 1,000,000 USDC absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter2), 0.02 ether); // 2% penalty

        vault.removeAllocatorInstant(address(tx.origin));
        vault.setCurator(address(curator));
        vault.setOwner(address(owner));

        vm.stopBroadcast();
        return vault;
    }
    /*
    function deployPeatyCBBTC() public returns (IVaultV2) {
        vm.startBroadcast();

        bytes32 salt = "12";

        VaultV2 vault = VaultV2(vaultV2Factory.createVaultV2(address(tx.origin), address(usdc), salt));
        console.log("Peaty cbBTC deployed at:", address(vault));

        vault.setCurator(address(tx.origin));

        vault.addAllocatorInstant(address(tx.origin));
        vault.addAllocatorInstant(address(allocator1));
        vault.addAllocatorInstant(address(allocator2));

        vault.setName("Peaty cbBTC");
        vault.setSymbol("ptCBTC");

        vault.setMaxRate(MAX_MAX_RATE);

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box Peaty";
        string memory symbol = "BOX_PEATY";
        uint256 maxSlippage = 0.003 ether; // 0.3%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        uint256 shutdownWarmup = 7 days;
        IBox box1 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Peaty deployed at:", address(box1));

        // Creating the ERC4626 adapter between the vault and box1
        IBoxAdapter adapter1 = boxAdapterFactory.createBoxAdapter(address(vault), box1);

        // Allow box 1 to invest in stUSD
        box1.addTokenInstant(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator1), true);
        box1.setIsAllocator(address(allocator2), true);
        box1.addFeederInstant(address(adapter1));
        box1.setCurator(address(curator));
        box1.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter1), adapter1.adapterData(), 10_000_000 * 10 ** 6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap

        FundingMorpho fundingMorpho = new FundingMorpho(address(box2), address(morpho), 99e16);
        MarketParamsBlue memory fundingMarketParams = MarketParamsBlue({
            loanToken: address(usdc),
            collateralToken: address(cbbtc),
            oracle: address(cbbtcOracle),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 860000000000000000
        });
        bytes memory facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box1.addFundingInstant(fundingMorpho);
        box1.addFundingCollateralInstant(fundingMorpho, cbbtc);
        box1.addFundingDebtInstant(fundingMorpho, usdc);
        box1.addFundingFacilityInstant(fundingMorpho, facilityData);



        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box Resolv";
        symbol = "BOX_RESOLV";
        maxSlippage = 0.001 ether; // 0.1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        shutdownWarmup = 7 days;
        box2 = boxFactory.createBox(
            usdc,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Resolv deployed at:", address(box2));
        // Creating the ERC4626 adapter between the vault and box2
        adapter2 = boxAdapterFactory.createBoxAdapter(address(vault), box2);

        // Allow box 2 to invest in PT-USR-25SEP
        box2.addTokenInstant(ptusr25sep, ptusr25sepOracle);

        fundingMorpho = new FundingMorpho(address(box2), address(morpho), 99e16);
        fundingMarketParams = MarketParamsBlue({
            loanToken: address(usdc),
            collateralToken: address(ptusr25sep),
            oracle: address(ptusr25sepOracle),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 915000000000000000
        });
        facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box2.addFundingInstant(fundingMorpho);
        box2.addFundingCollateralInstant(fundingMorpho, ptusr25sep);
        box2.addFundingDebtInstant(fundingMorpho, usdc);
        box2.addFundingFacilityInstant(fundingMorpho, facilityData);

        box2.setIsAllocator(address(allocator1), true);
        box2.setIsAllocator(address(allocator2), true);
        box2.addFeederInstant(address(adapter2));
        box2.setCurator(address(curator));
        box2.transferOwnership(address(owner));
        vault.addCollateralInstant(address(adapter2), adapter2.adapterData(), 1_000_000 * 10 ** 6, 0.9 ether); // 1,000,000 USDC absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter2), 0.02 ether); // 2% penalty

        vault.removeAllocatorInstant(address(tx.origin));
        vault.setCurator(address(curator));
        vault.setOwner(address(owner));

        vm.stopBroadcast();
        return vault;
    }*/

    function deployPeatyETHTurbo() public returns (IVaultV2) {
        vm.startBroadcast();

        bytes32 salt = "14";

        VaultV2 vault = VaultV2(vaultV2Factory.createVaultV2(address(tx.origin), address(weth), salt));
        console.log("Peaty ETH Turbo deployed at:", address(vault));

        vault.setCurator(address(tx.origin));

        vault.addAllocatorInstant(address(tx.origin));
        vault.addAllocatorInstant(address(allocator1));
        vault.addAllocatorInstant(address(allocator2));

        vault.setName("Peaty ETH Turbo");
        vault.setSymbol("ptETHturbo");

        vault.setMaxRate(MAX_MAX_RATE);

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box Peaty";
        string memory symbol = "BOX_PEATY";
        uint256 maxSlippage = 0.001 ether; // 0.1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        uint256 shutdownWarmup = 7 days;
        IBox box1 = boxFactory.createBox(
            weth,
            address(tx.origin),
            address(tx.origin),
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            shutdownWarmup,
            salt
        );
        console.log("Box Peaty deployed at:", address(box1));

        // Creating the ERC4626 adapter between the vault and box1
        IBoxAdapter adapter1 = boxAdapterFactory.createBoxAdapter(address(vault), box1);

        box1.addTokenInstant(wsteth, wstethOracle);
        box1.addTokenInstant(cbeth, cbethOracle);
        box1.setIsAllocator(address(allocator1), true);
        box1.setIsAllocator(address(allocator2), true);
        box1.addFeederInstant(address(adapter1));
        vault.addCollateralInstant(address(adapter1), adapter1.adapterData(), 10_000_000 * 10 ** 6, 0.9 ether); // 10,000,000 absolute cap and 90% relative cap
        vault.setForceDeallocatePenaltyInstant(address(adapter1), 0.0 ether); // 0% penalty

        FundingMorpho fundingMorpho = new FundingMorpho(address(box1), address(morpho), 99e16);
        box1.addFundingInstant(fundingMorpho);
        box1.addFundingCollateralInstant(fundingMorpho, wsteth);
        box1.addFundingCollateralInstant(fundingMorpho, cbeth);
        box1.addFundingDebtInstant(fundingMorpho, weth);
        MarketParamsBlue memory fundingMarketParams = MarketParamsBlue({
            loanToken: address(weth),
            collateralToken: address(wsteth),
            oracle: address(0xaE10cbdAa587646246c8253E4532A002EE4fa7A4),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 965000000000000000
        });
        bytes memory facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box1.addFundingFacilityInstant(fundingMorpho, facilityData);
        fundingMarketParams = MarketParamsBlue({
            loanToken: address(weth),
            collateralToken: address(wsteth),
            oracle: address(0x4A11590e5326138B514E08A9B52202D42077Ca65),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 945000000000000000
        });
        facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box1.addFundingFacilityInstant(fundingMorpho, facilityData);
        fundingMarketParams = MarketParamsBlue({
            loanToken: address(weth),
            collateralToken: address(cbeth),
            oracle: address(0xB03855Ad5AFD6B8db8091DD5551CAC4ed621d9E6),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 965000000000000000
        });
        facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box1.addFundingFacilityInstant(fundingMorpho, facilityData);
        fundingMarketParams = MarketParamsBlue({
            loanToken: address(weth),
            collateralToken: address(cbeth),
            oracle: address(0xB03855Ad5AFD6B8db8091DD5551CAC4ed621d9E6),
            irm: 0x46415998764C29aB2a25CbeA6254146D50D22687,
            lltv: 945000000000000000
        });
        facilityData = fundingMorpho.encodeFacilityData(fundingMarketParams);
        box1.addFundingFacilityInstant(fundingMorpho, facilityData);

        FundingAave fundingAave = new FundingAave(
            address(box1),
            IPool(0xA238Dd80C259a72e81d7e4664a9801593F98d1c5),
            8 /* wstETH/ETH emode) */
        );
        box1.addFundingInstant(fundingAave);
        box1.addFundingCollateralInstant(fundingAave, wsteth);
        box1.addFundingDebtInstant(fundingAave, weth);

        fundingAave = new FundingAave(address(box1), IPool(0xA238Dd80C259a72e81d7e4664a9801593F98d1c5), 9 /* cbETH/ETH emode) */);
        box1.addFundingInstant(fundingAave);
        box1.addFundingCollateralInstant(fundingAave, cbeth);
        box1.addFundingDebtInstant(fundingAave, weth);

        box1.setCurator(address(curator));
        box1.transferOwnership(address(owner));

        vault.removeAllocatorInstant(address(tx.origin));
        vault.setCurator(address(curator));
        vault.setOwner(address(owner));

        vm.stopBroadcast();
        return vault;
    }



    function deploySteakUSDC() public returns (IVaultV2) {
        vm.startBroadcast();

        VaultV2Helper helper = new VaultV2Helper();

        IVaultV2 vault = helper.create(address(usdc), bytes32("45"), "Steakhouse High Yield Instant", "bbqUSDC");
        console.log("Vault deployed at:", address(vault));

        address guardianAddr = helper.createGuardian(vault);
        console.log("Guardian deployed at:", guardianAddr);
        helper.setGuardian(vault, guardianAddr);

        helper.addVaultV1(vault, address(steakusdc), true, 1_000_000_000 * 10 ** 6, 1 ether);

        helper.conformMorphoRegistry(vault);
        address msig = helper.finalize(vault, 3 days, guardianAddr);
        console.log("Msig owner deployed at:", msig);

        usdc.approve(address(vault), 10);
        vault.deposit(10, address(tx.origin));

        vm.stopBroadcast();
        return vault;
    }

    function deployBbqUSDC() public returns (IVaultV2) {
        vm.startBroadcast();

        VaultV2Helper helper = new VaultV2Helper();

        IVaultV2 vault = helper.create(address(usdc), bytes32("45"), "Steakhouse High Yield Instant", "bbqUSDC");
        console.log("Vault deployed at:", address(vault));

        address guardianAddr = helper.createGuardian(vault);
        console.log("Guardian deployed at:", guardianAddr);
        helper.setGuardian(vault, guardianAddr);

        helper.addVaultV1(vault, address(bbqusdc), true, 1_000_000_000 * 10 ** 6, 1 ether);

        helper.conformMorphoRegistry(vault);
        address msig = helper.finalize(vault, 3 days, guardianAddr);
        console.log("Msig owner deployed at:", msig);

        usdc.approve(address(vault), 10);
        vault.deposit(10, address(tx.origin));

        vm.stopBroadcast();
        return vault;
    }


    function deployRampUSDC() public returns (IVaultV2) {
        vm.startBroadcast();

        VaultV2Helper helper = new VaultV2Helper();

        IVaultV2 vault = helper.create(address(usdc), bytes32("45"), "Ramp x Steakhouse High Yield Instant", "ramp-bbqUSDC");
        console.log("Vault deployed at:", address(vault));

        address guardianAddr = helper.createGuardian(vault);
        console.log("Guardian deployed at:", guardianAddr);
        helper.setGuardian(vault, guardianAddr);

        helper.addVaultV1(vault, address(steakusdc), true, 1_000_000_000 * 10 ** 6, 1 ether);

        // Not conforming vault helper.conformMorphoRegistry(vault);
        address msig = helper.finalize(vault, 7 days, guardianAddr);
        console.log("Msig owner deployed at:", msig);

        usdc.approve(address(vault), 10);
        vault.deposit(10, address(tx.origin));

        vm.stopBroadcast();
        return vault;
    }
}
