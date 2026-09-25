// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingMidnight, OfferFill} from "../src/FundingMidnight.sol";
import {FundingMidnightFactory} from "../src/factories/FundingMidnightFactory.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {CollateralParams, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {IdLib} from "../src/libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "../src/libraries/midnight/MidnightMathLib.sol";
import {TickLib} from "../src/libraries/midnight/TickLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {MidnightBaseOffers} from "./helpers/MidnightBaseOffers.sol";
import {MidnightBuyCallbackProbe} from "./helpers/MidnightBuyCallbackProbe.sol";
import {MidnightForkTest} from "./helpers/MidnightForkTest.sol";
import {IMidnightTest, IVmEvmVersion} from "./helpers/MidnightTestInterfaces.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/**
 * @title Box + FundingMidnight against the real Morpho Midnight deployment on Base
 * @dev Block 51,711,632 (2026-09-24 01:16:51 UTC). Primary market: cbBTC/USDC maturing 2026-12-25 15:00 UTC; second
 *      maturity: the 2026-10-30 market where cbBTC is collateral index 1 (index 0 is USDC). Settlement and continuous
 *      fees are 0 on both markets at this block (checked in setUp), so buyer assets equal seller assets in every take.
 * @dev Midnight's bytecode uses the Osaka CLZ opcode: setUp switches the execution EVM right after forking.
 * @dev The Box oracle for cbBTC is the Midnight market oracle, so Box nav and the module ltv share one price.
 */
