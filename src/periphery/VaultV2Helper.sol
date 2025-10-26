// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.28;

import {MorphoVaultV1AdapterFactory} from "@vault-v2/src/adapters/MorphoVaultV1AdapterFactory.sol";
import {IVaultV2, IERC20} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@vault-v2/src/libraries/ConstantsLib.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "@vault-v2/src/VaultV2Factory.sol";
import {Revoker} from "./Revoker.sol";
import {VaultV2Lib} from "./VaultV2Lib.sol";
import "../interfaces/Aragon.sol";

/**
 * @title VaultV2Helper
 * @notice Helper contract for VaultV2 configuration
 * @dev This contract handles vault configuration, adapter management, and other utility functions.
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
    IDAOFactory public daoFactory;
    address public lockToVoteRepo;
    address public multisigRepo;


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
            daoFactory = IDAOFactory(0xcc602EA573a42eBeC290f33F49D4A87177ebB8d2);
            lockToVoteRepo = 0x05ECA5ab78493Bf812052B0211a206BCBA03471B;
            multisigRepo = 0xcDC4b0BC63AEfFf3a7826A19D101406C6322A585;
        }
        // Ethereum Mainnet configuration (chain ID 1)
        else if (block.chainid == 1) {
            morphoRegistry = address(0); // TODO: Set mainnet Morpho registry
            owner = 0x0A0e559bc3b0950a7e448F0d4894db195b9cf8DD;
            curator = 0x827e86072B06674a077f592A531dcE4590aDeCdB;
            allocators.push(0x0000aeB716a0DF7A9A1AAd119b772644Bc089dA8);
            allocators.push(0xfeed46c11F57B7126a773EeC6ae9cA7aE1C03C9a);
            vaultV2Factory = VaultV2Factory(address(0xA1D94F746dEfa1928926b84fB2596c06926C0405)); // TODO: Set mainnet factory
            mv1AdapterFactory = MorphoVaultV1AdapterFactory(address(0xD1B8E2dee25c2b89DCD2f98448a7ce87d6F63394)); // TODO: Set mainnet adapter factory
            daoFactory = IDAOFactory(address(0)); // TODO: Set mainnet DAO factory
            lockToVoteRepo = address(0); // TODO: Set mainnet LockToVote repo
            multisigRepo = address(0); // TODO: Set mainnet Multisig repo
        } else {
            revert("Unsupported chain");
        }
    }

    /* ======== VAULT CREATION TEMPLATES ======== */
    function createV1WrapperCompliant(
        address asset,
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        address v1Vault) external returns (IVaultV2 vault) {
        // Create vault via factory
        vault = create(asset, salt, name, symbol);

        addVaultV1(vault, v1Vault, true, 1_000_000_000 * 10 ** IERC20Metadata(v1Vault).decimals(), 1 ether);
        conformMorphoRegistry(vault);

        address guardian = createGuardian(vault);
        
        finalize(vault, 3 days, guardian);
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
    ) public returns (IVaultV2 vault) {
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
    ) public {
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
     * @notice Configure vault to use Morpho's adapter registry
     * @dev Sets registry and abdicates permission to change it
     * @param vault The vault to configure
     */
    function conformMorphoRegistry(IVaultV2 vault) public {
        // Set the correct adapter registry and abdicate
        vault.submit(abi.encodeWithSelector(vault.setAdapterRegistry.selector, morphoRegistry));
        vault.setAdapterRegistry(morphoRegistry);
        vault.submit(abi.encodeWithSelector(vault.abdicate.selector, vault.setAdapterRegistry.selector));
        vault.abdicate(vault.setAdapterRegistry.selector);
    }

    /**
     * @notice Create the Guardian DAO using LockToVote plugin and set the sentinel
     */
    function createGuardian(IVaultV2 vault) public returns (address guardian) {
        guardian = createGuardianDAO(vault);
        setRevoker(vault, guardian);
    }

    /**
     * @notice Perform timelocks and ACLs setup, then transfer ownership to Owner DAO
     */
    function finalize(IVaultV2 vault, uint256 timelocks, address guardian) public returns (address) {
        
        removeHelperAsAllocator(vault);
        setVaultTimelocks(vault, timelocks);

        setProductionCurator(vault);

        if(guardian != address(0)) {
            address ownerDAO = createOwnerDAO(guardian, owner, "");
            transferOwnership(vault, ownerDAO);
            return ownerDAO;
        }
        else {
            transferOwnership(vault, owner);
            return owner;
        }
    }

    /* ======== VAULT FINALIZATION ======== */

    /**
     * @notice Set all required timelocks on the vault
     * @dev Sets timelocks according to Morpho requirements (7 days for critical functions)
     * @param vault The vault to configure
     * @param capsDays Timelock for caps changes (typically 3 days)
     */
    function setVaultTimelocks(IVaultV2 vault, uint256 capsDays) public {
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
    function setProductionCurator(IVaultV2 vault) public {
        vault.setCurator(curator);
    }

    /**
     * @notice Remove helper from vault allocator list
     * @dev Should be called before transferring curator/ownership
     * @param vault The vault to clean up
     */
    function removeHelperAsAllocator(IVaultV2 vault) public {
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
     * @notice create a Guardian DAO using LockToVote plugin using the vault shares
     */
    function createGuardianDAO(IVaultV2 vault) public returns (address) {
        DAOSettings memory daoSettings = DAOSettings({
            trustedForwarder: address(0),
            daoURI: "ipfs://QmTe4gavy3LB91hYZ9MszzD1v3wsgnVYEfwkS2SZKM46rC",
            subdomain: "",
            metadata: ""
        });

        PluginSettings[] memory pluginSettings = new PluginSettings[](0);

        (address dao, InstalledPlugin[] memory installedPlugins) = IDAOFactory(daoFactory).createDao(
            daoSettings,
            pluginSettings
        );

        address plugin = addLockedVotePlugin(IDAO(dao), address(vault));

        // Create the action array
        IDAO.Action[] memory actions = new IDAO.Action[](3);

        bytes32 ROOT = keccak256("ROOT_PERMISSION");
        bytes32 UPGRADE = keccak256("UPGRADE_DAO_PERMISSION");
        bytes32 UPDATE_VOTING = keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

        // 1. Revoke UPDATE_VOTING_SETTINGS_PERMISSION from plugin
        actions[0] = IDAO.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, plugin, dao, UPDATE_VOTING)
        });

        // 2. Revoke UPGRADE_DAO_PERMISSION from DAO
        actions[1] = IDAO.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, dao, dao, UPGRADE)
        });

        // 3. Revoke ROOT_PERMISSION from DAO (makes it fully immutable)
        actions[2] = IDAO.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, dao, dao, ROOT)
        });

        // Execute
        IDAO(dao).execute({_callId: "", _actions: actions, _allowFailureMap: 0});


        // Revoke Temporarily `ROOT_PERMISSION_ID` that implicitly granted to this `DaoFactory`
        // at the create dao step `address(this)` being the initial owner of the new created DAO.
        //dao.revoke(daoAddress, address(this), dao.ROOT_PERMISSION_ID());

        return dao;
    }

    function createOwnerDAO(
        address sentinel,
        address steakhouse,
        string memory metadataURI
    ) public returns (address) {

        DAOSettings memory daoSettings = DAOSettings({
            trustedForwarder: address(0),
            daoURI: "ipfs://QmP7dhYX2HdVPQbhcu6a1oLjsWoqmwtWB5Bwk7Gajvehrb",
            subdomain: "",
            metadata: ""
        });

        PluginSettings[] memory pluginSettings = new PluginSettings[](1);
        pluginSettings[0] = PluginSettings({
            pluginSetupRef: PluginSetupRef({
                versionTag: PluginSettingsTag({release: 1, build: 2}),
                pluginSetupRepo: multisigRepo
            }),
            data: _getMultisigData(sentinel, steakhouse)
        });

        (address dao, InstalledPlugin[] memory installedPlugins) = IDAOFactory(daoFactory).createDao(
            daoSettings,
            pluginSettings
        );

        return dao;
    }

    function _revoke(address dao, address where, address who, bytes32 permission) internal {
        (bool ok, ) = dao.call(
            abi.encodeWithSignature("revoke(address,address,bytes32)", where, who, permission)
        );
        require(ok, "Revoke failed");
    }
    /* ======== OWNERSHIP TRANSFER ======== */

    /**
     * @notice Transfer vault ownership to Owner DAO
     * @dev Final step in vault setup - transfers control to governance
     * @param vault The vault to transfer
     * @param newOwner Address of Owner DAO (2/2 multisig)
     */
    function transferOwnership(IVaultV2 vault, address newOwner) public {
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


    /* ======== INTERNAL FUNCTIONS ======== */

    function _getLockToVoteData(address votingToken) internal pure returns (bytes memory) {
        // Create the exact struct that prepareInstallation expects
        InstallationParameters memory params = InstallationParameters({
            token: votingToken,
            votingSettings: VotingSettings({
                votingMode: 0,
                supportThreshold: 500000, // 50%
                minParticipation: 1, // 0.0001%
                minApprovalRatio: 0,
                proposalDuration: 1 days,
                minProposerVotingPower: 0
            }),
            pluginMetadata: "",
            createProposalCaller: address(type(uint160).max),
            executeCaller: address(type(uint160).max),
            targetConfig: TargetConfig({
                target: address(0),
                operation: 0
            })
        });

        // Now encode it properly - Solidity will handle the nested struct encoding correctly
        return abi.encode(params);
    }

    function _getMultisigData(address sentinel, address steakhouse) internal pure returns (bytes memory) {
        address[] memory members = new address[](2);
        members[0] = sentinel;
        members[1] = steakhouse;

        // MultisigSettings struct: {bool onlyListed, uint16 minApprovals}
        return abi.encode(
            members,
            false,      // onlyListed
            uint16(2)   // minApprovals (2/2)
        );
    }

    function addLockedVotePlugin(IDAO dao, address vault) internal returns (address) {
        address daoAddress = address(dao);
        
        PluginSettings memory pluginSettings = PluginSettings({
            pluginSetupRef: PluginSetupRef({
                versionTag: PluginSettingsTag({release: 1, build: 1}),
                pluginSetupRepo: lockToVoteRepo
            }),
            data: _getLockToVoteData(vault)
        });
     
        IPluginSetupProcessor pluginSetupProcessor = IPluginSetupProcessor(address(daoFactory.pluginSetupProcessor()));

        // Create the action array
        IDAO.Action[] memory actions = new IDAO.Action[](2);

        // Grant Temporarily `ROOT_PERMISSION` to `pluginSetupProcessor`.
        actions[0] = IDAO.Action({
            to: daoAddress,
            value: 0,
            data: abi.encodeWithSelector(IDAO.grant.selector, daoAddress, address(pluginSetupProcessor), dao.ROOT_PERMISSION_ID())
        });

        // Grant Temporarily `APPLY_INSTALLATION_PERMISSION` on `pluginSetupProcessor` to this `DAOFactory`.
        actions[1] = IDAO.Action({
            to: daoAddress,
            value: 0,
            data: abi.encodeWithSelector(IDAO.grant.selector, 
                address(pluginSetupProcessor),
                address(this), 
                keccak256("APPLY_INSTALLATION_PERMISSION"))
        });

        // Execute
        IDAO(dao).execute({_callId: "", _actions: actions, _allowFailureMap: 0});
        // Grant the temporary permissions.
        // Grant Temporarily `ROOT_PERMISSION` to `pluginSetupProcessor`.
        //dao.grant(daoAddress, address(pluginSetupProcessor), dao.ROOT_PERMISSION_ID());

        // Grant Temporarily `APPLY_INSTALLATION_PERMISSION` on `pluginSetupProcessor` to this `DAOFactory`.
        /*dao.grant(
            address(pluginSetupProcessor),
            address(this),
            keccak256("APPLY_INSTALLATION_PERMISSION")
        );
*/
        (
            address plugin,
            IPluginSetup.PreparedSetupData memory preparedSetupData
        ) = pluginSetupProcessor.prepareInstallation(
                daoAddress,
                IPluginSetupProcessor.PrepareInstallationParams(
                    pluginSettings.pluginSetupRef,
                    pluginSettings.data
            )
        );

        // Apply plugin.
        pluginSetupProcessor.applyInstallation(
            daoAddress,
            IPluginSetupProcessor.ApplyInstallationParams(
                pluginSettings.pluginSetupRef,
                plugin,
                preparedSetupData.permissions,
                    keccak256(abi.encode((preparedSetupData.helpers)))
            )
        );
            

        
        // Revoke Temporarily `ROOT_PERMISSION` to `pluginSetupProcessor`.
        actions[0] = IDAO.Action({
            to: daoAddress,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, daoAddress, address(pluginSetupProcessor), dao.ROOT_PERMISSION_ID())
        });

        // Revoke Temporarily `APPLY_INSTALLATION_PERMISSION` on `pluginSetupProcessor` to this `DAOFactory`.
        actions[1] = IDAO.Action({
            to: daoAddress,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, 
                address(pluginSetupProcessor),
                address(this), 
                keccak256("APPLY_INSTALLATION_PERMISSION"))
        });

        // Execute
        IDAO(dao).execute({_callId: "", _actions: actions, _allowFailureMap: 0});

        // Revoke the temporarily granted permissions.
        // Revoke Temporarily `ROOT_PERMISSION` from `pluginSetupProcessor`.
        //dao.revoke(daoAddress, address(pluginSetupProcessor), dao.ROOT_PERMISSION_ID());

        // Revoke `APPLY_INSTALLATION_PERMISSION` on `pluginSetupProcessor` from this `DAOFactory` .
        /*dao.revoke(
            address(pluginSetupProcessor),
            address(this),
            keccak256("APPLY_INSTALLATION_PERMISSION")
        );*/

        return plugin;   
    }

}
