// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {MorphoVaultV1AdapterFactory} from "@vault-v2/src/adapters/MorphoVaultV1AdapterFactory.sol";
import {IVaultV2, IERC20} from "@vault-v2/src/interfaces/IVaultV2.sol";
import "@vault-v2/src/libraries/ConstantsLib.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "@vault-v2/src/VaultV2Factory.sol";
import {Revoker} from "./Revoker.sol";
import {VaultV2Lib} from "./VaultV2Lib.sol";

/**
 * @title VaultV2Helper
 * @notice Helper contract for VaultV2 configuration (vault setup only, NO DAO logic)
 * @dev This contract handles vault creation, adapter configuration, and timelock setup.
 *      All Aragon DAO logic has been moved to AragonDAOEncoder library and deployment scripts.
 *
 * Key principle: This contract can be called by other contracts because it only configures
 * the vault, not DAOs. DAO operations require EOA execution (see AragonDAOEncoder).
 *
 * Chain Support:
 * - Ethereum Mainnet (chainId: 1)
 * - Base (chainId: 8453)
 * - Addresses configured per chain in constructor
 */
contract VaultV2Helper {
    using VaultV2Lib for IVaultV2;

    /* ======== EVENTS ======== */
    event VaultCreated(address indexed vault, address indexed asset, string name, string symbol);
    event RevokerDeployed(address indexed vault, address indexed sentinel, address indexed revoker);
    event VaultConfigured(address indexed vault);

    /* ======== VARIABLES ======== */
    address public owner;
    address public curator;
    address[] public allocators;

    address public morphoRegistry;
    VaultV2Factory public vaultV2Factory;
    MorphoVaultV1AdapterFactory public mv1AdapterFactory;

    /* ======== CONSTRUCTOR ======== */

    constructor() {
        // Base configuration (chain ID 8453) or local testing (31337)
        if (block.chainid == 8453 || block.chainid == 31337) {
            morphoRegistry = 0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a;
            owner = 0x0A0e559bc3b0950a7e448F0d4894db195b9cf8DD;
            curator = 0x827e86072B06674a077f592A531dcE4590aDeCdB;
            allocators.push(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
            allocators.push(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);
            vaultV2Factory = VaultV2Factory(0x4501125508079A99ebBebCE205DeC9593C2b5857);
            mv1AdapterFactory = MorphoVaultV1AdapterFactory(0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642);
        }
        // Ethereum Mainnet configuration (chain ID 1)
        else if (block.chainid == 1) {
            morphoRegistry = address(0); // TODO: Set mainnet Morpho registry
            owner = 0x0A0e559bc3b0950a7e448F0d4894db195b9cf8DD;
            curator = 0x827e86072B06674a077f592A531dcE4590aDeCdB;
            allocators.push(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
            allocators.push(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);
            vaultV2Factory = VaultV2Factory(address(0)); // TODO: Set mainnet factory
            mv1AdapterFactory = MorphoVaultV1AdapterFactory(address(0)); // TODO: Set mainnet adapter factory
        } else {
            revert("Unsupported chain");
        }
    }

    /* ======== VAULT CREATION ======== */

    /**
     * @notice Create a new VaultV2 instance
     * @dev Helper becomes initial owner and curator, which should be transferred later
     * @param asset The underlying asset (e.g., USDC)
     * @param salt Salt for deterministic deployment
     * @param name Vault name
     * @param symbol Vault symbol
     * @return vault The created vault
     */
    function create(
        address asset,
        bytes32 salt,
        string calldata name,
        string calldata symbol
    ) external returns (IVaultV2 vault) {
        // Create vault via factory
        vault = VaultV2(vaultV2Factory.createVaultV2(address(this), asset, salt));

        // Set helper as curator
        vault.setCurator(address(this));

        // Add helper as allocator (needed for initial config)
        vault.submit(abi.encodeWithSelector(vault.setIsAllocator.selector, address(this), true));
        vault.setIsAllocator(address(this), true);

        // Add configured allocators
        for (uint i = 0; i < allocators.length; i++) {
            vault.submit(abi.encodeWithSelector(vault.setIsAllocator.selector, address(allocators[i]), true));
            vault.setIsAllocator(address(allocators[i]), true);
        }

        // Set vault metadata
        vault.setName(name);
        vault.setSymbol(symbol);

        // Set maximum rate
        vault.setMaxRate(MAX_MAX_RATE);

        emit VaultCreated(address(vault), asset, name, symbol);
    }

    /* ======== ADAPTER CONFIGURATION ======== */

    /**
     * @notice Add a Morpho MetaMorpho vault as an adapter
     * @dev Creates adapter, adds it to vault, and sets caps
     * @param vault The VaultV2 to configure
     * @param vaultV1 The MetaMorpho vault address
     * @param liquidity Whether to set as liquidity adapter
     * @param capAbs Absolute cap in asset units
     * @param capRel Relative cap as a fraction (1 ether = 100%)
     */
    function addVaultV1(
        IVaultV2 vault,
        address vaultV1,
        bool liquidity,
        uint256 capAbs,
        uint256 capRel
    ) external {
        // Create adapter
        address adapterMV1 = mv1AdapterFactory.createMorphoVaultV1Adapter(address(vault), vaultV1);
        bytes memory idData = abi.encode("this", adapterMV1);

        // Add adapter and set caps using submit/accept pattern
        vault.submit(abi.encodeWithSelector(vault.addAdapter.selector, adapterMV1));
        vault.addAdapter(adapterMV1);

        vault.submit(abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, capAbs));
        vault.increaseAbsoluteCap(idData, capAbs);

        vault.submit(abi.encodeWithSelector(vault.increaseRelativeCap.selector, idData, capRel));
        vault.increaseRelativeCap(idData, capRel);

        // Optionally set as liquidity adapter
        if (liquidity) {
            vault.setLiquidityAdapterAndData(adapterMV1, "");
        }
    }

    /**
     * @notice Seed vault with initial deposit
     * @dev Caller must have approved the vault to spend the asset
     * @param vault The vault to seed
     * @param amount Amount to deposit
     */
    function seed(IVaultV2 vault, uint256 amount) external {
        // Approve the vault to pull the asset
        IERC20(vault.asset()).approve(address(vault), amount);
        // Deposit into the vault
        vault.deposit(amount, address(this));
    }

    /**
     * @notice Configure vault to use Morpho's adapter registry
     * @dev Sets registry and abdicates permission to change it
     * @param vault The vault to configure
     */
    function conformMorphoRegistry(IVaultV2 vault) external {
        // Set the correct adapter registry and abdicate
        vault.submit(abi.encodeWithSelector(vault.setAdapterRegistry.selector, morphoRegistry));
        vault.setAdapterRegistry(morphoRegistry);
        vault.submit(abi.encodeWithSelector(vault.abdicate.selector, vault.setAdapterRegistry.selector));
        vault.abdicate(vault.setAdapterRegistry.selector);
    }

    /* ======== VAULT FINALIZATION ======== */

    /**
     * @notice Set all required timelocks on the vault
     * @dev Sets timelocks according to Morpho requirements (7 days for critical functions)
     * @param vault The vault to configure
     * @param capsDays Timelock for caps changes (typically 3 days)
     */
    function setVaultTimelocks(IVaultV2 vault, uint256 capsDays) external {
        // Morpho requires these to be 7 days
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

        // These can be 3 days for Morpho UI acceptance
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.addAdapter.selector, capsDays));
        vault.increaseTimelock(vault.addAdapter.selector, capsDays);

        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseRelativeCap.selector, capsDays));
        vault.increaseTimelock(vault.increaseRelativeCap.selector, capsDays);

        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseAbsoluteCap.selector, capsDays));
        vault.increaseTimelock(vault.increaseAbsoluteCap.selector, capsDays);

        // This must be last - 7 days minimum
        vault.submit(abi.encodeWithSelector(vault.increaseTimelock.selector, vault.increaseTimelock.selector, 7 days));
        vault.increaseTimelock(vault.increaseTimelock.selector, 7 days);
    }

    /**
     * @notice Set production curator on the vault
     * @dev Should be called after vault is configured but before ownership transfer
     * @param vault The vault to configure
     */
    function setProductionCurator(IVaultV2 vault) external {
        vault.setCurator(curator);
    }

    /**
     * @notice Remove helper from vault allocator list
     * @dev Should be called before transferring curator/ownership
     * @param vault The vault to clean up
     */
    function removeHelperAsAllocator(IVaultV2 vault) external {
        vault.submit(abi.encodeWithSelector(vault.setIsAllocator.selector, address(this), false));
        vault.setIsAllocator(address(this), false);
    }

    /* ======== SENTINEL/GUARDIAN SETUP ======== */

    /**
     * @notice Deploy Revoker and set as vault sentinel
     * @dev Revoker connects sentinel DAO to vault for emergency actions
     * @param vault The vault to configure
     * @param sentinel Address of Sentinel DAO (LockToVote)
     * @return revoker The deployed Revoker contract
     */
    function setRevoker(IVaultV2 vault, address sentinel) public returns (address revoker) {
        // Deploy Revoker
        Revoker revokerContract = new Revoker(vault, sentinel);
        revoker = address(revokerContract);

        // Set as sentinel
        vault.setIsSentinel(revoker, true);

        emit RevokerDeployed(address(vault), sentinel, revoker);
    }

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use setRevoker() instead
     */
    function setGuardian(IVaultV2 vault, address sentinel) external returns (address) {
        return setRevoker(vault, sentinel);
    }

    /* ======== OWNERSHIP TRANSFER ======== */

    /**
     * @notice Transfer vault ownership to Owner DAO
     * @dev Final step in vault setup - transfers control to governance
     * @param vault The vault to transfer
     * @param newOwner Address of Owner DAO (2/2 multisig)
     */
    function transferOwnership(IVaultV2 vault, address newOwner) external {
        require(newOwner != address(0), "Invalid owner address");
        vault.setOwner(newOwner);
        emit VaultConfigured(address(vault));
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     * @notice Get configured addresses for this chain
     */
    function getConfig() external view returns (
        address _owner,
        address _curator,
        address[] memory _allocators,
        address _morphoRegistry,
        address _vaultV2Factory,
        address _mv1AdapterFactory
    ) {
        return (owner, curator, allocators, morphoRegistry, address(vaultV2Factory), address(mv1AdapterFactory));
    }

    /* ======== DEPRECATED FUNCTIONS (FOR COMPILATION ONLY) ======== */

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use AragonDAOEncoder library and direct EOA calls instead
     * @dev See ARAGON_DAO_SETUP.md for implementation guide
     */
    function createGuardian(IVaultV2) external pure returns (address) {
        revert("createGuardian() removed - use AragonDAOEncoder + EOA direct calls");
    }

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use AragonDAOEncoder library and direct EOA calls instead
     * @dev See ARAGON_DAO_SETUP.md for implementation guide
     */
    function createGuardianWithMetadata(IVaultV2, string memory)
        external
        pure
        returns (address, address, address)
    {
        revert("createGuardianWithMetadata() removed - use AragonDAOEncoder + EOA direct calls");
    }

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use AragonDAOEncoder library and direct EOA calls instead
     * @dev See ARAGON_DAO_SETUP.md for implementation guide
     */
    function finalizeWithMetadata(IVaultV2, uint256, address, string memory)
        external
        pure
        returns (address)
    {
        revert("finalizeWithMetadata() removed - use AragonDAOEncoder + EOA direct calls");
    }

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use AragonDAOEncoder library and direct EOA calls instead
     * @dev See ARAGON_DAO_SETUP.md for implementation guide
     */
    function createRootPermissionProposal(address, address, address)
        external
        pure
        returns (uint256)
    {
        revert("createRootPermissionProposal() removed - use AragonDAOEncoder + EOA direct calls");
    }

    /**
     * @dev DEPRECATED - This function has been removed
     * @dev Use setVaultTimelocks(), setProductionCurator(), transferOwnership() separately
     * @dev See ARAGON_DAO_SETUP.md for implementation guide
     */
    function finalize(IVaultV2, uint256, address) external pure returns (address) {
        revert("finalize() removed - use setVaultTimelocks() + transferOwnership() separately");
    }
}

/**
 * USAGE EXAMPLE (in deployment script):
 *
 * // Deploy helper
 * VaultV2Helper helper = new VaultV2Helper();
 *
 * // 1. Create and configure vault
 * IVaultV2 vault = helper.create(address(usdc), bytes32("salt"), "My Vault", "mvUSDC");
 * usdc.approve(address(vault), 0.01e6);
 * vault.deposit(0.01e6, tx.origin);  // Seed vault
 *
 * helper.addVaultV1(vault, metamorphoAddress, true, 1_000_000e6, 1 ether);
 * helper.conformMorphoRegistry(vault);
 *
 * // 2. Create DAOs (using AragonDAOEncoder + EOA direct calls)
 * address sentinelDao = _createSentinelDao(vault);  // See AragonDAOEncoder
 * address ownerDao = _createOwnerDao(sentinelDao);  // See AragonDAOEncoder
 *
 * // 3. Connect sentinel and transfer ownership
 * helper.setRevoker(vault, sentinelDao);
 * helper.setVaultTimelocks(vault, 3 days);
 * helper.setProductionCurator(vault);
 * helper.removeHelperAsAllocator(vault);
 * helper.transferOwnership(vault, ownerDao);
 */
