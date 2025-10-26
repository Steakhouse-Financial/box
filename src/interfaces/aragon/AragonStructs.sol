// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

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

// DAOFactory interface
interface IDAOFactory {
    function createDao(
        DAOSettings calldata _daoSettings,
        PluginSettings[] calldata _pluginSettings
    ) external returns (address createdDao, InstalledPlugin[] memory installedPlugins);
}
