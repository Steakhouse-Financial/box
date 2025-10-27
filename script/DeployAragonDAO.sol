// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import "../src/interfaces/Aragon.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title DeployAragonDAO
 * @notice Creates Aragon DAOs using proper struct encoding
 */
contract DeployAragonDAO is Script {

    // Base (Chain ID: 8453)
    address constant DAO_FACTORY_BASE = 0xcc602EA573a42eBeC290f33F49D4A87177ebB8d2;
    address constant LOCKTOVOTE_REPO_BASE = 0x05ECA5ab78493Bf812052B0211a206BCBA03471B;
    address constant MULTISIG_REPO_BASE = 0xcDC4b0BC63AEfFf3a7826A19D101406C6322A585;

    // Ethereum Mainnet (Chain ID: 1)
    // https://github.com/aragon/osx/blob/c931aa6929c7631a01453ad4a2ba707e4849ae82/packages/artifacts/src/addresses.json#L25-L47
    // https://github.com/aragon/app/blob/e7694505c3525c69a3137c4305691f7e440113f0/src/plugins/lockToVotePlugin/constants/lockToVotePlugin.ts#L18
    // https://github.com/aragon/app/blob/e7694505c3525c69a3137c4305691f7e440113f0/src/plugins/multisigPlugin/constants/multisigPlugin.ts#L17
    address constant DAO_FACTORY_MAINNET = 0x246503df057A9a85E0144b6867a828c99676128B;
    address constant LOCKTOVOTE_REPO_MAINNET = 0x0f4FBD2951Db08B45dE16e7519699159aE1b4bb7;
    address constant MULTISIG_REPO_MAINNET = 0x8c278e37D0817210E18A7958524b7D0a1fAA6F7b;

    function _getAddresses() internal view returns (address daoFactory, address lockToVoteRepo, address multisigRepo) {
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            return (DAO_FACTORY_MAINNET, LOCKTOVOTE_REPO_MAINNET, MULTISIG_REPO_MAINNET);
        } else if (chainId == 8453) {
            return (DAO_FACTORY_BASE, LOCKTOVOTE_REPO_BASE, MULTISIG_REPO_BASE);
        } else {
            revert("Unsupported chain");
        }
    }

    struct DAOResult {
        address dao;
        address plugin;
        address lockManager;
    }

    /**
     * @notice Create Sentinel DAO with LockToVote
     */
    function createSentinelDAO(
        address votingToken,
        string memory metadataURI
    ) public returns (DAOResult memory result) {
        console.log("Creating Sentinel DAO...");

        (address daoFactory, address lockToVoteRepo,) = _getAddresses();

        DAOSettings memory daoSettings = DAOSettings({
            trustedForwarder: address(0),
            daoURI: metadataURI,
            subdomain: "",
            metadata: ""
        });

        PluginSettings[] memory pluginSettings = new PluginSettings[](1);
        pluginSettings[0] = PluginSettings({
            pluginSetupRef: PluginSetupRef({
                versionTag: PluginSettingsTag({release: 1, build: 1}),
                pluginSetupRepo: lockToVoteRepo
            }),
            data: _getLockToVoteData(votingToken)
        });

        (address dao, InstalledPlugin[] memory installedPlugins) = IDAOFactory(daoFactory).createDao(
            daoSettings,
            pluginSettings
        );

        result.dao = dao;
        if (installedPlugins.length > 0) {
            result.plugin = installedPlugins[0].plugin;
            // LockManager is second helper (index 1)
            if (installedPlugins[0].preparedSetupData.helpers.length > 1) {
                result.lockManager = installedPlugins[0].preparedSetupData.helpers[1];
            }
        }

        console.log("DAO created:", dao);
        console.log("Plugin:", result.plugin);
        console.log("LockManager:", result.lockManager);

        // Make immutable
        _makeSentinelImmutable(dao, result.plugin, result.lockManager, votingToken);

        return result;
    }

    /**
     * @notice Create Owner DAO with Multisig
     */
    function createOwnerDAO(
        address sentinel,
        address steakhouse,
        string memory metadataURI
    ) public returns (DAOResult memory result) {
        console.log("Creating Owner DAO...");

        (address daoFactory,, address multisigRepo) = _getAddresses();

        DAOSettings memory daoSettings = DAOSettings({
            trustedForwarder: address(0),
            daoURI: metadataURI,
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

        result.dao = dao;
        if (installedPlugins.length > 0) {
            result.plugin = installedPlugins[0].plugin;
        }
        result.lockManager = address(0);

        console.log("DAO created:", dao);
        console.log("Plugin:", result.plugin);

        // Remove deployer admin
        _removeOwnerAdmin(dao);

        return result;
    }

    /* ======== INTERNAL HELPERS ======== */

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

    function _makeSentinelImmutable(address dao, address plugin, address lockManager, address votingToken) internal {
        if (plugin == address(0)) {
            console.log("WARNING: Plugin address is 0, skipping immutability");
            return;
        }

        console.log("Making Sentinel DAO immutable via proposal...");

        bytes32 ROOT = keccak256("ROOT_PERMISSION");
        bytes32 UPGRADE = keccak256("UPGRADE_DAO_PERMISSION");
        bytes32 UPDATE_VOTING = keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");

        // Create actions to revoke permissions
        ILockToVotePlugin.Action[] memory actions = new ILockToVotePlugin.Action[](3);

        // 1. Revoke UPDATE_VOTING_SETTINGS_PERMISSION from plugin
        actions[0] = ILockToVotePlugin.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, plugin, dao, UPDATE_VOTING)
        });

        // 2. Revoke UPGRADE_DAO_PERMISSION from DAO
        actions[1] = ILockToVotePlugin.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, dao, dao, UPGRADE)
        });

        // 3. Revoke ROOT_PERMISSION from DAO (makes it fully immutable)
        actions[2] = ILockToVotePlugin.Action({
            to: dao,
            value: 0,
            data: abi.encodeWithSelector(IDAO.revoke.selector, dao, dao, ROOT)
        });

        // Create proposal
        uint256 proposalId = ILockToVotePlugin(plugin).createProposal(
            bytes("Make Sentinel DAO immutable"),
            actions,
            uint64(0),   // startDate (0 = now)
            uint64(0),   // endDate (0 = use plugin default duration, typically 3 days)
            ""           // data: empty bytes
        );

        console.log("Immutability proposal created:", proposalId);
        console.log("To complete immutability:");
        console.log("  1. Lock vault shares: lockManager.lock(amount)");
        console.log("  2. Vote YES: lockManager.vote(proposalId, 3)");
        console.log("  3. Wait for voting period (3 days)");
        console.log("  4. Execute: plugin.execute(proposalId)");
    }

    function _removeOwnerAdmin(address dao) internal {
        console.log("NOTICE: Deployer EXECUTE_PERMISSION will be removed automatically by Aragon");
        // The Aragon DAOFactory automatically removes temporary permissions after setup
        // No manual revocation needed
    }

    function _revoke(address dao, address where, address who, bytes32 permission) internal {
        (bool ok, ) = dao.call(
            abi.encodeWithSignature("revoke(address,address,bytes32)", where, who, permission)
        );
        require(ok, "Revoke failed");
    }
}
