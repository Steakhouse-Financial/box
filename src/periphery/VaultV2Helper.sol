// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "@vault-v2/src/VaultV2Factory.sol";
import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2Lib} from "./VaultV2Lib.sol";
import {Revoker} from "./Revoker.sol";
import {MorphoVaultV1AdapterFactory} from "@vault-v2/src/adapters/MorphoVaultV1AdapterFactory.sol";
import "@vault-v2/src/libraries/ConstantsLib.sol";

contract VaultV2Helper {
    using VaultV2Lib for IVaultV2;
    
    /* ======== EVENTS ======== */
    event RevokerCreated(address vault, address sentinel, address revoker);


    /* ======== VARIABLES ======== */
    address public curator;
    address[] allocators;

    address morphoRegistry;
    address aragonCreator;
    bytes aragonOwner;
    bytes aragonGuardian;

    VaultV2Factory vaultV2Factory;
    MorphoVaultV1AdapterFactory mv1AdapterFactory;

    constructor() {
        morphoRegistry = 0x3696c5eAe4a7Ffd04Ea163564571E9CD8Ed9364e; 
        curator = 0x827e86072B06674a077f592A531dcE4590aDeCdB;
        aragonCreator = 0xcc602EA573a42eBeC290f33F49D4A87177ebB8d2;
        aragonOwner = bytes(0xb5568838000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d61544b4250386444335562485a74697669545333754b7661696f77757761476e754857347464706e53744e7200000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000212ef339c77b3390599cab4d46222d79faabcb5c00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000060000000000000000000000000feed46c11f57b7126a773eec6ae9ca7ae1c03c9a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000);
        aragonGuardian = bytes(0xb5568838000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d51707755697a3454565a36546567613555685a5366667363354139595a79765175335436484178616137703600000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000212ef339c77b3390599cab4d46222d79faabcb5c00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000060000000000000000000000000feed46c11f57b7126a773eec6ae9ca7ae1c03c9a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000);
        allocators.push(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
        allocators.push(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);
        vaultV2Factory = VaultV2Factory(0x4501125508079A99ebBebCE205DeC9593C2b5857);
        mv1AdapterFactory = MorphoVaultV1AdapterFactory(0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642);
    }

    function create(address asset, bytes32 salt, string calldata name, string calldata symbol) public returns (IVaultV2 vault) {
        vault = VaultV2(vaultV2Factory.createVaultV2(address(this), asset, salt));

        vault.setCurator(address(this));

        for(uint i = 0; i < allocators.length; i++) {
            IVaultV2(vault).addAllocatorInstant(address(allocators[i]));
        }

        vault.setName(name);
        vault.setSymbol(symbol);

        vault.setMaxRate(MAX_MAX_RATE);
    }


    function createGuardian(IVaultV2 vault) public returns (address guardian) {
        (bool success, bytes memory result) = aragonCreator.call(aragonGuardian);
        guardian = abi.decode(result, (address));

        // Optionally revert if the call failed
        require(success, "Guardian creation failed");
    }

    function setGuardian(IVaultV2 vault, address guardian) public {
        address revoker = new Revoker(address(vault), guardian);
        vault.setIsSentinel(revoker, true);
    }


    function addVaultV1(IVaultV2 vault, address vaultV1, bool liquidity) public {
        address adapterMV1 = mv1AdapterFactory.createMorphoVaultV1Adapter(address(vault), vaultV1);

        vault.addCollateralInstant(
            adapterMV1,
            abi.encode("this", adapterMV1),
            1_000_000_000 * 10 ** 6, // 1_000_000_000 USDC absolute cap
            1 ether // 100% relative cap
        );

        if(liquidity) {
            vault.setLiquidityAdapterAndData(adapterMV1, "");
        }
    }


    function setOwner(IVaultV2 vault, address owner, address guardian) public returns (address msig) {
        (bool success, bytes memory result) = aragonCreator.call(aragonOwner);
        msig = abi.decode(result, (address));

        // Optionally revert if the call failed
        require(success, "Msig creation failed");

        vault.setOwner(msig);
    }

    function seed(IVaultV2 vault, uint256 amount) public {
        // Approve the vault to pull the asset
        vault.asset().approve(address(vault), amount);
        // Deposit into the vault
        vault.deposit(amount, address(this));
    }


    function conformMorphoRegistry(IVaultV2 vault) public {
        // Set the correct adapter registry and abdicate
        vault.submit(abi.encodeWithSelector(vault.setAdapterRegistry.selector, 0x3696c5eAe4a7Ffd04Ea163564571E9CD8Ed9364e));
        vault.setAdapterRegistry(0x3696c5eAe4a7Ffd04Ea163564571E9CD8Ed9364e);
        vault.submit(abi.encodeWithSelector(vault.abdicate.selector, vault.setAdapterRegistry.selector));
        vault.abdicate(vault.setAdapterRegistry.selector);
    }


    function finalize(IVaultV2 vault, uint capsDays) public {
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

        // Production owners 
        vault.setCurator(address(curator));
    }
}
