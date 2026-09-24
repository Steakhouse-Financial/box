// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity >=0.8.0;

/// @title IEVault
/// @notice Minimal hand-written interface for the subset of an Euler Vault Kit vault used by FundingEuler.
/// @dev Signatures match the upstream EVK `IEVault` interface (GPL-2.0-or-later). No implementation code is used.
interface IEVault {
    function EVC() external view returns (address);

    function asset() external view returns (address);

    /// @notice Vault shares held by `account`
    function balanceOf(address account) external view returns (uint256);

    /// @notice Assets for `shares`, rounded down
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @dev `amount == type(uint256).max` deposits the caller's whole balance
    function deposit(uint256 amount, address receiver) external returns (uint256);

    /// @dev Burns shares rounded up and sends exactly `amount` to `receiver`; no max sentinel
    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256);

    /// @dev `amount == type(uint256).max` redeems the owner's whole share balance
    function redeem(uint256 amount, address receiver, address owner) external returns (uint256);

    /// @dev `amount == type(uint256).max` borrows all the vault cash
    function borrow(uint256 amount, address receiver) external returns (uint256);

    /// @dev Pulls from the caller and reduces the debt of `receiver`; `amount == type(uint256).max` repays it all
    function repay(uint256 amount, address receiver) external returns (uint256);

    /// @notice Debt of `account` in assets, rounded up and including interest accrued up to now
    function debtOf(address account) external view returns (uint256);

    /// @notice Releases this vault as the controller of the authenticated account; reverts with outstanding debt
    function disableController() external;

    /// @notice Borrow LTV of `collateral` in this vault, 1e4 scale; 0 when the collateral is not configured
    function LTVBorrow(address collateral) external view returns (uint16);

    function oracle() external view returns (address);

    function unitOfAccount() external view returns (address);
}
