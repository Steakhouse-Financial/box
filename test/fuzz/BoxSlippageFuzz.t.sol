// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {MAX_SLIPPAGE_LIMIT, ORACLE_PRECISION, PRECISION} from "../../src/libraries/Constants.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {MockFunding} from "../Box.t.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSlippageSwapper} from "../mocks/MockSlippageSwapper.sol";

/// @dev Stateless fuzzing of Box allocate/deallocate slippage bounds with a fuzzed oracle price, Box max slippage and
/// swapper slippage in [0, 5%]. Expected outcomes are derived from the documented Box formulas, then compared to the
/// actual success or revert selector.
contract BoxSlippageFuzzTest is Test {
    using BoxLib for IBox;
    using Math for uint256;

    uint256 internal constant MAX_UNITS = 1e12;
    uint256 internal constant MAX_SWAPPER_SLIPPAGE = 0.05 ether;
    uint256 internal constant ROUNDS = 3;

    address internal owner = address(0x1);
    address internal allocator = address(0x2);
    address internal curator = address(0x3);
    address internal feeder = address(0x5);

    ERC20MockDecimals internal asset;
    ERC20MockDecimals internal token;
    MockOracle internal oracle;
    MockSlippageSwapper internal swapper;
    IBox internal box;
    uint256 internal assetUnit;
    uint256 internal tokenUnit;

    struct Market {
        uint256 decimalsSeed;
        uint256 priceSeed;
        uint256 maxSlippage;
        uint256 deposit;
    }

    struct Outcome {
        bytes4 error;
        uint256 expected;
        uint256 received;
        uint256 accumulatedSlippage;
    }

    /////////////////////////////
    /// SETUP HELPERS
    /////////////////////////////

    function _decimals(uint256 seed) internal pure returns (uint8) {
        uint256 choice = seed % 3;
        return
            choice == 0
                ? 6
                : choice == 1
                    ? 8
                    : 18;
    }

    function _deployBox(Market memory market) internal {
        uint8 assetDecimals = _decimals(market.decimalsSeed);
        uint8 tokenDecimals = _decimals(market.decimalsSeed / 3);
        assetUnit = 10 ** assetDecimals;
        tokenUnit = 10 ** tokenDecimals;

        asset = new ERC20MockDecimals(assetDecimals);
        token = new ERC20MockDecimals(tokenDecimals);
        // One whole token is worth between 0.001 and 100,000 whole asset units
        uint256 parity = (ORACLE_PRECISION * assetUnit) / tokenUnit;
        oracle = new MockOracle(bound(market.priceSeed, parity / 1000, parity * 100_000));
        swapper = new MockSlippageSwapper(address(asset), oracle);

        market.maxSlippage = bound(market.maxSlippage, 0, MAX_SLIPPAGE_LIMIT);
        box = IBox(address(new Box(address(asset), owner, curator, "Box Fuzz", "BOXF", market.maxSlippage, 7 days, 10 days, 7 days)));

        vm.startPrank(curator);
        box.addFeederInstant(feeder);
        box.setIsAllocator(allocator, true);
        box.addTokenInstant(token, oracle);
        vm.stopPrank();

        uint256 depositAmount = bound(market.deposit, assetUnit, MAX_UNITS * assetUnit);
        asset.mint(feeder, depositAmount);
        vm.startPrank(feeder);
        asset.approve(address(box), depositAmount);
        box.deposit(depositAmount, feeder);
        vm.stopPrank();
    }

    /// @dev Adds `pct` to the accumulated slippage the way Box does, including the epoch reset
    function _accumulate(uint256 pct) internal view returns (uint256) {
        if (vm.getBlockTimestamp() >= box.slippageEpochStart() + box.slippageEpochDuration()) return pct;
        return box.accumulatedSlippage() + pct;
    }

    function _predictAllocate(uint256 assets) internal view returns (Outcome memory o) {
        uint256 price = oracle.price();
        uint256 tolerance = box.maxSlippage();
        o.expected = assets.mulDiv(ORACLE_PRECISION, price, Math.Rounding.Ceil);
        o.received = swapper.quote(address(asset), assets);
        o.accumulatedSlippage = box.accumulatedSlippage();

        uint256 minTokens = o.expected.mulDiv(PRECISION - tolerance, PRECISION, Math.Rounding.Ceil);
        if (o.received < minTokens) {
            o.error = ErrorsLib.AllocationTooExpensive.selector;
        } else if (o.received < o.expected) {
            uint256 slippageValue = (o.expected - o.received).mulDiv(price, ORACLE_PRECISION, Math.Rounding.Ceil);
            o.accumulatedSlippage = _accumulate(slippageValue.mulDiv(PRECISION, box.totalAssets(), Math.Rounding.Ceil));
            if (o.accumulatedSlippage >= tolerance) o.error = ErrorsLib.TooMuchAccumulatedSlippage.selector;
        }
    }

    function _predictDeallocate(uint256 tokens) internal view returns (Outcome memory o) {
        uint256 tolerance = box.maxSlippage();
        o.expected = tokens.mulDiv(oracle.price(), ORACLE_PRECISION, Math.Rounding.Ceil);
        o.received = swapper.quote(address(token), tokens);
        o.accumulatedSlippage = box.accumulatedSlippage();

        uint256 minAssets = o.expected.mulDiv(PRECISION - tolerance, PRECISION, Math.Rounding.Ceil);
        if (o.received < minAssets) {
            o.error = ErrorsLib.TokenSaleNotGeneratingEnoughAssets.selector;
        } else if (o.received < o.expected) {
            o.accumulatedSlippage = _accumulate((o.expected - o.received).mulDiv(PRECISION, box.totalAssets(), Math.Rounding.Ceil));
            if (o.accumulatedSlippage >= tolerance) o.error = ErrorsLib.TooMuchAccumulatedSlippage.selector;
        }
    }

    function _assertAccumulated(Outcome memory o, uint256 accumulatedBefore) internal view {
        if (o.received < o.expected) {
            assertEq(box.accumulatedSlippage(), o.accumulatedSlippage, "accumulated slippage");
            assertLt(box.accumulatedSlippage(), box.maxSlippage(), "accumulated slippage stays below max slippage");
        } else {
            assertEq(box.accumulatedSlippage(), accumulatedBefore, "no slippage accounted without a loss");
        }
    }

    /////////////////////////////
    /// VAL-FUZZ-004: ALLOCATE / DEALLOCATE SLIPPAGE BOUNDS
    /////////////////////////////

    function testFuzz_AllocateRespectsSlippageBounds(
        Market memory market,
        uint256[ROUNDS] memory amounts,
        uint256[ROUNDS] memory slippages,
        uint256[ROUNDS] memory warps
    ) public {
        _deployBox(market);

        for (uint256 i; i < ROUNDS; i++) {
            uint256 available = asset.balanceOf(address(box));
            if (available == 0) break;
            // Occasionally cross the 7-day slippage epoch so the reset path is exercised too
            vm.warp(vm.getBlockTimestamp() + bound(warps[i], 0, 8 days));
            uint256 assets = bound(amounts[i], 1, available);
            swapper.setSlippage(bound(slippages[i], 0, MAX_SWAPPER_SLIPPAGE));

            Outcome memory o = _predictAllocate(assets);
            uint256 accumulatedBefore = box.accumulatedSlippage();
            uint256 tokensBefore = token.balanceOf(address(box));

            vm.prank(allocator);
            if (o.error != bytes4(0)) {
                vm.expectRevert(o.error);
                box.allocate(token, assets, swapper, "");
                continue;
            }
            (uint256 expected, uint256 received) = box.allocate(token, assets, swapper, "");

            assertEq(expected, o.expected, "expected tokens");
            assertEq(received, o.received, "received tokens");
            assertGe(
                received,
                o.expected.mulDiv(PRECISION - box.maxSlippage(), PRECISION, Math.Rounding.Ceil),
                "received at least the minimum"
            );
            assertEq(asset.balanceOf(address(box)), available - assets, "assets spent");
            assertEq(token.balanceOf(address(box)), tokensBefore + received, "tokens received");
            _assertAccumulated(o, accumulatedBefore);
        }
    }

    function testFuzz_DeallocateRespectsSlippageBounds(
        Market memory market,
        uint256 tokenBalance,
        uint256[ROUNDS] memory amounts,
        uint256[ROUNDS] memory slippages,
        uint256[ROUNDS] memory warps
    ) public {
        _deployBox(market);
        token.mint(address(box), bound(tokenBalance, 1, MAX_UNITS * tokenUnit));

        for (uint256 i; i < ROUNDS; i++) {
            uint256 available = token.balanceOf(address(box));
            if (available == 0) break;
            vm.warp(vm.getBlockTimestamp() + bound(warps[i], 0, 8 days));
            uint256 tokens = bound(amounts[i], 1, available);
            swapper.setSlippage(bound(slippages[i], 0, MAX_SWAPPER_SLIPPAGE));

            Outcome memory o = _predictDeallocate(tokens);
            uint256 accumulatedBefore = box.accumulatedSlippage();
            uint256 assetsBefore = asset.balanceOf(address(box));

            vm.prank(allocator);
            if (o.error != bytes4(0)) {
                vm.expectRevert(o.error);
                box.deallocate(token, tokens, swapper, "");
                continue;
            }
            (uint256 expected, uint256 received) = box.deallocate(token, tokens, swapper, "");

            assertEq(expected, o.expected, "expected assets");
            assertEq(received, o.received, "received assets");
            assertGe(
                received,
                o.expected.mulDiv(PRECISION - box.maxSlippage(), PRECISION, Math.Rounding.Ceil),
                "received at least the minimum"
            );
            assertEq(token.balanceOf(address(box)), available - tokens, "tokens sold");
            assertEq(asset.balanceOf(address(box)), assetsBefore + received, "assets received");
            _assertAccumulated(o, accumulatedBefore);
        }
    }

    function testFuzz_SwapperSpendingTooMuchReverts(Market memory market, uint256 amount, uint256 extra, uint256 slippage) public {
        _deployBox(market);
        swapper.setSlippage(bound(slippage, 0, MAX_SWAPPER_SLIPPAGE));

        // allocate: the swapper takes the approved assets and burns `extra` more from the Box
        uint256 assetBalance = asset.balanceOf(address(box));
        uint256 assets = bound(amount, 1, assetBalance - 1);
        swapper.setOverspend(bound(extra, 1, assetBalance - assets));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.SwapperDidSpendTooMuch.selector);
        box.allocate(token, assets, swapper, "");

        // deallocate: same with tokens
        uint256 tokenBalance = bound(amount, 2, MAX_UNITS * tokenUnit);
        token.mint(address(box), tokenBalance);
        uint256 tokens = bound(amount, 1, tokenBalance - 1);
        swapper.setOverspend(bound(extra, 1, tokenBalance - tokens));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.SwapperDidSpendTooMuch.selector);
        box.deallocate(token, tokens, swapper, "");
    }

    /////////////////////////////
    /// VAL-FUZZ-004: WINDDOWN ALLOCATION CAP
    /////////////////////////////

    function testFuzz_WinddownAllocateCapIsExact(
        Market memory market,
        uint256 debt,
        uint256 existingBalance,
        uint256 elapsed,
        address caller
    ) public {
        _deployBox(market);
        vm.assume(!box.isAllocator(caller));

        MockFunding funding = new MockFunding(address(box));
        vm.prank(curator);
        box.addFundingInstant(funding);

        debt = bound(debt, 1, MAX_UNITS * tokenUnit);
        existingBalance = bound(existingBalance, 0, debt - 1);
        funding.setDebtBalance(token, debt);
        token.mint(address(box), existingBalance);

        vm.prank(curator);
        box.shutdown();
        elapsed = bound(elapsed, 0, 2 * box.shutdownSlippageDuration());
        vm.warp(vm.getBlockTimestamp() + box.shutdownWarmup() + elapsed);
        assertTrue(box.isWinddown(), "in winddown");

        // Debt shortfall valued at the oracle, grossed up by the linearly increasing winddown slippage tolerance
        uint256 tolerance = elapsed < box.shutdownSlippageDuration()
            ? elapsed.mulDiv(MAX_SLIPPAGE_LIMIT, box.shutdownSlippageDuration())
            : MAX_SLIPPAGE_LIMIT;
        uint256 neededValue = (debt - existingBalance).mulDiv(oracle.price(), ORACLE_PRECISION, Math.Rounding.Ceil);
        uint256 cap = neededValue.mulDiv(PRECISION, PRECISION - tolerance, Math.Rounding.Ceil);

        // Make sure liquidity is not what limits the allocation
        uint256 assetBalance = asset.balanceOf(address(box));
        if (assetBalance <= cap) asset.mint(address(box), cap + 1 - assetBalance);
        assetBalance = asset.balanceOf(address(box));

        vm.prank(caller);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        box.allocate(token, cap + 1, swapper, "");

        uint256 expectedReceived = swapper.quote(address(asset), cap);
        vm.prank(caller);
        (uint256 expected, uint256 received) = box.allocate(token, cap, swapper, "");

        assertEq(expected, cap.mulDiv(ORACLE_PRECISION, oracle.price(), Math.Rounding.Ceil), "expected tokens");
        assertEq(received, expectedReceived, "received tokens");
        assertEq(asset.balanceOf(address(box)), assetBalance - cap, "assets spent");
        assertEq(token.balanceOf(address(box)), existingBalance + received, "tokens received");
        assertEq(box.accumulatedSlippage(), 0, "no slippage accounting in winddown");
    }
}
