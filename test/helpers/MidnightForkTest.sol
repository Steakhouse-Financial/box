// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OfferFill} from "../../src/FundingMidnight.sol";
import {Market, Offer} from "../../src/interfaces/midnight/IMidnight.sol";
import {MidnightAddresses} from "./MidnightAddresses.sol";
import {MidnightHashLib} from "./MidnightHashLib.sol";
import {EIP712_DOMAIN_TYPEHASH, IMidnightTest, ISetterRatifier, Signature} from "./MidnightTestInterfaces.sol";

/**
 * @title Shared helpers for fork tests against a real Morpho Midnight deployment
 * @dev Creates a test lender and its bids (buy offers), ratified either by on-chain registration (SetterRatifier) or
 *      by an EIP-712 signature (EcrecoverRatifier). Concrete tests set `midnight` and the two ratifiers in `setUp`.
 */
abstract contract MidnightForkTest is Test, MidnightAddresses {
    uint256 internal constant LENDER_PK = 0xA11CE;

    IMidnightTest internal midnight;
    address internal setterRatifier;
    address internal ecrecoverRatifier;
    address internal lender;

    /// @dev Funds the lender with `amount` loan tokens and authorises both ratifiers on its behalf. The offers created
    ///      here have no callback, so the lender itself pays the proceeds.
    function _setUpLender(IERC20 loanToken, uint256 amount) internal {
        lender = vm.addr(LENDER_PK);
        deal(address(loanToken), lender, amount);
        vm.startPrank(lender);
        loanToken.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(setterRatifier, true, lender);
        midnight.setIsAuthorized(ecrecoverRatifier, true, lender);
        vm.stopPrank();
    }

    /// @dev Lender bid capped in buyer assets, valid from now until 30 days after maturity
    function _bid(
        Market memory market,
        address ratifier,
        uint256 tick,
        bytes32 group,
        uint128 maxAssets
    ) internal view returns (Offer memory offer) {
        offer.market = market;
        offer.buy = true;
        offer.maker = lender;
        offer.start = block.timestamp;
        offer.expiry = market.maturity + 30 days;
        offer.tick = tick;
        offer.group = group;
        offer.ratifier = ratifier;
        offer.maxAssets = maxAssets;
        offer.continuousFeeCap = type(uint256).max;
    }

    /// @dev Single-leaf tree (root = leaf, empty proof) registered on chain by the lender
    function _ratifyWithSetter(Offer memory offer) internal returns (bytes memory ratifierData) {
        require(offer.ratifier == setterRatifier, "not a SetterRatifier offer");
        bytes32 root = MidnightHashLib.hashOffer(offer);
        vm.prank(offer.maker);
        ISetterRatifier(setterRatifier).setIsRootRatified(offer.maker, root, true);
        ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
    }

    /// @dev Single-leaf tree signed by the lender for the EcrecoverRatifier (EIP-712, domain = chain id + ratifier)
    function _signForEcrecover(Offer memory offer) internal view returns (bytes memory ratifierData) {
        require(offer.ratifier == ecrecoverRatifier, "not an EcrecoverRatifier offer");
        require(offer.maker == vm.addr(LENDER_PK), "maker is not the signing lender");
        bytes32 root = MidnightHashLib.hashOffer(offer);
        bytes32 structHash = keccak256(abi.encode(MidnightHashLib.offerTreeTypeHash(0), root));
        bytes32 domainSeparator = keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, block.chainid, ecrecoverRatifier));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, keccak256(bytes.concat("\x19\x01", domainSeparator, structHash)));
        ratifierData = abi.encode(Signature(v, r, s), root, uint256(0), new bytes32[](0));
    }

    function _fills(Offer memory offer, bytes memory ratifierData) internal pure returns (OfferFill[] memory fills) {
        fills = new OfferFill[](1);
        fills[0] = OfferFill(offer, ratifierData, type(uint256).max);
    }

    function _fills(
        Offer memory offer0,
        bytes memory ratifierData0,
        Offer memory offer1,
        bytes memory ratifierData1
    ) internal pure returns (OfferFill[] memory fills) {
        fills = new OfferFill[](2);
        fills[0] = OfferFill(offer0, ratifierData0, type(uint256).max);
        fills[1] = OfferFill(offer1, ratifierData1, type(uint256).max);
    }
}
