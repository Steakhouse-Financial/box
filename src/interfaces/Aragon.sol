// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.0;

// Exact struct definitions from Aragon OSx DAOFactory
struct DAOSettings {
    address trustedForwarder;
    string daoURI;
    string subdomain;
    bytes metadata;
}

struct PluginSettingsTag {
    uint8 release;
    uint16 build;
}

struct PluginSetupRef {
    PluginSettingsTag versionTag;
    address pluginSetupRepo;
}

struct PluginSettings {
    PluginSetupRef pluginSetupRef;
    bytes data;
}

// PreparedSetupData from IPluginSetup
struct PreparedSetupData {
    address[] helpers;
    bytes permissions;
}

// InstalledPlugin struct from DAOFactory
struct InstalledPlugin {
    address plugin;
    PreparedSetupData preparedSetupData;
}

struct VotingSettings {
    uint8 votingMode;
    uint32 supportThreshold;
    uint32 minParticipation;
    uint32 minApprovalRatio;
    uint64 proposalDuration;
    uint256 minProposerVotingPower;
}

struct TargetConfig {
    address target;
    uint8 operation;
}

struct InstallationParameters {
    address token;
    VotingSettings votingSettings;
    bytes pluginMetadata;
    address createProposalCaller;
    address executeCaller;
    TargetConfig targetConfig;
}
/// @title PermissionLib
/// @author Aragon X - 2021-2023
/// @notice A library containing objects for permission processing.
/// @custom:security-contact sirt@aragon.org
library PermissionLib {
    /// @notice The types of permission operations available in the `PermissionManager`.
    /// @param Grant The grant operation setting a permission without a condition.
    /// @param Revoke The revoke operation removing a permission (that was granted with or without a condition).
    /// @param GrantWithCondition The grant operation setting a permission with a condition.
    enum Operation {
        Grant,
        Revoke,
        GrantWithCondition
    }

    /// @notice A struct containing the information for a permission to be applied on a single target contract without a condition.
    /// @param operation The permission operation type.
    /// @param who The address (EOA or contract) receiving the permission.
    /// @param permissionId The permission identifier.
    struct SingleTargetPermission {
        Operation operation;
        address who;
        bytes32 permissionId;
    }

    /// @notice A struct containing the information for a permission to be applied on multiple target contracts, optionally, with a condition.
    /// @param operation The permission operation type.
    /// @param where The address of the target contract for which `who` receives permission.
    /// @param who The address (EOA or contract) receiving the permission.
    /// @param condition The `PermissionCondition` that will be asked for authorization on calls connected to the specified permission identifier.
    /// @param permissionId The permission identifier.
    struct MultiTargetPermission {
        Operation operation;
        address where;
        address who;
        address condition;
        bytes32 permissionId;
    }
}

/**
 * @title Aragon Interfaces
 * @notice Minimal interfaces for interacting with Aragon DAOs
 * @dev Used by deployment scripts to interact with deployed DAOs
 */

/**
 * @notice Interface for Aragon LockManager (helper contract from LockToVote plugin)
 */
interface ILockManager {
    function lock(uint256 _amount) external;
    function unlock(uint256 _amount) external;
    function vote(uint256 _proposalId, uint8 _voteOption) external;
    function getVotingPower(address _account) external view returns (uint256);
}

/**
 * @notice Interface for Aragon LockToVote plugin
 */
interface ILockToVotePlugin {
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    function createProposal(
        bytes calldata _metadata,
        Action[] memory _actions,
        uint64 _startDate,
        uint64 _endDate,
        bytes memory _data
    ) external returns (uint256 proposalId);

    function execute(uint256 _proposalId) external;

    function canExecute(uint256 _proposalId) external view returns (bool);
}

/**
 * @notice Interface for Aragon Multisig plugin
 */
interface IMultisig {
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    function createProposal(
        bytes calldata _metadata,
        Action[] memory _actions,
        uint256 _allowFailureMap
    ) external returns (uint256 proposalId);

    function approve(uint256 _proposalId) external;

    function execute(uint256 _proposalId) external;

    function canApprove(uint256 _proposalId, address _account) external view returns (bool);

    function canExecute(uint256 _proposalId) external view returns (bool);
}

/**
 * @notice Interface for Aragon DAO
 */
interface IDAO {
    function hasPermission(address _where, address _who, bytes32 _permissionId, bytes memory _data) external view returns (bool);

    function grant(address _where, address _who, bytes32 _permissionId) external;

    function revoke(address _where, address _who, bytes32 _permissionId) external;

    function execute(bytes32 _callId, Action[] memory _actions, uint256 _allowFailureMap) external returns (bytes[] memory, uint256);

    function ROOT_PERMISSION_ID() external returns (bytes32);

    struct Action {
        address to;
        uint256 value;
        bytes data;
    }
}


/// @notice DAOFactory interface
interface IDAOFactory {
    function createDao(
        DAOSettings calldata _daoSettings,
        PluginSettings[] calldata _pluginSettings
    ) external returns (address createdDao, InstalledPlugin[] memory installedPlugins);
    function pluginSetupProcessor() external returns (address);
}

interface IPluginSetup {
    /// @notice The data associated with a prepared setup.
    /// @param helpers The address array of helpers (contracts or EOAs) associated with this plugin version after the installation or update.
    /// @param permissions The array of multi-targeted permission operations to be applied by the `PluginSetupProcessor` to the installing or updating DAO.
    struct PreparedSetupData {
        address[] helpers;
        PermissionLib.MultiTargetPermission[] permissions;
    }

