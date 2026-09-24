// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity ^0.8.28;

// Test-only members of Morpho Midnight and of its two deployed ratifiers, adapted from Morpho Midnight's interfaces.
// The module itself only needs `src/interfaces/midnight/IMidnight.sol`.

import {IMidnight, Market, Offer} from "../../src/interfaces/midnight/IMidnight.sol";

/// @notice Cheatcodes implemented by forge but not declared by the vendored forge-std `Vm`.
/// @dev Midnight's bytecode uses the Osaka `CLZ` opcode while the repository compiles for prague: fork tests switch
///      the execution EVM right after forking, without changing the compile target.
interface IVmEvmVersion {
    function setEvmVersion(string calldata evm) external;

    function getEvmVersion() external view returns (string memory);
}

/// @notice Midnight members used by tests only (authorisations, liquidations, cancellations, raw market views).
interface IMidnightTest is IMidnight {
    error CannotIncreaseDebtPostMaturity();
    error NotLiquidatable();
    error OfferExpired();
    error SellerIsLiquidatable();
    error UnhealthyBorrower();

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @dev type(uint128).max cancels every offer of the group
    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external;

    /// @dev One of `seizedAssets` / `repaidUnits` must be 0. `postMaturityMode` requires block.timestamp > maturity.
    function liquidate(
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool postMaturityMode,
        address receiver,
        address callback,
        bytes memory data
    ) external returns (uint256 seized, uint256 repaid);

    /// @dev Uses the Osaka `CLZ` opcode
    function isHealthy(Market memory market, bytes32 id, address borrower) external view returns (bool);

    function toMarket(bytes32 id) external view returns (Market memory);

    function totalUnits(bytes32 id) external view returns (uint128);
}

/// @notice Maker callback of a buy offer, called by `take` after the seller's debt grew and before the payer pays.
/// @dev When an offer names a callback, the callback is also the payer of the buyer assets.
interface IBuyCallback {
    function onBuy(
        bytes32 id,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    ) external returns (bytes32);
}

/// @notice Ratifies a Merkle root of offers registered on chain by the maker (or an address it authorised on Midnight).
/// @dev ratifierData = abi.encode(bytes32 root, uint256 leafIndex, bytes32[] proof)
interface ISetterRatifier {
    function setIsRootRatified(address maker, bytes32 root, bool newIsRootRatified) external;

    function isRootRatified(address maker, bytes32 root) external view returns (bool);

    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);

    // solhint-disable-next-line func-name-mixedcase
    function MIDNIGHT() external view returns (address);
}

/// @notice ECDSA signature of an offer tree root, as expected by the EcrecoverRatifier.
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @dev keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")
bytes32 constant EIP712_DOMAIN_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

/// @notice Ratifies a Merkle root of offers signed (EIP-712) by the maker or an address it authorised on Midnight.
/// @dev ratifierData = abi.encode(Signature signature, bytes32 root, uint256 leafIndex, bytes32[] proof)
interface IEcrecoverRatifier {
    function cancelRoot(address maker, bytes32 root) external;

    function isRootCanceled(address maker, bytes32 root) external view returns (bool);

    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);

    // solhint-disable-next-line func-name-mixedcase
    function MIDNIGHT() external view returns (address);
}
