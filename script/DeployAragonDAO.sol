// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import "../src/interfaces/aragon/AragonStructs.sol";
import "../src/interfaces/aragon/LockToVoteStructs.sol";
import "../src/interfaces/aragon/AragonInterfaces.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/**
 * @title DeployAragonDAO
 * @notice Creates Aragon DAOs using proper struct encoding
 */
contract DeployAragonDAO is Script {

    address constant DAO_FACTORY = 0xcc602EA573a42eBeC290f33F49D4A87177ebB8d2;
    address constant LOCKTOVOTE_REPO = 0x05ECA5ab78493Bf812052B0211a206BCBA03471B;
    address constant MULTISIG_REPO = 0xcDC4b0BC63AEfFf3a7826A19D101406C6322A585;

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
                pluginSetupRepo: LOCKTOVOTE_REPO
            }),
            data: _getLockToVoteData(votingToken)
        });

        (address dao, InstalledPlugin[] memory installedPlugins) = IDAOFactory(DAO_FACTORY).createDao(
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
                pluginSetupRepo: MULTISIG_REPO
            }),
            data: _getMultisigData(sentinel, steakhouse)
        });

        (address dao, InstalledPlugin[] memory installedPlugins) = IDAOFactory(DAO_FACTORY).createDao(
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
                proposalDuration: 3 days,
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