    /// @notice The payload for plugin updates and uninstallations containing the existing contracts as well as optional data to be consumed by the plugin setup.
    /// @param plugin The address of the `Plugin`.
    /// @param currentHelpers The address array of all current helpers (contracts or EOAs) associated with the plugin to update from.
    /// @param data The bytes-encoded data containing the input parameters for the preparation of update/uninstall as specified in the corresponding ABI on the version's metadata.
    struct SetupPayload {
        address plugin;
        address[] currentHelpers;
        bytes data;
    }

    /// @notice Prepares the installation of a plugin.
    /// @param _dao The address of the installing DAO.
    /// @param _data The bytes-encoded data containing the input parameters for the installation as specified in the plugin's build metadata JSON file.
    /// @return plugin The address of the `Plugin` contract being prepared for installation.
    /// @return preparedSetupData The deployed plugin's relevant data which consists of helpers and permissions.
    function prepareInstallation(
        address _dao,
        bytes calldata _data
    ) external returns (address plugin, PreparedSetupData memory preparedSetupData);

    /// @notice Prepares the update of a plugin.
    /// @param _dao The address of the updating DAO.
    /// @param _fromBuild The build number of the plugin to update from.
    /// @param _payload The relevant data necessary for the `prepareUpdate`. See above.
    /// @return initData The initialization data to be passed to upgradeable contracts when the update is applied in the `PluginSetupProcessor`.
    /// @return preparedSetupData The deployed plugin's relevant data which consists of helpers and permissions.
    function prepareUpdate(
        address _dao,
        uint16 _fromBuild,
        SetupPayload calldata _payload
    ) external returns (bytes memory initData, PreparedSetupData memory preparedSetupData);

    /// @notice Prepares the uninstallation of a plugin.
    /// @param _dao The address of the uninstalling DAO.
    /// @param _payload The relevant data necessary for the `prepareUninstallation`. See above.
    /// @return permissions The array of multi-targeted permission operations to be applied by the `PluginSetupProcessor` to the uninstalling DAO.
    function prepareUninstallation(
        address _dao,
        SetupPayload calldata _payload
    ) external returns (PermissionLib.MultiTargetPermission[] memory permissions);

    /// @notice Returns the plugin implementation address.
    /// @return The address of the plugin implementation contract.
    /// @dev The implementation can be instantiated via the `new` keyword, cloned via the minimal proxy pattern (see [ERC-1167](https://eips.ethereum.org/EIPS/eip-1167)), or proxied via the UUPS proxy pattern (see [ERC-1822](https://eips.ethereum.org/EIPS/eip-1822)).
    function implementation() external view returns (address);
}


interface IPluginSetupProcessor {

    /// @notice A struct containing information related to plugin setups that have been applied.
    /// @param blockNumber The block number at which the `applyInstallation`, `applyUpdate` or `applyUninstallation` was executed.
    /// @param currentAppliedSetupId The current setup id that plugin holds. Needed to confirm that `prepareUpdate` or `prepareUninstallation` happens for the plugin's current/valid dependencies.
    /// @param preparedSetupIdToBlockNumber The mapping between prepared setup IDs and block numbers at which `prepareInstallation`, `prepareUpdate` or `prepareUninstallation` was executed.
    struct PluginState {
        uint256 blockNumber;
        bytes32 currentAppliedSetupId;
        mapping(bytes32 => uint256) preparedSetupIdToBlockNumber;
    }


    /// @notice The struct containing the parameters for the `prepareInstallation` function.
    /// @param pluginSetupRef The reference to the plugin setup to be used for the installation.
    /// @param data The bytes-encoded data containing the input parameters for the installation preparation as specified in the corresponding ABI on the version's metadata.
    struct PrepareInstallationParams {
        PluginSetupRef pluginSetupRef;
        bytes data;
    }

    /// @notice The struct containing the parameters for the `applyInstallation` function.
    /// @param pluginSetupRef The reference to the plugin setup used for the installation.
    /// @param plugin The address of the plugin contract to be installed.
    /// @param permissions The array of multi-targeted permission operations to be applied by the `PluginSetupProcessor` to the DAO.
    /// @param helpersHash The hash of helpers that were deployed in `prepareInstallation`. This helps to derive the setup ID.
    struct ApplyInstallationParams {
        PluginSetupRef pluginSetupRef;
        address plugin;
        PermissionLib.MultiTargetPermission[] permissions;
        bytes32 helpersHash;
    }

    /// @notice Prepares the installation of a plugin.
    /// @param _dao The address of the installing DAO.
    /// @param _params The struct containing the parameters for the `prepareInstallation` function.
    /// @return plugin The prepared plugin contract address.
    /// @return preparedSetupData The data struct containing the array of helper contracts and permissions that the setup has prepared.
    function prepareInstallation(
        address _dao,
        PrepareInstallationParams calldata _params
    ) external returns (address plugin, IPluginSetup.PreparedSetupData memory preparedSetupData) ;

    /// @notice Applies the permissions of a prepared installation to a DAO.
    /// @param _dao The address of the installing DAO.
    /// @param _params The struct containing the parameters for the `applyInstallation` function.
    function applyInstallation(
        address _dao,
        ApplyInstallationParams calldata _params
    ) external;

}