contract BoxLeverageMidnightBaseTest is MidnightForkTest {
    using BoxLib for Box;
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 51_711_632;
    uint256 internal constant FORK_TIMESTAMP = 1_790_212_611;

    uint256 internal constant DEC25_MATURITY = 1_798_210_800;
    uint256 internal constant OCT30_MATURITY = 1_793_372_400;
    bytes32 internal constant DEC25_ID = 0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da;
    bytes32 internal constant OCT30_ID = 0x0ff32a563814a0e5822441b77c1b463da99f095d686cb09b637d5d80418cffed;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant CURSOR = 0.3e18;
    uint256 internal constant LLTV_CAP = 0.9e18;
    uint256 internal constant MAX_APR = 0.08e18;
    uint256 internal constant COLLATERAL = 5e8; // 5 cbBTC, about 421k USDC

    IERC20 internal constant USDC = IERC20(BASE_USDC);
    IERC20 internal constant CBBTC = IERC20(BASE_CBBTC);

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);

    FundingMidnightFactory internal factory;
    Box internal box;
    FundingMidnight internal module;
    bytes internal fd;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), FORK_BLOCK);
        IVmEvmVersion(address(vm)).setEvmVersion("osaka");

        midnight = IMidnightTest(BASE_MIDNIGHT);
        setterRatifier = BASE_SETTER_RATIFIER;
        ecrecoverRatifier = BASE_ECRECOVER_RATIFIER;

        assertEq(midnight.settlementFee(DEC25_ID, DEC25_MATURITY - block.timestamp), 0, "no settlement fee on Dec-25");
        assertEq(midnight.settlementFee(OCT30_ID, OCT30_MATURITY - block.timestamp), 0, "no settlement fee on Oct-30");
        assertEq(midnight.continuousFee(DEC25_ID), 0, "no continuous fee on Dec-25");

        factory = new FundingMidnightFactory();
        box = new Box(address(USDC), owner, curator, "Box USDC", "BOXUSDC", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(CBBTC, IOracle(BASE_CBBTC_USDC_ORACLE));
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        vm.stopPrank();

        (module, fd) = _attachInstant(_dec25Market(), 0, MAX_APR);

        // Face exceeds proceeds: the Box needs extra USDC to close positions at face value
        deal(address(USDC), address(this), 50_000e6);
        USDC.approve(address(box), 50_000e6);
        box.deposit(50_000e6, address(this));
        deal(address(CBBTC), address(box), COLLATERAL);

        _setUpLender(USDC, 10_000_000e6);
    }

    // ========== OSAKA EXECUTION ==========

    function testOsakaExecutionWithoutConfigChange() public {
        assertEq(IVmEvmVersion(address(vm)).getEvmVersion(), "osaka", "execution EVM switched to Osaka");
        assertEq(block.chainid, BASE_CHAIN_ID, "Base");
        assertEq(block.number, FORK_BLOCK, "pinned block");
        assertEq(block.timestamp, FORK_TIMESTAMP, "pinned timestamp");

        assertEq(IdLib.toId(_dec25Market()), DEC25_ID, "Dec-25 market id");
        assertEq(IdLib.toId(_oct30Market()), OCT30_ID, "Oct-30 market id");
        assertEq(keccak256(abi.encode(midnight.toMarket(DEC25_ID))), keccak256(abi.encode(_dec25Market())), "Dec-25 literal");
        assertEq(keccak256(abi.encode(midnight.toMarket(OCT30_ID))), keccak256(abi.encode(_oct30Market())), "Oct-30 literal");
        assertEq(midnight.tickSpacing(DEC25_ID), 4, "Dec-25 created");

        // take and isHealthy run Midnight's CLZ code path, which only executes under Osaka
        _open(module, fd, _dec25Market(), COLLATERAL, 10_000e6, 4212, "osaka");
        assertGt(midnight.debt(DEC25_ID, address(module)), 10_000e6, "borrowed through take");
        assertTrue(midnight.isHealthy(_dec25Market(), DEC25_ID, address(module)), "health check executes");
    }

    // ========== TIMELOCKED ATTACHMENT ==========

    function testTimelockedAttachOfFactoryModule() public {
        FundingMidnight fresh = factory.createFundingMidnight(address(box), BASE_MIDNIGHT, LLTV_CAP);
        assertTrue(factory.isFundingMidnight(address(fresh)), "created by the factory");
        assertEq(fresh.owner(), address(box), "owned by the Box");
        assertEq(address(fresh.midnight()), BASE_MIDNIGHT, "Base Midnight");
        assertEq(fresh.lltvCap(), LLTV_CAP, "lltvCap");

        bytes memory freshFd = fresh.encodeFacilityData(_dec25Market(), 0, MAX_APR);
        assertEq(freshFd, abi.encode(_dec25Market(), uint256(0), MAX_APR), "canonical facilityData");

        IFunding funding = IFunding(address(fresh));
        bytes[4] memory calls = [
            abi.encodeCall(IBox.addFunding, (funding)),
            abi.encodeCall(IBox.addFundingCollateral, (funding, CBBTC)),
            abi.encodeCall(IBox.addFundingDebt, (funding, USDC)),
            abi.encodeCall(IBox.addFundingFacility, (funding, freshFd))
        ];
        bytes4[4] memory selectors = [
            IBox.addFunding.selector,
            IBox.addFundingCollateral.selector,
            IBox.addFundingDebt.selector,
            IBox.addFundingFacility.selector
        ];

        uint256 delay = 3 days;
        vm.startPrank(curator);
        for (uint256 i = 0; i < 4; i++) {
            box.increaseTimelock(selectors[i], delay);
            box.submit(calls[i]);
        }
        vm.stopPrank();
        uint256 executableAt = block.timestamp + delay;
        for (uint256 i = 0; i < 4; i++) {
            assertEq(box.executableAt(calls[i]), executableAt, "queued with the delay");
        }

        address anyone = makeAddr("anyone");
        vm.startPrank(anyone);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.addFunding(funding);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.addFundingCollateral(funding, CBBTC);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.addFundingDebt(funding, USDC);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.addFundingFacility(funding, freshFd);

        vm.warp(executableAt - 1);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box.addFunding(funding);

        vm.warp(executableAt);
        box.addFunding(funding);
        box.addFundingCollateral(funding, CBBTC);
        box.addFundingDebt(funding, USDC);
        box.addFundingFacility(funding, freshFd);
        vm.stopPrank();

        assertTrue(box.isFunding(funding), "module attached");
        assertTrue(fresh.isCollateralToken(CBBTC), "cbBTC collateral");
        assertTrue(fresh.isDebtToken(USDC), "USDC debt");
        assertTrue(fresh.isFacility(freshFd), "facility registered");
        assertEq(fresh.facilitiesLength(), 1, "one facility");
        assertEq(fresh.marketId(freshFd), DEC25_ID, "Dec-25 market");
        assertEq(fresh.facilityOfMarket(DEC25_ID), keccak256(freshFd), "market mapped to the facility");

        // Real offers have expired by now: borrow from a fresh signed lender bid
        Offer memory bid = _bid(_dec25Market(), ecrecoverRatifier, 4212, "timelocked", 100_000e6);
        bytes memory rd = _signForEcrecover(bid);
        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.pledge(fresh, freshFd, CBBTC, COLLATERAL);
        fresh.stageBorrow(freshFd, _fills(bid, rd), block.timestamp + 1 hours);
        box.borrow(fresh, freshFd, USDC, 50_000e6);
        vm.stopPrank();

        assertGe(USDC.balanceOf(address(box)) - usdcBefore, 50_000e6, "Box received the borrowed amount");
        assertEq(midnight.collateral(DEC25_ID, address(fresh), 0), COLLATERAL, "cbBTC pledged on Midnight");
        uint256 face = midnight.debt(DEC25_ID, address(fresh));
        assertGt(face, 50_000e6, "face above proceeds");
        assertEq(fresh.debtBalance(freshFd, USDC), face, "debtBalance is the face");
        assertLe(fresh.ltv(freshFd), (LLTV * LLTV_CAP) / WAD, "guard holds");
    }

    // ========== TEST-CREATED OFFERS ==========

    function testBorrowWithinBoundUsesSetterAndEcrecoverOffers() public {
        vm.prank(allocator);
        box.pledge(module, fd, CBBTC, COLLATERAL);

        // Each bid is capped at 60,000 USDC of buyer assets, so 100,000 USDC needs both
        Offer memory signedBid = _bid(_dec25Market(), ecrecoverRatifier, 4216, "ecrecover", 60_000e6);
        bytes memory signedRd = _signForEcrecover(signedBid);
        Offer memory registeredBid = _bid(_dec25Market(), setterRatifier, 4212, "setter", 60_000e6);
        bytes memory registeredRd = _ratifyWithSetter(registeredBid);

        uint256 amount = 100_000e6;
        uint256 ttm = DEC25_MATURITY - block.timestamp;
        uint256 minPrice = MidnightMathLib.minSellerPrice(MAX_APR, ttm);
        uint256 signedPrice = TickLib.tickToPrice(4216);
        uint256 registeredPrice = TickLib.tickToPrice(4212);
        assertGe(signedPrice, minPrice, "tick 4216 within 8%");
        assertGe(registeredPrice, minPrice, "tick 4212 within 8%");

        uint256 signedUnits = Math.min(
            MidnightMathLib.unitsForSellerAssets(amount, signedPrice),
            MidnightMathLib.consumableUnitsOfBuyOffer(0, 60_000e6, 0, signedPrice)
        );
        uint256 signedAssets = (signedUnits * signedPrice) / WAD;
        uint256 registeredUnits = MidnightMathLib.unitsForSellerAssets(amount - signedAssets, registeredPrice);
        uint256 registeredAssets = (registeredUnits * registeredPrice) / WAD;
        assertLt(signedAssets, amount, "the first bid alone is not enough");

        uint256 navBefore = box.totalAssets();
        uint256 usdcBefore = USDC.balanceOf(address(box));
        uint256 lenderBefore = USDC.balanceOf(lender);

        vm.startPrank(allocator);
        module.stageBorrow(fd, _fills(signedBid, signedRd, registeredBid, registeredRd), block.timestamp + 1 hours);
        box.borrow(module, fd, USDC, amount);
        vm.stopPrank();

        uint256 received = USDC.balanceOf(address(box)) - usdcBefore;
        uint256 face = midnight.debt(DEC25_ID, address(module));
        console2.log("proceeds", received);
        console2.log("face    ", face);
        console2.log("ltv     ", module.ltv(fd));

        assertGe(received, amount, "Box received at least the amount");
        assertEq(received, signedAssets + registeredAssets, "proceeds of both fills");
        assertEq(face, signedUnits + registeredUnits, "Midnight debt = units sold");
        assertEq(module.debtBalance(fd, USDC), face, "facility debtBalance = face");
        assertEq(module.debtBalance(USDC), face, "token debtBalance = face");
        assertEq(midnight.consumed(lender, "ecrecover"), signedAssets, "signed bid consumed");
        assertEq(midnight.consumed(lender, "setter"), registeredAssets, "registered bid consumed");
        assertEq(lenderBefore - USDC.balanceOf(lender), received, "lender paid the proceeds");
        assertEq(USDC.balanceOf(address(module)), 0, "no USDC left in the module");

        uint256 collateralValue = (COLLATERAL * IOracle(BASE_CBBTC_USDC_ORACLE).price()) / 1e36;
        assertEq(module.ltv(fd), face.mulDiv(WAD, collateralValue, Math.Rounding.Ceil), "ltv = face / collateral value");
        assertLe(module.ltv(fd), (LLTV * LLTV_CAP) / WAD, "ltv within LLTV x lltvCap");

        // Debt is valued at the proceeds (accretion starts there): 1 wei from rounding the discount down
        assertApproxEqAbs(box.totalAssets(), navBefore, 1, "pledge + borrow keeps totalAssets within 1 wei");
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertEq(validUntil, 0, "staging consumed");
    }

    // ========== CAPTURED REAL OFFERS ==========

    function testRealOffersFixtureDecodes() public view {
        bytes memory encoded = MidnightBaseOffers.encodedFills();
        OfferFill[] memory fills = abi.decode(encoded, (OfferFill[]));
        assertEq(fills.length, MidnightBaseOffers.LENGTH, "16 fills");
        assertEq(keccak256(abi.encode(fills)), keccak256(encoded), "canonical encoding");
        for (uint256 i = 0; i < fills.length; i++) {
            assertTrue(fills[i].offer.buy, "lender bid");
            assertEq(IdLib.toId(fills[i].offer.market), DEC25_ID, "Dec-25 market");
            assertLe(fills[i].offer.start, block.timestamp, "started");
            assertGe(fills[i].offer.expiry, block.timestamp, "not expired");
        }
        assertEq(fills[0].offer.tick, 4216, "best bid first");
        assertEq(fills[1].offer.tick, 4212, "then tick 4212");
        assertEq(fills[3].offer.tick, 4204, "tick 4204 at index 3");
    }

    function testBorrowFromCapturedRealOffers() public {
        OfferFill[] memory fills = _realFills();
        uint256[] memory consumedBefore = _consumed(fills);
        uint256 amount = 100_000e6;

        (uint256 units0, uint256 assets0) = _expectedFill(fills[0], amount);
        (uint256 units1, uint256 assets1) = _expectedFill(fills[1], amount - assets0);
        assertGt(assets0, 0, "tick 4216 bid used first");
        assertGe(assets0 + assets1, amount, "two bids cover the amount");

        uint256 usdcBefore = USDC.balanceOf(address(box));
        uint256 navBefore = box.totalAssets();
        vm.startPrank(allocator);
        box.pledge(module, fd, CBBTC, COLLATERAL);
        module.stageBorrow(fd, fills, block.timestamp + 1 hours);
        box.borrow(module, fd, USDC, amount);
        vm.stopPrank();

        uint256 received = USDC.balanceOf(address(box)) - usdcBefore;
        uint256 face = module.debtBalance(fd, USDC);
        uint256 averagePrice = (received * WAD) / face;
        console2.log("proceeds     ", received);
        console2.log("units sold   ", face);
        console2.log("average price", averagePrice);

        assertGe(received, amount, "Box received at least 100,000 USDC");
        assertEq(received, assets0 + assets1, "proceeds of the two best bids");
        assertEq(face, units0 + units1, "debtBalance = units sold");
        assertEq(midnight.debt(DEC25_ID, address(module)), face, "Midnight debt = units sold");
        assertApproxEqAbs(face, 101_515_300_000, 100_000, "about 101,515.3 units");
        assertApproxEqAbs(averagePrice, 0.985073e18, 1e12, "average price 0.985073 within 1e-6");

        uint256[] memory consumedAfter = _consumed(fills);
        assertEq(consumedAfter[0] - consumedBefore[0], _consumption(fills[0], units0, assets0), "tick 4216 bid consumed");
        assertEq(consumedAfter[1] - consumedBefore[1], _consumption(fills[1], units1, assets1), "tick 4212 bid consumed");
        assertEq(consumedAfter[2], consumedBefore[2], "third bid untouched");
        assertEq(consumedAfter[3], consumedBefore[3], "fourth bid untouched");

        assertApproxEqAbs(box.totalAssets(), navBefore, 1, "totalAssets within 1 wei");
        assertLe(module.ltv(fd), (LLTV * LLTV_CAP) / WAD, "guard holds");
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertEq(validUntil, 0, "staging consumed");
    }

    function testRealOffersAboveTighterBoundAreSkipped() public {
        OfferFill[] memory real = _realFills();
        uint256 ttm = DEC25_MATURITY - block.timestamp;
        uint256 price4204 = TickLib.tickToPrice(real[3].offer.tick);
        assertLt(price4204, MidnightMathLib.minSellerPrice(0.06e18, ttm), "tick 4204 above 6%");
        assertGe(price4204, MidnightMathLib.minSellerPrice(MAX_APR, ttm), "tick 4204 within 8%");

        (FundingMidnight tight, bytes memory tightFd) = _attachInstant(_dec25Market(), 0, 0.06e18);

        OfferFill[] memory fills = new OfferFill[](4);
        fills[0] = real[3];
        fills[1] = real[0];
        fills[2] = real[1];
        fills[3] = real[2];
        uint256[] memory consumedBefore = _consumed(fills);

        uint256 amount = 100_000e6;
        (uint256 units0, uint256 assets0) = _expectedFill(fills[1], amount);
        (uint256 units1, uint256 assets1) = _expectedFill(fills[2], amount - assets0);

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.pledge(tight, tightFd, CBBTC, COLLATERAL);
        tight.stageBorrow(tightFd, fills, block.timestamp + 1 hours);
        box.borrow(tight, tightFd, USDC, amount);
        vm.stopPrank();

        uint256[] memory consumedAfter = _consumed(fills);
        assertEq(consumedAfter[0], consumedBefore[0], "tick 4204 bid skipped: its maker's consumed is unchanged");
        assertEq(consumedAfter[1] - consumedBefore[1], _consumption(fills[1], units0, assets0), "tick 4216 bid filled");
        assertEq(consumedAfter[2] - consumedBefore[2], _consumption(fills[2], units1, assets1), "tick 4212 bid filled");
        assertEq(consumedAfter[3], consumedBefore[3], "last bid not needed");

        uint256 received = USDC.balanceOf(address(box)) - usdcBefore;
        assertGe(received, amount, "Box received at least the amount");
        assertEq(received, assets0 + assets1, "proceeds from ticks 4216 and 4212");
        assertEq(tight.debtBalance(tightFd, USDC), units0 + units1, "debt = units sold into the two bids");
    }

    /// @dev Control for the 6% scenario: the same staging order on the 8% facility takes the tick-4204 bid first, so
    ///      the skip above is caused by the APR bound alone
    function testRealOffersTick4204TakenUnderLooserBound() public {
        OfferFill[] memory real = _realFills();
        OfferFill[] memory fills = new OfferFill[](4);
        fills[0] = real[3];
        fills[1] = real[0];
        fills[2] = real[1];
        fills[3] = real[2];
        assertEq(fills[0].offer.tick, 4204, "tick 4204 bid staged first");
        uint256[] memory consumedBefore = _consumed(fills);

        uint256 amount = 100_000e6;
        uint256[] memory units = new uint256[](fills.length);
        uint256[] memory assets = new uint256[](fills.length);
        uint256 raised;
        uint256 sold;
        for (uint256 i = 0; i < fills.length && raised < amount; i++) {
            (units[i], assets[i]) = _expectedFill(fills[i], amount - raised);
            raised += assets[i];
            sold += units[i];
        }
        assertGt(assets[0], 0, "tick 4204 bid has capacity for this borrow");
        assertGe(raised, amount, "staged bids cover the amount");

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.pledge(module, fd, CBBTC, COLLATERAL);
        module.stageBorrow(fd, fills, block.timestamp + 1 hours);
        box.borrow(module, fd, USDC, amount);
        vm.stopPrank();

        uint256[] memory consumedAfter = _consumed(fills);
        assertEq(
            consumedAfter[0] - consumedBefore[0],
            _consumption(fills[0], units[0], assets[0]),
            "tick 4204 bid taken: its maker's consumed changed"
        );
        for (uint256 i = 1; i < fills.length; i++) {
            assertEq(consumedAfter[i] - consumedBefore[i], _consumption(fills[i], units[i], assets[i]), "later bids as expected");
        }
        assertEq(USDC.balanceOf(address(box)) - usdcBefore, raised, "proceeds of the bids taken in staging order");
        assertEq(module.debtBalance(fd, USDC), sold, "debt = units sold");
    }

    // ========== ONLY ABOVE-BOUND OFFERS ==========

    function testBorrowRevertsWhenOnlyAboveBoundRealOffers() public {
        OfferFill[] memory fills = _realFills();
        (FundingMidnight strict, bytes memory strictFd) = _attachInstant(_dec25Market(), 0, 0.01e18);
        uint256 minPrice = MidnightMathLib.minSellerPrice(0.01e18, DEC25_MATURITY - block.timestamp);
        for (uint256 i = 0; i < fills.length; i++) {
            assertLt(TickLib.tickToPrice(fills[i].offer.tick), minPrice, "every real bid implies more than 1%");
        }

        vm.startPrank(allocator);
        box.pledge(strict, strictFd, CBBTC, COLLATERAL);
        strict.stageBorrow(strictFd, fills, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256[] memory consumedBefore = _consumed(fills);
        uint256 usdcBefore = USDC.balanceOf(address(box));

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        box.borrow(strict, strictFd, USDC, 1_000e6);

        assertEq(midnight.debt(DEC25_ID, address(strict)), 0, "no Midnight debt");
        assertEq(strict.debtBalance(strictFd, USDC), 0, "no debtBalance");
        assertEq(USDC.balanceOf(address(box)), usdcBefore, "Box USDC unchanged");
        uint256[] memory consumedAfter = _consumed(fills);
        for (uint256 i = 0; i < fills.length; i++) {
            assertEq(consumedAfter[i], consumedBefore[i], "no maker's consumed changed");
        }
    }

    function testBorrowRevertsWhenOnlyAboveBoundTestOffer() public {
        // Tick 4100 implies about 10.45% a year on this market, above the 8% bound
        Offer memory bid = _bid(_dec25Market(), setterRatifier, 4100, "expensive", 1_000_000e6);
        bytes memory rd = _ratifyWithSetter(bid);
        assertLt(TickLib.tickToPrice(4100), MidnightMathLib.minSellerPrice(MAX_APR, DEC25_MATURITY - block.timestamp));

        vm.startPrank(allocator);
        box.pledge(module, fd, CBBTC, COLLATERAL);
        module.stageBorrow(fd, _fills(bid, rd), block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 usdcBefore = USDC.balanceOf(address(box));
        uint256 lenderBefore = USDC.balanceOf(lender);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        box.borrow(module, fd, USDC, 10_000e6);

        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "no Midnight debt");
        assertEq(midnight.consumed(lender, "expensive"), 0, "bid not consumed");
        assertEq(USDC.balanceOf(address(box)), usdcBefore, "Box USDC unchanged");
        assertEq(USDC.balanceOf(lender), lenderBefore, "lender USDC unchanged");
    }

    // ========== EARLY REPAY ==========

    function testEarlyPartialAndFullRepay() public {
        _open(module, fd, _dec25Market(), COLLATERAL, 100_000e6, 4212, "repay");
        vm.warp(block.timestamp + 30 days);

        uint256 face = midnight.debt(DEC25_ID, address(module));
        uint256 value = module.debtValue(fd);
        uint256 navBefore = box.totalAssets();
        uint256 usdcBefore = USDC.balanceOf(address(box));
        assertLt(value, face, "discount not fully accreted before maturity");

        uint256 repaid = 40_000e6;
        vm.prank(allocator);
        box.repay(module, fd, USDC, repaid);

        uint256 realisedLoss = repaid.mulDiv(face - value, face);
        console2.log("face before       ", face);
        console2.log("debt value before ", value);
        console2.log("realised discount ", realisedLoss);
        assertEq(midnight.debt(DEC25_ID, address(module)), face - repaid, "Midnight debt down by exactly r");
        assertEq(usdcBefore - USDC.balanceOf(address(box)), repaid, "Box paid exactly r");
        assertApproxEqAbs(module.debtValue(fd), value.mulDiv(face - repaid, face), 1, "debt value scaled by (A - r) / A");
        assertApproxEqAbs(navBefore - box.totalAssets(), realisedLoss, 2, "nav falls by r x (A - V) / A within 2 wei");

        uint256 snapshot = vm.snapshotState();
        vm.warp(DEC25_MATURITY);
        assertEq(module.debtValue(fd), face - repaid, "remaining debt accretes to the new face");
        vm.revertToState(snapshot);

        usdcBefore = USDC.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "debt closed exactly");
        assertEq(usdcBefore - USDC.balanceOf(address(box)), face - repaid, "Box paid the remaining face");
        assertEq(USDC.balanceOf(address(module)), 0, "module holds no USDC");
        assertEq(module.debtValue(fd), 0, "no debt value");
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, 0, "accretion units reset");
        assertEq(rate, 0, "accretion rate reset");
    }

    // ========== MATURITY AND CLEANUP ==========

    function testRepayAtMaturityDepledgeAndCleanup() public {
        _assertNoMidnightAuthorisations(module);
        _open(module, fd, _dec25Market(), COLLATERAL, 100_000e6, 4212, "maturity");
        _assertNoMidnightAuthorisations(module);

        uint256 face = midnight.debt(DEC25_ID, address(module));
        uint256 collateralValue = (COLLATERAL * IOracle(BASE_CBBTC_USDC_ORACLE).price()) / 1e36;
        vm.warp(block.timestamp + 1 days);
        assertLt(module.debtValue(fd), face, "accreting before maturity");

        vm.warp(DEC25_MATURITY);
        assertTrue(module.isMatured(fd), "matured at the maturity timestamp");
        assertEq(module.debtValue(fd), face, "debt value = face at maturity");
        assertEq(module.nav(IOracleCallback(address(box))), collateralValue - face, "nav counts the debt at face");

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        assertEq(usdcBefore - USDC.balanceOf(address(box)), face, "Box paid exactly the face");
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "debt closed");

        box.depledge(module, fd, CBBTC, type(uint256).max);
        vm.stopPrank();
        assertEq(CBBTC.balanceOf(address(box)), COLLATERAL, "all cbBTC back in the Box");
        assertEq(midnight.collateral(DEC25_ID, address(module), 0), 0, "no collateral on Midnight");
        assertEq(USDC.balanceOf(address(module)), 0, "no idle USDC");
        assertEq(CBBTC.balanceOf(address(module)), 0, "no idle cbBTC");
        _assertNoMidnightAuthorisations(module);

        vm.startPrank(curator);
        box.removeFundingFacility(module, fd);
        box.removeFundingDebt(module, USDC);
        box.removeFundingCollateral(module, CBBTC);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
        assertFalse(module.isFacility(fd), "facility removed");
        assertEq(module.facilityOfMarket(DEC25_ID), bytes32(0), "market released");
        _assertNoMidnightAuthorisations(module);
    }

    // ========== POST-MATURITY LIQUIDATION ==========

    function testLiquidationExposureAfterMaturity() public {
        _open(module, fd, _dec25Market(), COLLATERAL, 100_000e6, 4212, "liquidation");
        uint256 face = midnight.debt(DEC25_ID, address(module));
        uint256 price = IOracle(BASE_CBBTC_USDC_ORACLE).price();

        vm.warp(DEC25_MATURITY + 1);
        assertTrue(module.isMatured(fd), "matured");
        Offer memory late = _bid(_dec25Market(), setterRatifier, 4212, "late", 100_000e6);
        bytes memory lateRd = _ratifyWithSetter(late);
        vm.startPrank(allocator);
        module.stageBorrow(fd, _fills(late, lateRd), block.timestamp + 1 hours);
        vm.expectRevert(ErrorsLib.FacilityMatured.selector);
        box.borrow(module, fd, USDC, 1_000e6);
        vm.stopPrank();
        assertEq(module.debtBalance(fd, USDC), face, "debtBalance unchanged");
        assertEq(module.nav(IOracleCallback(address(box))), (COLLATERAL * price) / 1e36 - face, "nav counts the face");

        vm.warp(DEC25_MATURITY + 30 minutes);
        address liquidator = makeAddr("liquidator");
        uint256 repaidUnits = face / 2;
        deal(address(USDC), liquidator, repaidUnits);
        vm.startPrank(liquidator);
        USDC.approve(address(midnight), repaidUnits);
        (uint256 seized, uint256 repaid) = midnight.liquidate(
            _dec25Market(),
            0,
            0,
            repaidUnits,
            address(module),
            true,
            liquidator,
            address(0),
            ""
        );
        vm.stopPrank();

        // maxLif = 1 / (1 - cursor x (1 - lltv)), reached 60 minutes after maturity; half of it after 30 minutes
        uint256 maxLif = WAD.mulDiv(WAD, WAD - CURSOR.mulDiv(WAD - LLTV, WAD));
        uint256 lif30 = WAD + (maxLif - WAD) / 2;
        uint256 impliedLif = (seized * price).mulDiv(WAD, repaid * 1e36);
        console2.log("seized cbBTC", seized);
        console2.log("repaid units", repaid);
        console2.log("maxLif      ", maxLif);
        console2.log("implied LIF ", impliedLif);
        assertApproxEqAbs(maxLif, 1.043841e18, 1e12, "maxLif about 1.043841 for LLTV 0.86 and cursor 0.3");
        assertEq(repaid, repaidUnits, "repaid the requested units");
        assertLe(impliedLif, maxLif, "LIF at most maxLif");
        assertApproxEqRel(impliedLif, lif30, 1e12, "LIF ramped halfway after 30 minutes");
        assertEq(CBBTC.balanceOf(liquidator), seized, "third party received the seized cbBTC");

        uint256 faceLeft = face - repaid;
        uint256 collateralLeft = COLLATERAL - seized;
        assertEq(module.debtBalance(fd, USDC), faceLeft, "face reduced");
        assertEq(module.collateralBalance(fd, CBBTC), collateralLeft, "collateral reduced");
        assertEq(module.debtValue(fd), faceLeft, "debt valued at face after maturity");
        assertEq(module.nav(IOracleCallback(address(box))), (collateralLeft * price) / 1e36 - faceLeft, "nav reflects the cut");
        assertEq(module.ltv(fd), faceLeft.mulDiv(WAD, (collateralLeft * price) / 1e36, Math.Rounding.Ceil), "ltv reflects the cut");
        assertEq(
            box.totalAssets(),
            USDC.balanceOf(address(box)) + module.nav(IOracleCallback(address(box))),
            "totalAssets = idle USDC + module nav"
        );

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        box.depledge(module, fd, CBBTC, type(uint256).max);
        vm.stopPrank();
        assertEq(usdcBefore - USDC.balanceOf(address(box)), faceLeft, "Box paid the remaining face");
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "debt closed");
        assertEq(CBBTC.balanceOf(address(box)), collateralLeft, "remaining cbBTC back in the Box");
        assertEq(midnight.collateral(DEC25_ID, address(module), 0), 0, "no collateral left");
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked + rate, 0, "accretion state cleared");
    }

    // ========== TWO MATURITIES ==========

    function testTwoMaturitiesAsSeparateFacilities() public {
        bytes memory octFd = abi.encode(_oct30Market(), uint256(1), MAX_APR);
        vm.startPrank(curator);
        box.addFundingFacilityInstant(module, octFd);
        vm.stopPrank();
        assertTrue(module.isFacility(fd) && module.isFacility(octFd), "both facilities coexist");
        assertEq(module.facilitiesLength(), 2, "two facilities");
        assertEq(module.marketId(octFd), OCT30_ID, "Oct-30 market");

        _expectDuplicateRejected(abi.encode(_dec25Market(), uint256(0), 0.05e18));
        _expectDuplicateRejected(abi.encode(_oct30Market(), uint256(1), 0.05e18));

        // Tick 4400 implies about 5.9% a year on the 36.6-day Oct-30 market
        uint256 decProceeds = _open(module, fd, _dec25Market(), COLLATERAL / 2, 50_000e6, 4212, "dec");
        uint256 octProceeds = _open(module, octFd, _oct30Market(), COLLATERAL / 2, 30_000e6, 4400, "oct");
        assertGe(decProceeds, 50_000e6, "Dec-25 borrow delivered");
        assertGe(octProceeds, 30_000e6, "Oct-30 borrow delivered");

        vm.warp(block.timestamp + 10 days);
        uint256 decFace = midnight.debt(DEC25_ID, address(module));
        uint256 octFace = midnight.debt(OCT30_ID, address(module));
        assertEq(midnight.collateral(OCT30_ID, address(module), 1), COLLATERAL / 2, "cbBTC at index 1 of Oct-30");
        assertEq(midnight.collateral(OCT30_ID, address(module), 0), 0, "nothing at index 0 (USDC) of Oct-30");
        assertEq(module.debtBalance(USDC), decFace + octFace, "token debt = sum of faces");
        assertEq(module.collateralBalance(CBBTC), COLLATERAL, "token collateral = sum");

        uint256 halfValue = ((COLLATERAL / 2) * IOracle(BASE_CBBTC_USDC_ORACLE).price()) / 1e36;
        uint256 decValue = halfValue - module.debtValue(fd);
        uint256 octValue = halfValue - module.debtValue(octFd);
        assertEq(module.nav(IOracleCallback(address(box))), decValue + octValue, "nav = sum of facility values");

        // Close Oct-30 only
        uint256 decValueBefore = module.debtValue(fd);
        vm.startPrank(allocator);
        box.repay(module, octFd, USDC, type(uint256).max);
        box.depledge(module, octFd, CBBTC, type(uint256).max);
        vm.stopPrank();
        assertEq(midnight.debt(OCT30_ID, address(module)), 0, "Oct-30 debt closed");
        assertEq(midnight.collateral(OCT30_ID, address(module), 1), 0, "Oct-30 collateral withdrawn");
        assertEq(midnight.debt(DEC25_ID, address(module)), decFace, "Dec-25 debt unchanged");
        assertEq(midnight.collateral(DEC25_ID, address(module), 0), COLLATERAL / 2, "Dec-25 collateral unchanged");
        assertEq(module.debtValue(fd), decValueBefore, "Dec-25 debt value unchanged");
        assertEq(module.debtBalance(USDC), decFace, "token debt = Dec-25 face");

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingFacility(module, fd);
        vm.prank(curator);
        box.removeFundingFacility(module, octFd);
        assertFalse(module.isFacility(octFd), "Oct-30 facility removed");
        assertTrue(module.isFacility(fd), "Dec-25 facility kept");

        vm.startPrank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        box.depledge(module, fd, CBBTC, type(uint256).max);
        vm.stopPrank();
        vm.prank(curator);
        box.removeFundingFacility(module, fd);
        assertEq(module.facilitiesLength(), 0, "both facilities removed");
        assertEq(CBBTC.balanceOf(address(box)), COLLATERAL, "all cbBTC back in the Box");
    }

    // ========== WINDDOWN ==========

    function testWinddownCloseByRandomAddress() public {
        ERC20MockDecimals unrelated = new ERC20MockDecimals(18);
        MockOracle unrelatedOracle = new MockOracle(1e24);
        vm.startPrank(curator);
        box.addTokenInstant(unrelated, unrelatedOracle);
        vm.stopPrank();

        _open(module, fd, _dec25Market(), COLLATERAL, 100_000e6, 4212, "winddown");
        Offer memory stale = _bid(_dec25Market(), setterRatifier, 4212, "stale", 100_000e6);
        bytes memory staleRd = _ratifyWithSetter(stale);
        vm.prank(allocator);
        module.stageBorrow(fd, _fills(stale, staleRd), block.timestamp + 1 hours);

        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + MAX_SHUTDOWN_WARMUP + 1);
        assertTrue(box.isWinddown(), "winddown");
        assertLt(block.timestamp, DEC25_MATURITY, "still before maturity");
        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        assertEq(staged.length, 1, "stale staging present");
        assertLt(validUntil, block.timestamp, "staging expired");

        uint256 face = midnight.debt(DEC25_ID, address(module));
        uint256 price = IOracle(BASE_CBBTC_USDC_ORACLE).price();
        // Leave collateral for an ltv of about 0.82: above LLTV x lltvCap (0.774), healthy for Midnight (below 0.86)
        uint256 collateralLeft = face.mulDiv(WAD, 0.82e18).mulDiv(1e36, price, Math.Rounding.Ceil);
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, fd, CBBTC, COLLATERAL - collateralLeft);

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(random);
        box.repay(module, fd, USDC, type(uint256).max);
        box.depledge(module, fd, CBBTC, type(uint256).max);
        vm.stopPrank();

        assertEq(usdcBefore - USDC.balanceOf(address(box)), face, "Box paid the face");
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "Midnight debt 0");
        assertEq(midnight.collateral(DEC25_ID, address(module), 0), 0, "no collateral on Midnight");
        assertEq(CBBTC.balanceOf(address(box)), COLLATERAL, "all collateral in the Box");
        assertEq(module.debtBalance(unrelated), 0, "unrelated Box token has no debt");
        assertEq(module.collateralBalance(unrelated), 0, "unrelated Box token has no collateral");
        assertEq(module.debtBalance(fd, unrelated), 0, "unrelated token has no facility debt");
        assertEq(module.nav(IOracleCallback(address(box))), 0, "empty position has no nav");
        assertEq(box.totalAssets(), USDC.balanceOf(address(box)) + (COLLATERAL * price) / 1e36, "totalAssets = idle USDC + idle cbBTC");
    }

    // ========== MAKER CALLBACKS DURING TAKE ==========

    /// @dev Real Midnight calls the maker callback after the module's debt grew and before the proceeds reach the Box:
    ///      the Box share price read there must still match the price before the borrow, and the Box cannot be reentered.
    function testTotalAssetsStableInsideMakerCallback() public {
        MidnightBuyCallbackProbe probe = new MidnightBuyCallbackProbe(
            IBox(address(box)),
            IFunding(address(module)),
            USDC,
            BASE_MIDNIGHT,
            fd
        );
        deal(address(USDC), address(probe), 1_000_000e6);
        vm.prank(curator);
        box.setIsAllocator(address(probe), true);

        Offer memory first = _bid(_dec25Market(), setterRatifier, 4216, "probe-1", 60_000e6);
        first.callback = address(probe);
        bytes memory firstRd = _ratifyWithSetter(first);
        Offer memory second = _bid(_dec25Market(), setterRatifier, 4212, "probe-2", 1_000_000e6);
        second.callback = address(probe);
        bytes memory secondRd = _ratifyWithSetter(second);

        uint256 totalBefore = box.totalAssets();
        uint256 lenderBefore = USDC.balanceOf(lender);
        vm.startPrank(allocator);
        box.pledge(module, fd, CBBTC, COLLATERAL);
        module.stageBorrow(fd, _fills(first, firstRd, second, secondRd), block.timestamp + 1 hours);
        box.borrow(module, fd, USDC, 100_000e6);
        vm.stopPrank();

        assertEq(probe.observations(), 2, "both fills called the maker callback");
        assertEq(USDC.balanceOf(lender), lenderBefore, "the callback paid, not the maker");
        assertApproxEqAbs(probe.observedTotalAssets(0), totalBefore, 2, "totalAssets inside the first callback");
        assertApproxEqAbs(probe.observedTotalAssets(1), totalBefore, 2, "totalAssets inside the second callback");
        assertApproxEqAbs(box.totalAssets(), totalBefore, 2, "totalAssets after the borrow");
        assertEq(probe.reentryAttempts(), 4);
        assertEq(probe.reentrySuccesses(), 0, "no Box reentry from the callback");
    }

    // ========== FORK FUZZ ==========

    /// @dev One fresh SetterRatifier bid per run at a tick between 4204 and 4216 (all within the 8% bound). Borrows
    ///      stay at or below 70% of the collateral value, so face / value stays under LLTV x lltvCap (0.774). Collateral
    ///      returns exactly and nothing else moves, so the round trip costs exactly the discount (face - proceeds).
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_PledgeBorrowRepayDepledgeRoundTrip(uint256 collateral, uint256 amount, uint256 tickStep, uint256 elapsed) public {
        collateral = bound(collateral, 0.5e8, COLLATERAL);
        uint256 collateralValue = (collateral * IOracle(BASE_CBBTC_USDC_ORACLE).price()) / 1e36;
        amount = bound(amount, 5_000e6, (collateralValue * 70) / 100);
        uint256 tick = 4204 + 4 * bound(tickStep, 0, 3);
        elapsed = bound(elapsed, 0, 60 days);
        uint256 minPrice = MidnightMathLib.minSellerPrice(MAX_APR, DEC25_MATURITY - block.timestamp);
        assertGe(TickLib.tickToPrice(tick), minPrice, "bid within the 8% bound");

        uint256 cbbtcBefore = CBBTC.balanceOf(address(box));
        uint256 navBefore = box.totalAssets();

        uint256 proceeds = _open(module, fd, _dec25Market(), collateral, amount, tick, "fuzz");
        uint256 face = midnight.debt(DEC25_ID, address(module));

        assertGe(proceeds, amount, "Box received at least the amount");
        assertGt(face, proceeds, "face above proceeds");
        assertEq(module.debtBalance(fd, USDC), face, "debtBalance = face");
        assertEq(module.collateralBalance(fd, CBBTC), collateral, "collateral = pledged");
        assertEq(USDC.balanceOf(address(module)), 0, "no USDC left in the module");
        assertLe(module.ltv(fd), (LLTV * LLTV_CAP) / WAD, "ltv within LLTV x lltvCap");
        // 1 wei from the discount rounding, 1 wei from flooring the Box and module cbBTC values separately
        assertApproxEqAbs(box.totalAssets(), navBefore, 2, "pledge + borrow within 2 wei");

        vm.warp(block.timestamp + elapsed);
        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        box.depledge(module, fd, CBBTC, type(uint256).max);
        vm.stopPrank();

        assertEq(usdcBefore - USDC.balanceOf(address(box)), face, "repay(max) paid exactly the face");
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "no Midnight debt");
        assertEq(midnight.collateral(DEC25_ID, address(module), 0), 0, "no collateral on Midnight");
        assertEq(module.debtBalance(fd, USDC), 0, "facility debt 0");
        assertEq(module.collateralBalance(fd, CBBTC), 0, "facility collateral 0");
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, 0, "accretion units reset");
        assertEq(rate, 0, "accretion rate reset");
        assertEq(CBBTC.balanceOf(address(box)), cbbtcBefore, "all cbBTC back in the Box");
        assertEq(USDC.balanceOf(address(module)), 0, "no idle USDC");
        assertEq(CBBTC.balanceOf(address(module)), 0, "no idle cbBTC");
        assertEq(box.totalAssets(), navBefore - (face - proceeds), "totalAssets = start - discount paid, exactly");
    }

    // ========== HELPERS ==========

    function _dec25Market() internal pure returns (Market memory market) {
        market.chainId = BASE_CHAIN_ID;
        market.midnight = BASE_MIDNIGHT;
        market.loanToken = BASE_USDC;
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] = CollateralParams(BASE_CBBTC, LLTV, CURSOR, BASE_CBBTC_USDC_ORACLE);
        market.maturity = DEC25_MATURITY;
        market.rcfThreshold = 3000e6;
    }

    /// @dev Collateral sorted by address: [0] USDC (LLTV 0.98), [1] cbBTC (LLTV 0.86)
    function _oct30Market() internal pure returns (Market memory market) {
        market.chainId = BASE_CHAIN_ID;
        market.midnight = BASE_MIDNIGHT;
        market.loanToken = BASE_USDC;
        market.collateralParams = new CollateralParams[](2);
        market.collateralParams[0] = CollateralParams(BASE_USDC, 0.98e18, CURSOR, BASE_USDC_USDC_ORACLE);
        market.collateralParams[1] = CollateralParams(BASE_CBBTC, LLTV, CURSOR, BASE_CBBTC_USDC_ORACLE);
        market.maturity = OCT30_MATURITY;
        market.rcfThreshold = 3000e6;
    }

    /// @dev Factory module attached to the Box without timelocks, with cbBTC collateral, USDC debt and one facility
    function _attachInstant(
        Market memory market,
        uint256 collateralIndex,
        uint256 maxApr
    ) internal returns (FundingMidnight fundingModule, bytes memory facilityData) {
        fundingModule = factory.createFundingMidnight(address(box), BASE_MIDNIGHT, LLTV_CAP);
        facilityData = abi.encode(market, collateralIndex, maxApr);
        vm.startPrank(curator);
        box.addFundingInstant(fundingModule);
        box.addFundingCollateralInstant(fundingModule, CBBTC);
        box.addFundingDebtInstant(fundingModule, USDC);
        box.addFundingFacilityInstant(fundingModule, facilityData);
        vm.stopPrank();
    }

    /// @dev Pledges `collateral` cbBTC and borrows `amount` from one fresh SetterRatifier bid; returns the Box USDC delta
    function _open(
        FundingMidnight fundingModule,
        bytes memory facilityData,
        Market memory market,
        uint256 collateral,
        uint256 amount,
        uint256 tick,
        bytes32 group
    ) internal returns (uint256 proceeds) {
        Offer memory bid = _bid(market, setterRatifier, tick, group, uint128(2 * amount));
        bytes memory rd = _ratifyWithSetter(bid);
        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.startPrank(allocator);
        box.pledge(fundingModule, facilityData, CBBTC, collateral);
        fundingModule.stageBorrow(facilityData, _fills(bid, rd), block.timestamp + 1 hours);
        box.borrow(fundingModule, facilityData, USDC, amount);
        vm.stopPrank();
        proceeds = USDC.balanceOf(address(box)) - usdcBefore;
    }

    function _expectDuplicateRejected(bytes memory facilityData) internal {
        bytes memory call = abi.encodeCall(IBox.addFundingFacility, (IFunding(address(module)), facilityData));
        vm.prank(curator);
        box.submit(call);
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        box.addFundingFacility(module, facilityData);
    }

    function _realFills() internal view returns (OfferFill[] memory fills) {
        assertEq(block.number, MidnightBaseOffers.BLOCK, "real offers replayed at their block");
        fills = abi.decode(MidnightBaseOffers.encodedFills(), (OfferFill[]));
    }

    function _consumed(OfferFill[] memory fills) internal view returns (uint256[] memory consumed) {
        consumed = new uint256[](fills.length);
        for (uint256 i = 0; i < fills.length; i++) {
            consumed[i] = midnight.consumed(fills[i].offer.maker, fills[i].offer.group);
        }
    }

    /// @dev Units the module sells into `fill` to raise `target` (fee 0), capped by the offer capacity and the fill cap
    function _expectedFill(OfferFill memory fill, uint256 target) internal view returns (uint256 units, uint256 assets) {
        Offer memory offer = fill.offer;
        uint256 price = TickLib.tickToPrice(offer.tick);
        uint256 capacity = MidnightMathLib.consumableUnitsOfBuyOffer(
            offer.maxUnits,
            offer.maxAssets,
            midnight.consumed(offer.maker, offer.group),
            price
        );
        units = Math.min(MidnightMathLib.unitsForSellerAssets(target, price), Math.min(capacity, fill.maxUnits));
        assets = (units * price) / WAD;
    }

    /// @dev What Midnight adds to consumed[maker][group] for a fill: buyer assets for asset-capped offers, else units
    function _consumption(OfferFill memory fill, uint256 units, uint256 assets) internal pure returns (uint256) {
        return fill.offer.maxAssets > 0 ? assets : units;
    }

    function _assertNoMidnightAuthorisations(FundingMidnight fundingModule) internal view {
        address[5] memory others = [address(box), allocator, setterRatifier, ecrecoverRatifier, lender];
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(midnight.isAuthorized(address(fundingModule), others[i]), "module authorised nobody on Midnight");
        }
    }
}
