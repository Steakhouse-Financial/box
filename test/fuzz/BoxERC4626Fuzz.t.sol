// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Stateless fuzzing of Box's ERC-4626 surface on a real Box with fuzzed asset decimals and pre-existing state
/// (other holders, an 18-decimals Box token held by the Box whose oracle price moves after they deposited).
contract BoxERC4626FuzzTest is Test {
    using BoxLib for IBox;

    /// @dev Amount bounds in whole units of the asset (or of shares / tokens, 18 decimals)
    uint256 internal constant MAX_UNITS = 1e12;
    uint256 internal constant ACTIONS = 12;

    address internal owner = address(0x1);
    address internal curator = address(0x3);
    address internal feeder = address(0x5);
    address internal otherFeeder = address(0x6);
    address internal holder = address(0x7);
    address internal otherHolder = address(0x8);

    ERC20MockDecimals internal asset;
    ERC20MockDecimals internal token;
    MockOracle internal oracle;
    IBox internal box;
    uint256 internal unit;
    uint256 internal virtualShares;

    struct PreState {
        uint256 decimalsSeed;
        uint256 othersDeposit;
        uint256 tokenBalance;
        uint256 priceSeed;
    }

    /////////////////////////////
    /// SETUP HELPERS
    /////////////////////////////

    /// @dev Picks 6 or 18 decimals two thirds of the time so both extremes are always covered, otherwise any value in [6, 18]
    function _decimals(uint256 seed) internal pure returns (uint8) {
        uint256 choice = seed % 3;
        if (choice == 0) return 6;
        if (choice == 1) return 18;
        return uint8(6 + ((seed / 3) % 13));
    }

    function _deployBox(PreState memory pre) internal {
        uint8 assetDecimals = _decimals(pre.decimalsSeed);
        unit = 10 ** assetDecimals;
        virtualShares = 10 ** (18 - assetDecimals);

        asset = new ERC20MockDecimals(assetDecimals);
        token = new ERC20MockDecimals(18);
        // One whole token is worth one whole asset unit
        uint256 initialPrice = (1e36 * unit) / 1e18;
        oracle = new MockOracle(initialPrice);

        box = IBox(address(new Box(address(asset), owner, curator, "Box Fuzz", "BOXF", 0.01 ether, 7 days, 10 days, 7 days)));

        vm.startPrank(curator);
        box.addFeederInstant(feeder);
        box.addFeederInstant(otherFeeder);
        box.addTokenInstant(token, oracle);
        vm.stopPrank();

        // Pre-existing token position, then other holders deposit, then the token price moves (NAV change)
        token.mint(address(box), bound(pre.tokenBalance, 0, MAX_UNITS * 1e18));
        _deposit(otherFeeder, otherFeeder, bound(pre.othersDeposit, unit, MAX_UNITS * unit));
        oracle.setPrice(bound(pre.priceSeed, 0, 10 * initialPrice));

        assertGt(box.totalAssets(), 0, "non-zero NAV");
    }

    function _deposit(address caller, address receiver, uint256 assets) internal returns (uint256 shares) {
        asset.mint(caller, assets);
        vm.startPrank(caller);
        asset.approve(address(box), assets);
        shares = box.deposit(assets, receiver);
        vm.stopPrank();
    }

    /////////////////////////////
    /// VAL-FUZZ-002: ROUND TRIPS NEVER CREATE VALUE
    /////////////////////////////

    function testFuzz_DepositThenRedeemNeverCreatesValue(PreState memory pre, uint256 assets) public {
        _deployBox(pre);
        assets = bound(assets, 1, MAX_UNITS * unit);

        asset.mint(feeder, assets);
        vm.startPrank(feeder);
        asset.approve(address(box), assets);
        uint256 expectedShares = box.previewDeposit(assets);
        uint256 shares = box.deposit(assets, feeder);
        assertEq(shares, expectedShares, "deposit returns previewDeposit");
        assertEq(box.balanceOf(feeder), shares, "shares minted");

        uint256 expectedAssets = box.previewRedeem(shares);
        uint256 redeemed = box.redeem(shares, feeder, feeder);
        vm.stopPrank();

        assertEq(redeemed, expectedAssets, "redeem returns previewRedeem");
        assertEq(asset.balanceOf(feeder), redeemed, "assets received");
        assertEq(box.balanceOf(feeder), 0, "all shares burned");
        assertLe(redeemed, assets, "deposit then redeem never returns more than deposited");
    }

    function testFuzz_MintThenRedeemNeverCreatesValue(PreState memory pre, uint256 shares) public {
        _deployBox(pre);
        shares = bound(shares, 1, MAX_UNITS * 1e18);

        uint256 expectedAssets = box.previewMint(shares);
        asset.mint(feeder, expectedAssets);
        vm.startPrank(feeder);
        asset.approve(address(box), expectedAssets);
        uint256 paid = box.mint(shares, feeder);
        assertEq(paid, expectedAssets, "mint returns previewMint");
        assertEq(asset.balanceOf(feeder), 0, "mint pulled exactly the returned assets");
        assertEq(box.balanceOf(feeder), shares, "shares minted");

        uint256 expectedRedeemed = box.previewRedeem(shares);
        uint256 redeemed = box.redeem(shares, feeder, feeder);
        vm.stopPrank();

        assertEq(redeemed, expectedRedeemed, "redeem returns previewRedeem");
        assertEq(asset.balanceOf(feeder), redeemed, "assets received");
        assertLe(redeemed, paid, "mint then redeem never returns more than paid");
    }

    function testFuzz_WithdrawThenDepositNeverCreatesShares(PreState memory pre, uint256 assets, uint256 withdrawn) public {
        _deployBox(pre);
        _deposit(feeder, feeder, bound(assets, 1, MAX_UNITS * unit));

        uint256 maxWithdraw = box.maxWithdraw(feeder);
        vm.assume(maxWithdraw > 0);
        withdrawn = bound(withdrawn, 1, maxWithdraw);

        uint256 sharesBefore = box.balanceOf(feeder);
        uint256 assetsBefore = asset.balanceOf(feeder);

        vm.startPrank(feeder);
        uint256 expectedBurned = box.previewWithdraw(withdrawn);
        uint256 burned = box.withdraw(withdrawn, feeder, feeder);
        assertEq(burned, expectedBurned, "withdraw returns previewWithdraw");
        assertEq(box.balanceOf(feeder), sharesBefore - burned, "shares burned");
        assertEq(asset.balanceOf(feeder), assetsBefore + withdrawn, "assets received");

        asset.approve(address(box), withdrawn);
        uint256 expectedMinted = box.previewDeposit(withdrawn);
        uint256 minted = box.deposit(withdrawn, feeder);
        vm.stopPrank();

        assertEq(minted, expectedMinted, "deposit returns previewDeposit");
        assertEq(asset.balanceOf(feeder), assetsBefore, "same assets as before the round trip");
        assertLe(box.balanceOf(feeder), sharesBefore, "withdraw then deposit never leaves more shares");
    }

    function testFuzz_PartialRedeemReturnsPreview(PreState memory pre, uint256 assets, uint256 redeemedShares) public {
        _deployBox(pre);
        uint256 shares = _deposit(feeder, holder, bound(assets, 1, MAX_UNITS * unit));
        vm.assume(shares > 0);
        redeemedShares = bound(redeemedShares, 1, shares);

        uint256 expectedAssets = box.previewRedeem(redeemedShares);
        uint256 totalAssetsBefore = box.totalAssets();

        vm.prank(holder);
        uint256 redeemed = box.redeem(redeemedShares, otherHolder, holder);

        assertEq(redeemed, expectedAssets, "redeem returns previewRedeem");
        assertEq(asset.balanceOf(otherHolder), redeemed, "receiver got the assets");
        assertEq(box.balanceOf(holder), shares - redeemedShares, "owner shares burned");
        assertEq(box.totalAssets(), totalAssetsBefore - redeemed, "totalAssets decreases by the redeemed assets");
    }

    /////////////////////////////
    /// VAL-FUZZ-003: SHARE PRICE NEVER DECREASES
    /////////////////////////////

    function testFuzz_SharePriceNeverDecreases(PreState memory pre, uint256[ACTIONS] memory actions) public {
        _deployBox(pre);

        address[4] memory actors = [feeder, otherFeeder, holder, otherHolder];
        address[2] memory feeders = [feeder, otherFeeder];

        for (uint256 i; i < ACTIONS; i++) {
            uint256 action = actions[i];
            uint256 kind = action % 4;
            address actor = actors[(action >> 8) % 4];
            uint256 amountSeed = action >> 16;

            uint256 totalAssetsBefore = box.totalAssets();
            uint256 supplyBefore = box.totalSupply();

            if (kind == 0) {
                // A feeder deposits for any receiver
                _deposit(feeders[(action >> 4) % 2], actor, bound(amountSeed, 1, MAX_UNITS * unit));
            } else if (kind == 1) {
                // A feeder mints for any receiver
                address caller = feeders[(action >> 4) % 2];
                uint256 shares = bound(amountSeed, 1, MAX_UNITS * 1e18);
                uint256 assets = box.previewMint(shares);
                asset.mint(caller, assets);
                vm.startPrank(caller);
                asset.approve(address(box), assets);
                box.mint(shares, actor);
                vm.stopPrank();
            } else if (kind == 2) {
                // Any holder withdraws part of its position
                uint256 maxWithdraw = box.maxWithdraw(actor);
                if (maxWithdraw == 0) continue;
                vm.prank(actor);
                box.withdraw(bound(amountSeed, 1, maxWithdraw), actor, actor);
            } else {
                // Any holder redeems part of its position
                uint256 maxRedeem = box.maxRedeem(actor);
                if (maxRedeem == 0) continue;
                vm.prank(actor);
                box.redeem(bound(amountSeed, 1, maxRedeem), actor, actor);
            }

            _assertSharePriceNotDecreased(totalAssetsBefore, supplyBefore, box.totalAssets(), box.totalSupply());
        }
    }

    /// @dev P = (TA + 1) / (S + V); P' >= P  <=>  (TA' + 1) * (S + V) >= (TA + 1) * (S' + V).
    /// Compared as floor((TA' + 1) * (S + V) / (S' + V)) >= TA + 1, which is equivalent for integers and cannot overflow.
    function _assertSharePriceNotDecreased(uint256 ta, uint256 s, uint256 taAfter, uint256 sAfter) internal view {
        assertGe(Math.mulDiv(taAfter + 1, s + virtualShares, sAfter + virtualShares), ta + 1, "share price must not decrease");
    }
}
