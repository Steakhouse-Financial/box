// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity >=0.8.0;

// Adapted from Morpho Midnight's `IMidnight.sol`: trimmed to the members used by Box. The structs keep the upstream
// field order and types so that their ABI encoding (and therefore market ids) matches the deployed contract.

/// @notice Parameters of one collateral of a Midnight market.
/// @dev `lltv` and `liquidationCursor` are WAD. `oracle` returns the price of 1 collateral unit in loan-token units,
/// scaled by 1e36 (same convention as Box oracles).
struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

/// @notice A Midnight market. Each maturity is its own market; the id is derived from the whole struct.
/// @dev `collateralParams` is sorted strictly ascending by token address. `enterGate`/`liquidatorGate` are 0 when unused.
struct Market {
    uint256 chainId;
    address midnight;
    address loanToken;
    CollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

/// @notice A maker offer. `buy == true` means the maker buys units (lends); the taker is then the seller (borrower).
/// @dev Exactly one of `maxUnits` / `maxAssets` is non-zero. For buy offers `maxAssets` caps the cumulative buyer assets
/// consumed in `group`, and `receiverIfMakerIsSeller` must be 0.
struct Offer {
    Market market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;
    uint256 continuousFeeCap;
}

/// @title IMidnight
/// @notice Minimal interface of Morpho Midnight (fixed-rate, fixed-term lending) used by Box.
interface IMidnight {
    /// @notice Takes `units` of `offer`. For a buy offer the taker sells units: its debt grows by `units` and
    /// `sellerAssets` of loan token are sent to `receiverIfTakerIsSeller`.
    /// @dev No min-proceeds argument: the caller must enforce the price. Reverts if the taker ends up unhealthy.
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    /// @notice Repays `units` of debt of `onBehalf`, pulling exactly `units` loan tokens from `callback` if non-zero,
    /// otherwise from the caller. Reverts if `units` exceeds the debt.
    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory data) external;

    /// @notice Supplies `assets` of `market.collateralParams[collateralIndex].token` from the caller to `onBehalf`.
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external;

    /// @notice Withdraws `assets` of collateral of `onBehalf` to `receiver`. Reverts if `onBehalf` ends up unhealthy.
    function withdrawCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf, address receiver) external;

    /// @notice Face value (units of loan token due at maturity) owed by `user` in market `id`.
    function debt(bytes32 id, address user) external view returns (uint128);

    /// @notice Collateral of `user` at `index` in market `id`.
    function collateral(bytes32 id, address user, uint256 index) external view returns (uint128);

    /// @notice Credit (units owned as a lender) of `user` in market `id`.
    function credit(bytes32 id, address user) external view returns (uint128);

    /// @notice Amount already consumed from the offers of `user` in `group` (buyer assets or units, per offer cap type).
    function consumed(address user, bytes32 group) external view returns (uint128);

    /// @notice Settlement fee (WAD, per unit) charged to the taker of market `id` at `timeToMaturity`.
    /// @dev Reverts `MarketNotCreated` if the market does not exist.
    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

    /// @notice Tick spacing of market `id`; 0 means the market has not been created.
    function tickSpacing(bytes32 id) external view returns (uint8);

    /// @notice Continuous fee (WAD per second) charged to the lenders of market `id`.
    function continuousFee(bytes32 id) external view returns (uint32);
}
