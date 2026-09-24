// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association, Steakhouse Financial
pragma solidity ^0.8.28;

// Adapted from Morpho Midnight's ratifier `HashLib.sol`: only the offer hashing used by the Setter and Ecrecover
// ratifiers is kept, for tests that create and ratify their own lender offers.

import {CollateralParams, Market, Offer} from "../../src/interfaces/midnight/IMidnight.sol";

/// @dev keccak256("CollateralParams(address token,uint256 lltv,uint256 liquidationCursor,address oracle)")
bytes32 constant COLLATERAL_PARAMS_TYPEHASH = 0x39ed3f928d24fd00574b1a02aba9c2483abcf5d9a3a366118c9a5aa29885b841;
/// @dev keccak256(bytes.concat(MARKET_TYPE, COLLATERAL_PARAMS_TYPE))
bytes32 constant MARKET_TYPEHASH = 0x510b3862f3816a109c9340b76972e8a30984246be06e034ae12ed2934220391a;
/// @dev keccak256(bytes.concat(OFFER_TYPE, COLLATERAL_PARAMS_TYPE, MARKET_TYPE))
bytes32 constant OFFER_TYPEHASH = 0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906;

/// @title MidnightHashLib
/// @notice EIP-712 hashes of Midnight offers and offer trees (leaf = hashOffer, node = keccak256(left ++ right)).
library MidnightHashLib {
    error TreeTooHigh();

    /// @notice EIP-712 typehash of `OfferTree(Offer[2]...[2] offerTree)` with `height` levels (the proof length)
    function offerTreeTypeHash(uint256 height) internal pure returns (bytes32) {
        if (height == 0) return 0x270da1ebafc0f24637af3612fb8c3a1d828fcb56d3637c24e86dd006b12ca7f9;
        if (height == 1) return 0x828b9cdf8326a1cf234328e4d5229546a98fb72ef73624f5b6b31538e555b96c;
        if (height == 2) return 0xfcb7a3ca4094246b8185620c4cf025c93032b6f0384805aa3f22afe04290e982;
        if (height == 3) return 0xcc97cb1955496a5269b5a7afca62ba694edcab26ba838a1adbd257931249de92;
        revert TreeTooHigh();
    }

    function hashNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function hashCollateralParams(CollateralParams memory collateralParams) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    COLLATERAL_PARAMS_TYPEHASH,
                    collateralParams.token,
                    collateralParams.lltv,
                    collateralParams.liquidationCursor,
                    collateralParams.oracle
                )
            );
    }

    function hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes = new bytes32[](market.collateralParams.length);
        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            collateralParamsHashes[i] = hashCollateralParams(market.collateralParams[i]);
        }
        return
            keccak256(
                abi.encode(
                    MARKET_TYPEHASH,
                    market.chainId,
                    market.midnight,
                    market.loanToken,
                    keccak256(abi.encodePacked(collateralParamsHashes)),
                    market.maturity,
                    market.rcfThreshold,
                    market.enterGate,
                    market.liquidatorGate
                )
            );
    }

    /// @notice Leaf hash of an offer. The `ratifier` field is part of it: set it before hashing.
    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    OFFER_TYPEHASH,
                    hashMarket(offer.market),
                    offer.buy,
                    offer.maker,
                    offer.start,
                    offer.expiry,
                    offer.tick,
                    offer.group,
                    offer.callback,
                    keccak256(offer.callbackData),
                    offer.receiverIfMakerIsSeller,
                    offer.ratifier,
                    offer.reduceOnly,
                    offer.maxUnits,
                    offer.maxAssets,
                    offer.continuousFeeCap
                )
            );
    }
}
