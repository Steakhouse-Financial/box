// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity >=0.8.0;

/// @title IEVC
/// @notice Minimal hand-written interface for the subset of the Ethereum Vault Connector used by FundingEuler.
/// @dev Signatures match the upstream `IEthereumVaultConnector` (GPL-2.0-or-later).
interface IEVC {
    /// @notice Adds `vault` to the collateral set of `account` (idempotent), then requires an account status check
    function enableCollateral(address account, address vault) external payable;

    /// @notice Removes `vault` from the collateral set of `account` (idempotent), then requires an account status check
    function disableCollateral(address account, address vault) external payable;

    /// @notice Adds `vault` to the controller set of `account` (idempotent), then requires an account status check
    function enableController(address account, address vault) external payable;

    function isCollateralEnabled(address account, address vault) external view returns (bool);

    function isControllerEnabled(address account, address vault) external view returns (bool);

    /// @notice Calls `targetContract` with `onBehalfOfAccount` as the authenticated account, bubbling any revert
    /// @dev Deferred account and vault status checks run when the outermost call frame exits
    function call(
        address targetContract,
        address onBehalfOfAccount,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result);
}
