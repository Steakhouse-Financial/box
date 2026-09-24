// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Steakhouse Financial
pragma solidity 0.8.28;

/// @title IAaveV4Spoke
/// @notice Minimal hand-written interface for the subset of an Aave v4 Spoke used by Box.
/// @dev Written from the deployed ABI. Struct layouts are ABI-compatible with the deployed Spoke.
interface IAaveV4Spoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        /// @dev Key of the latest dynamic config of the reserve
        uint32 dynamicConfigKey;
    }

    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    struct DynamicReserveConfig {
        /// @dev Basis points (1e4 = 100%)
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    struct UserPosition {
        uint120 drawnShares;
        uint120 premiumShares;
        int200 premiumOffsetRay;
        uint120 suppliedShares;
        uint32 dynamicConfigKey;
    }

    struct UserAccountData {
        /// @dev Basis points
        uint256 riskPremium;
        /// @dev WAD
        uint256 avgCollateralFactor;
        /// @dev WAD, type(uint256).max when there is no debt
        uint256 healthFactor;
        /// @dev Value units; only enabled collaterals with a non-zero collateral factor are counted
        uint256 totalCollateralValue;
        /// @dev Value units scaled by 1e27
        uint256 totalDebtValueRay;
        uint256 activeCollateralCount;
        uint256 borrowCount;
    }

    // Actions: the caller must be `onBehalfOf` (or a position manager approved by it).

    /// @dev Pulls exactly `amount` from the caller. Does not enable the reserve as collateral.
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets);

    /// @dev Sends the assets to the caller. `amount` is capped at the withdrawable balance.
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets);

    /// @dev Sends exactly `amount` to the caller.
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets);

    /// @dev Pulls from the caller at most the total debt (premium first); returns the amount actually repaid.
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets);

    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;

    // Reserve views: all revert for an unlisted reserveId, except getReserveCount.

    function getReserveCount() external view returns (uint256);

    function getReserve(uint256 reserveId) external view returns (Reserve memory);

    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);

    function getDynamicReserveConfig(uint256 reserveId, uint32 dynamicConfigKey) external view returns (DynamicReserveConfig memory);

    // User views: revert for an unlisted reserveId, return 0 for a user without a position.

    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool usingAsCollateral, bool borrowing);

    /// @dev Rounded down
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);

    /// @dev Both rounded up
    function getUserDebt(uint256 reserveId, address user) external view returns (uint256 drawnDebt, uint256 premiumDebt);

    /// @dev Drawn plus premium debt, rounded up
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);

    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory);

    /// @dev Calls the Spoke oracle and uses the user's stored (possibly stale) dynamic config keys.
    function getUserAccountData(address user) external view returns (UserAccountData memory);

    function ORACLE() external view returns (address);
}
