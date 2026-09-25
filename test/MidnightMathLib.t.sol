// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CollateralParams, Market} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "../src/libraries/midnight/MidnightMathLib.sol";
import {TickLib} from "../src/libraries/midnight/TickLib.sol";
import {MidnightAddresses} from "./helpers/MidnightAddresses.sol";

/// @dev External wrapper so library reverts happen one call deeper than the test (required by `vm.expectRevert`).
contract TickLibHarness {
    function tickToPrice(uint256 tick) external pure returns (uint256) {
        return TickLib.tickToPrice(tick);
    }
}

/// @dev Reference values come from Midnight's TickLib emulated exactly and from the deployed markets on Base and Ethereum.
contract MidnightMathLibTest is Test, MidnightAddresses {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    // Base cbBTC/USDC 2026-12-25 market at Base block 51,711,632.
    uint256 internal constant DEC25_MATURITY = 1798210800;
    uint256 internal constant BASE_BLOCK_TIMESTAMP = 1790212611;
    uint256 internal constant DEC25_TTM = DEC25_MATURITY - BASE_BLOCK_TIMESTAMP; // 7,998,189 s

    TickLibHarness internal harness;

    function setUp() public {
        harness = new TickLibHarness();
    }

    // ========== TICK PRICES ==========

    function testTickToPriceReferenceValues() public pure {
        assertEq(TickLib.tickToPrice(3636), 788633800000000000);
        assertEq(TickLib.tickToPrice(3876), 925082200000000000);
        assertEq(TickLib.tickToPrice(4012), 960522100000000000);
        assertEq(TickLib.tickToPrice(4100), 974191500000000000);
        assertEq(TickLib.tickToPrice(4160), 980735600000000000);
        assertEq(TickLib.tickToPrice(4180), 982534700000000000);
        assertEq(TickLib.tickToPrice(4188), 983206600000000000);
        assertEq(TickLib.tickToPrice(4204), 984474700000000000);
        assertEq(TickLib.tickToPrice(4212), 985072900000000000);
        assertEq(TickLib.tickToPrice(4216), 985363400000000000);
        assertEq(TickLib.tickToPrice(4220), 985648300000000000);
        assertEq(TickLib.tickToPrice(4240), 986992700000000000);
        assertEq(TickLib.tickToPrice(4260), 988211300000000000);
        assertEq(TickLib.tickToPrice(4300), 990323300000000000);
        assertEq(TickLib.tickToPrice(4400), 994100700000000000);
        assertEq(TickLib.tickToPrice(4440), 995162900000000000);
    }

    function testTickToPriceBounds() public pure {
        assertEq(TickLib.tickToPrice(0), 0);
        assertEq(TickLib.tickToPrice(TickLib.MAX_TICK), WAD);
        assertEq(TickLib.MAX_TICK, 6744);
    }

    function testTickToPriceRevertsAboveMaxTick() public {
        vm.expectRevert(TickLib.TickOutOfRange.selector);
        harness.tickToPrice(6745);
        vm.expectRevert(TickLib.TickOutOfRange.selector);
        harness.tickToPrice(type(uint256).max);
    }

    function testFuzz_TickToPriceMonotonicAndStepped(uint256 tick) public pure {
        tick = bound(tick, 0, TickLib.MAX_TICK - 1);
        uint256 price = TickLib.tickToPrice(tick);
        assertLe(price, TickLib.tickToPrice(tick + 1), "non-decreasing");
        assertLe(price, WAD, "price <= 1");
        assertEq(price % TickLib.PRICE_ROUNDING_STEP, 0, "multiple of 1e-7");
    }

    // ========== SELLER PRICE ==========

    function testSellerPriceNetOfFee() public pure {
        assertEq(MidnightMathLib.sellerPrice(4212, 0), 985072900000000000);
        assertEq(MidnightMathLib.sellerPrice(4212, 0.001e18), 984072900000000000);
        assertEq(MidnightMathLib.sellerPrice(TickLib.MAX_TICK, 0), WAD);
    }

    function testSellerPriceUnusableOffersReturnZero() public pure {
        assertEq(MidnightMathLib.sellerPrice(TickLib.MAX_TICK + 1, 0), 0, "tick above max");
        assertEq(MidnightMathLib.sellerPrice(type(uint256).max, 0), 0, "huge tick");
        assertEq(MidnightMathLib.sellerPrice(0, 0), 0, "tick 0");
        assertEq(MidnightMathLib.sellerPrice(4212, 985072900000000000), 0, "fee == price");
        assertEq(MidnightMathLib.sellerPrice(4212, 985072900000000001), 0, "fee > price");
        assertEq(MidnightMathLib.sellerPrice(4212, 985072899999999999), 1, "fee just below price");
    }

    // ========== UNITS / PROCEEDS ==========

    function testUnitsForSellerAssetsReference() public pure {
        // 100,000 USDC at tick 4212 (library worked example, step 1).
        uint256 price = TickLib.tickToPrice(4212);
        uint256 units = MidnightMathLib.unitsForSellerAssets(100_000e6, price);
        assertEq(units, 101_515_329_475);
        assertEq(MidnightMathLib.sellerAssetsOf(units, price), 100_000e6);
        assertLt(MidnightMathLib.sellerAssetsOf(units - 1, price), 100_000e6, "minimal units");

        // 50,000 USDC at tick 4240 (step 3).
        price = TickLib.tickToPrice(4240);
        units = MidnightMathLib.unitsForSellerAssets(50_000e6, price);
        assertEq(units, 50_658_935_978);
        assertEq(MidnightMathLib.sellerAssetsOf(units, price), 50_000e6);
    }

    function testUnitsForSellerAssetsZeroPrice() public pure {
        assertEq(MidnightMathLib.unitsForSellerAssets(1e6, 0), 0);
        assertEq(MidnightMathLib.unitsForSellerAssets(0, WAD), 0);
    }

    function testFuzz_UnitsDeliverAtLeastTargetAndAreMinimal(uint256 target, uint256 tick, uint256 fee) public pure {
        target = bound(target, 1, 1e30);
        // Low ticks round to a price of 0 (covered by testSellerPriceUnusableOffersReturnZero).
        tick = bound(tick, 1000, TickLib.MAX_TICK);
        uint256 tickPrice = TickLib.tickToPrice(tick);
        fee = bound(fee, 0, tickPrice - 1);
        uint256 price = MidnightMathLib.sellerPrice(tick, fee);
        assertEq(price, tickPrice - fee);

        uint256 units = MidnightMathLib.unitsForSellerAssets(target, price);
        assertGe(MidnightMathLib.sellerAssetsOf(units, price), target, "delivers at least target");
        assertLt(MidnightMathLib.sellerAssetsOf(units - 1, price), target, "one unit less is short");
    }

    // ========== CONSUMABLE UNITS ==========

    function testConsumableUnitsAssetsCapReference() public pure {
        // Captured Base offer #0: maxAssets 101e6 at tick 4216; the Router quoted 102,500,256 units.
        uint256 price = TickLib.tickToPrice(4216);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(0, 101e6, 0, price), 102_500_256);
        // Largest amount whose buyer assets fit: one more unit exceeds the cap.
        assertLe(MidnightMathLib.sellerAssetsOf(102_500_256, price), 101e6);
        assertGt(MidnightMathLib.sellerAssetsOf(102_500_257, price), 101e6);
        // Partially consumed.
        uint256 partialUnits = MidnightMathLib.consumableUnitsOfBuyOffer(0, 101e6, 1e6, price);
        assertLe(MidnightMathLib.sellerAssetsOf(partialUnits, price), 100e6);
        assertGt(MidnightMathLib.sellerAssetsOf(partialUnits + 1, price), 100e6);
        // Fully or over consumed.
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(0, 101e6, 101e6, price), 0);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(0, 101e6, type(uint128).max, price), 0);
    }

    function testFuzz_ConsumableUnitsAssetsCapIsMaximal(uint128 maxAssets, uint128 consumed, uint256 tick) public pure {
        vm.assume(maxAssets > consumed);
        tick = bound(tick, 1000, TickLib.MAX_TICK);
        uint256 price = TickLib.tickToPrice(tick);
        uint256 remaining = uint256(maxAssets) - consumed;
        uint256 units = MidnightMathLib.consumableUnitsOfBuyOffer(0, maxAssets, consumed, price);
        assertLe(MidnightMathLib.sellerAssetsOf(units, price), remaining, "fits");
        assertGt(MidnightMathLib.sellerAssetsOf(units + 1, price), remaining, "maximal");
    }

    function testConsumableUnitsUnitsCap() public pure {
        uint256 price = TickLib.tickToPrice(4212);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(500, 0, 0, price), 500);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(500, 0, 200, price), 300);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(500, 0, 500, price), 0);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(500, 0, 600, price), 0);
        // A units cap does not depend on the price.
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(500, 0, 0, 0), 500);
    }

    function testConsumableUnitsInvalidCapsOrPrice() public pure {
        uint256 price = TickLib.tickToPrice(4212);
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(0, 0, 0, price), 0, "no cap");
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(1, 1, 0, price), 0, "both caps");
        assertEq(MidnightMathLib.consumableUnitsOfBuyOffer(0, 1e6, 0, 0), 0, "zero price");
    }

    // ========== APR FLOOR ==========

    function testMinSellerPriceReferenceValues() public pure {
        assertEq(MidnightMathLib.minSellerPrice(0.01e18, DEC25_TTM), 997470206989671326);
        assertEq(MidnightMathLib.minSellerPrice(0.05e18, DEC25_TTM), 987477749752950907);
        assertEq(MidnightMathLib.minSellerPrice(0.06e18, DEC25_TTM), 985010839307777337);
        assertEq(MidnightMathLib.minSellerPrice(0.07e18, DEC25_TTM), 982556223786530703);
        assertEq(MidnightMathLib.minSellerPrice(0.08e18, DEC25_TTM), 980113811502020464);
        assertEq(MidnightMathLib.minSellerPrice(0.1e18, DEC25_TTM), 975265234430169326);
        assertEq(MidnightMathLib.minSellerPrice(1e18, DEC25_TTM), 797689311395764310);
    }

    /// @dev Rounding the rate term up (the research helper) gives a floor 1 wei lower for each reference bound.
    function testMinSellerPriceIsStricterThanLaxRounding() public pure {
        uint256[7] memory bounds = [uint256(0.01e18), 0.05e18, 0.06e18, 0.07e18, 0.08e18, 0.1e18, 1e18];
        for (uint256 i; i < bounds.length; i++) {
            uint256 strict = MidnightMathLib.minSellerPrice(bounds[i], DEC25_TTM);
            uint256 laxRateTerm = (bounds[i] * DEC25_TTM + YEAR - 1) / YEAR;
            uint256 lax = (WAD * WAD + (WAD + laxRateTerm) - 1) / (WAD + laxRateTerm);
            assertEq(strict, lax + 1, "strict floor is 1 wei above the lax floor");
        }
    }

    function testMinSellerPriceScreensCapturedOffers() public pure {
        // 6% bound: ticks 4216 and 4212 pass, tick 4204 is rejected.
        uint256 floor6 = MidnightMathLib.minSellerPrice(0.06e18, DEC25_TTM);
        assertGe(TickLib.tickToPrice(4216), floor6);
        assertGe(TickLib.tickToPrice(4212), floor6);
        assertLt(TickLib.tickToPrice(4204), floor6);
        // 1% bound: even the best captured offer (tick 4216) is rejected.
        assertLt(TickLib.tickToPrice(4216), MidnightMathLib.minSellerPrice(0.01e18, DEC25_TTM));
    }

    function testMinSellerPriceZeroTermOrRate() public pure {
        assertEq(MidnightMathLib.minSellerPrice(0.08e18, 0), WAD);
        assertEq(MidnightMathLib.minSellerPrice(0, DEC25_TTM), WAD);
    }

    /// @dev Never lax: any price >= the floor implies a simple annual rate <= maxApr, i.e. exactly
    /// `floor * (1 + maxApr * ttm / YEAR) >= 1`. Tight: one wei below the floor is below the (floored) bound.
    function testFuzz_MinSellerPriceNeverLax(uint256 maxApr, uint256 ttm) public pure {
        maxApr = bound(maxApr, 1, 1e18);
        ttm = bound(ttm, 1, 100 * YEAR);
        uint256 floor = MidnightMathLib.minSellerPrice(maxApr, ttm);
        assertLe(floor, WAD);
        assertGe(floor * (WAD * YEAR + maxApr * ttm), WAD * WAD * YEAR, "exact rational check");
        uint256 rateTerm = (maxApr * ttm) / YEAR;
        assertLt((floor - 1) * (WAD + rateTerm), WAD * WAD, "tight");
    }

    function testFuzz_MinSellerPriceMonotonic(uint256 maxApr, uint256 ttm) public pure {
        maxApr = bound(maxApr, 1, 1e18 - 1);
        ttm = bound(ttm, 1, 10 * YEAR);
        uint256 floor = MidnightMathLib.minSellerPrice(maxApr, ttm);
        assertLe(MidnightMathLib.minSellerPrice(maxApr + 1, ttm), floor, "higher bound, lower floor");
        assertLe(MidnightMathLib.minSellerPrice(maxApr, ttm + 1), floor, "longer term, lower floor");
    }

    // ========== MARKET IDS ==========

    function testMarketIdBaseDec25() public pure {
        Market memory m;
        m.chainId = BASE_CHAIN_ID;
        m.midnight = BASE_MIDNIGHT;
        m.loanToken = BASE_USDC;
        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] = CollateralParams(BASE_CBBTC, 0.86e18, 0.3e18, BASE_CBBTC_USDC_ORACLE);
        m.maturity = DEC25_MATURITY;
        m.rcfThreshold = 3000e6;
        assertEq(IdLib.toId(m), 0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da);
    }

    function testMarketIdBaseOct30() public pure {
        Market memory m;
        m.chainId = BASE_CHAIN_ID;
        m.midnight = BASE_MIDNIGHT;
        m.loanToken = BASE_USDC;
        m.collateralParams = new CollateralParams[](2);
        m.collateralParams[0] = CollateralParams(BASE_USDC, 0.98e18, 0.3e18, BASE_USDC_USDC_ORACLE);
        m.collateralParams[1] = CollateralParams(BASE_CBBTC, 0.86e18, 0.3e18, BASE_CBBTC_USDC_ORACLE);
        m.maturity = 1793372400;
        m.rcfThreshold = 3000e6;
        assertEq(IdLib.toId(m), 0x0ff32a563814a0e5822441b77c1b463da99f095d686cb09b637d5d80418cffed);
    }

    function testMarketIdEthereumDec25() public pure {
        Market memory m;
        m.chainId = ETHEREUM_CHAIN_ID;
        m.midnight = ETHEREUM_MIDNIGHT;
        m.loanToken = ETHEREUM_USDC;
        m.collateralParams = new CollateralParams[](2);
        m.collateralParams[0] = CollateralParams(ETHEREUM_WBTC, 0.86e18, 0.3e18, ETHEREUM_WBTC_USDC_ORACLE);
        m.collateralParams[1] = CollateralParams(ETHEREUM_USDC, 0.98e18, 0.3e18, ETHEREUM_USDC_USDC_ORACLE);
        m.maturity = DEC25_MATURITY;
        m.rcfThreshold = 300000e6;
        assertEq(IdLib.toId(m), 0x3323abf2d2a3ec804f46552db920d900bb9c7ffd3f48143ab879a918fd6c0977);
    }
}
