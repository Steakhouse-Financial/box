// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {CollateralParams, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "../src/libraries/midnight/MidnightMathLib.sol";
import {TickLib} from "../src/libraries/midnight/TickLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MIDNIGHT_CALLBACK_SUCCESS, MockMidnight} from "./mocks/MockMidnight.sol";
import {MockMidnightRatifier} from "./mocks/MockMidnightRatifier.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @dev Maker callback recording the seller's state when it runs, and trying to liquidate the seller after crashing
///      the collateral price (which would make it liquidatable outside a take)
contract RecordingBuyCallback {
    MockMidnight internal immutable midnight;
    MockOracle internal immutable oracle;
    Market internal market;
    address internal immutable seller;
    address internal immutable receiver;

    bytes32 public answer = MIDNIGHT_CALLBACK_SUCCESS;
    uint256 public calls;
    uint256 public debtSeen;
    uint256 public receiverBalanceSeen;
    bool public liquidationBlocked;

    constructor(MockMidnight midnight_, MockOracle oracle_, Market memory market_, address seller_, address receiver_) {
        midnight = midnight_;
        oracle = oracle_;
        market = market_;
        seller = seller_;
        receiver = receiver_;
        IERC20(market_.loanToken).approve(address(midnight_), type(uint256).max);
    }

    function setAnswer(bytes32 newAnswer) external {
        answer = newAnswer;
    }

    function onBuy(bytes32 id, Market memory, uint256, uint256, uint256, address, bytes memory) external returns (bytes32) {
        calls++;
        debtSeen = midnight.debt(id, seller);
        receiverBalanceSeen = IERC20(market.loanToken).balanceOf(receiver);
        uint256 price = oracle.price();
        oracle.setPrice(price / 10);
        try midnight.liquidate(market, 0, 0, 1, seller, false, address(this), address(0), "") {} catch (bytes memory reason) {
            liquidationBlocked = bytes4(reason) == MockMidnight.NotLiquidatable.selector;
        }
        oracle.setPrice(price);
        return answer;
    }
}

/// @dev Sanity tests pinning the Midnight semantics the mock reproduces (library worked example numbers).
contract MockMidnightTest is Test {
    uint256 internal constant CBBTC_PRICE = 842515000000000000000000000000000000000; // 84,251.5 loan units per 1e8
    uint256 internal constant MATURITY_OFFSET = 7_998_189;
    uint256 internal constant FACE_100K = 101_515_329_475; // units for 100,000e6 proceeds at tick 4212

    MockMidnight internal midnight;
    MockMidnightRatifier internal ratifier;
    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal cbBtc;
    MockOracle internal oracle;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal box = makeAddr("box");
    address internal stranger = makeAddr("stranger");

    Market internal market;
    bytes32 internal id;

    function setUp() public {
        midnight = new MockMidnight();
        ratifier = new MockMidnightRatifier();
        usdc = new ERC20MockDecimals(6);
        cbBtc = new ERC20MockDecimals(8);
        oracle = new MockOracle(CBBTC_PRICE);

        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = address(usdc);
        market.collateralParams.push(CollateralParams(address(cbBtc), 0.86e18, 0.3e18, address(oracle)));
        market.maturity = block.timestamp + MATURITY_OFFSET;
        market.rcfThreshold = 3000e6;
        id = IdLib.toId(market);

        usdc.mint(lender, 10_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ratifier), true, lender);
        vm.stopPrank();

        cbBtc.mint(borrower, 10e8);
        usdc.mint(borrower, 1_000_000e6);
        vm.startPrank(borrower);
        cbBtc.approve(address(midnight), type(uint256).max);
        usdc.approve(address(midnight), type(uint256).max);
        midnight.supplyCollateral(market, 0, 5e8, borrower);
        vm.stopPrank();
    }

    // ========== HELPERS ==========

    function _offer(uint256 tick, bytes32 group) internal view returns (Offer memory o) {
        o.market = market;
        o.buy = true;
        o.maker = lender;
        o.start = block.timestamp;
        o.expiry = block.timestamp + 2 hours;
        o.tick = tick;
        o.group = group;
        o.ratifier = address(ratifier);
        o.maxAssets = 5_000_000e6;
        o.continuousFeeCap = type(uint256).max;
    }

    function _ratified(uint256 tick, bytes32 group) internal returns (Offer memory o) {
        o = _offer(tick, group);
        ratifier.setOfferRatified(o, true);
    }

    function _take(Offer memory o, uint256 units) internal returns (uint256 buyerAssets, uint256 sellerAssets) {
        vm.prank(borrower);
        return midnight.take(o, "", units, borrower, box, address(0), "");
    }

    function _expectTakeRevert(Offer memory o, uint256 units, bytes memory err) internal {
        vm.expectRevert(err);
        _take(o, units);
    }

    // ========== MARKETS ==========

    function testMarketsAreCreatedLazily() public {
        Market memory other = market;
        other.maturity = market.maturity + 1;
        bytes32 otherId = IdLib.toId(other);
        assertEq(midnight.tickSpacing(otherId), 0);
        vm.expectRevert(MockMidnight.MarketNotCreated.selector);
        midnight.settlementFee(otherId, 1 days);

        assertEq(midnight.touchMarket(other), otherId);
        assertEq(midnight.tickSpacing(otherId), 4);
        assertEq(midnight.settlementFee(otherId, 1 days), 0);
        assertEq(midnight.touchMarket(other), otherId, "idempotent");
        // The setUp supply created the main market.
        assertEq(midnight.tickSpacing(id), 4);
    }

    function testTouchMarketValidation() public {
        Market memory m = market;
        m.maturity = market.maturity + 1;

        m.chainId = block.chainid + 1;
        vm.expectRevert(MockMidnight.InvalidChainId.selector);
        midnight.touchMarket(m);
        m.chainId = block.chainid;

        m.midnight = address(1);
        vm.expectRevert(MockMidnight.InvalidMidnight.selector);
        midnight.touchMarket(m);
        m.midnight = address(midnight);

        m.collateralParams = new CollateralParams[](0);
        vm.expectRevert(MockMidnight.NoCollateralParams.selector);
        midnight.touchMarket(m);

        m.collateralParams = new CollateralParams[](2);
        m.collateralParams[0] = CollateralParams(address(cbBtc), 0.86e18, 0.3e18, address(oracle));
        m.collateralParams[1] = CollateralParams(address(cbBtc), 0.86e18, 0.3e18, address(oracle));
        vm.expectRevert(MockMidnight.CollateralParamsNotSorted.selector);
        midnight.touchMarket(m);

        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] = CollateralParams(address(cbBtc), 1e18, 0.3e18, address(oracle));
        vm.expectRevert(MockMidnight.InvalidLltv.selector);
        midnight.touchMarket(m);
    }

    // ========== TAKE ==========

    function testTakeBidSendsProceedsToReceiverAndAddsFaceDebt() public {
        Offer memory o = _ratified(4212, "g");
        uint256 units = MidnightMathLib.unitsForSellerAssets(100_000e6, TickLib.tickToPrice(4212));
        assertEq(units, FACE_100K);

        (uint256 buyerAssets, uint256 sellerAssets) = _take(o, units);

        assertEq(sellerAssets, 100_000e6, "seller assets");
        assertEq(buyerAssets, 100_000e6, "no fee: buyer pays seller assets");
        assertEq(usdc.balanceOf(box), 100_000e6, "proceeds at receiver");
        assertEq(usdc.balanceOf(borrower), 1_000_000e6, "taker receives nothing");
        assertEq(usdc.balanceOf(lender), 10_000_000e6 - 100_000e6, "maker pays");
        assertEq(midnight.debt(id, borrower), FACE_100K, "face debt");
        assertEq(midnight.credit(id, lender), FACE_100K, "lender credit");
        assertEq(midnight.consumed(lender, "g"), 100_000e6, "assets-capped offer consumes buyer assets");
        assertEq(midnight.takeCount(), 1);
    }

    function testTakeNetOfSettlementFee() public {
        midnight.setSettlementFee(id, 0.001e18);
        Offer memory o = _ratified(4212, "g");
        (uint256 buyerAssets, uint256 sellerAssets) = _take(o, FACE_100K);

        assertEq(buyerAssets, (FACE_100K * 985072900000000000) / 1e18);
        assertEq(sellerAssets, (FACE_100K * 984072900000000000) / 1e18);
        assertEq(usdc.balanceOf(box), sellerAssets);
        assertEq(usdc.balanceOf(address(midnight)), buyerAssets - sellerAssets, "fee kept by Midnight");
        assertEq(midnight.consumed(lender, "g"), buyerAssets);
    }

    function testTakeRevertsWhenFeeAbovePrice() public {
        midnight.setSettlementFee(id, 0.99e18);
        _expectTakeRevert(_ratified(4212, "g"), 1e6, stdError.arithmeticError);
    }

    function testOnePositionPerMarketPerAddress() public {
        _take(_ratified(4212, "a"), FACE_100K);
        _take(_ratified(4240, "b"), 50_658_935_978);
        assertEq(midnight.debt(id, borrower), FACE_100K + 50_658_935_978, "both takes add to one debt");
        assertEq(usdc.balanceOf(box), 150_000e6);
    }

    function testTakeUnitsCap() public {
        Offer memory o = _offer(4212, "u");
        o.maxAssets = 0;
        o.maxUnits = 1000e6;
        ratifier.setOfferRatified(o, true);

        _take(o, 600e6);
        assertEq(midnight.consumed(lender, "u"), 600e6, "units-capped offer consumes units");
        _expectTakeRevert(o, 400e6 + 1, abi.encodeWithSelector(MockMidnight.ConsumedUnits.selector));
        _take(o, 400e6);
        assertEq(midnight.consumed(lender, "u"), 1000e6);
    }

    function testTakeAssetsCapMatchesConsumableUnits() public {
        Offer memory o = _offer(4216, "c");
        o.maxAssets = 101e6;
        ratifier.setOfferRatified(o, true);
        uint256 maxUnits = MidnightMathLib.consumableUnitsOfBuyOffer(0, o.maxAssets, 0, TickLib.tickToPrice(4216));
        assertEq(maxUnits, 102_500_256);

        _expectTakeRevert(o, maxUnits + 1, abi.encodeWithSelector(MockMidnight.ConsumedAssets.selector));
        _take(o, maxUnits);
        assertEq(midnight.consumed(lender, "c"), 101e6);
    }

    function testTakeZeroUnitsIsNoOp() public {
        (uint256 buyerAssets, uint256 sellerAssets) = _take(_ratified(4212, "g"), 0);
        assertEq(buyerAssets, 0);
        assertEq(sellerAssets, 0);
        assertEq(midnight.debt(id, borrower), 0);
    }

    function testTakeAllowedAtMaturityBlockedAfter() public {
        vm.warp(market.maturity);
        Offer memory o = _ratified(6744, "g");
        _take(o, 1e6);
        assertEq(midnight.debt(id, borrower), 1e6, "Midnight still allows a debt increase at maturity");

        vm.warp(market.maturity + 1);
        o = _offer(6744, "h");
        o.start = market.maturity;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.CannotIncreaseDebtPostMaturity.selector));
    }

    function testTakeRevertsForConsumedGroup() public {
        Offer memory o = _ratified(4212, "g");
        vm.prank(lender);
        midnight.setConsumed("g", type(uint128).max, lender);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.ConsumedAssets.selector));
    }

    function testTakeRevertsForExpiredOrNotStartedOffer() public {
        Offer memory o = _ratified(4212, "g");
        vm.warp(o.expiry + 1);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.OfferExpired.selector));

        o = _offer(4212, "g");
        o.start = block.timestamp + 1;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.OfferNotStarted.selector));
    }

    function testTakeRatifierChecks() public {
        Offer memory o = _offer(4212, "g");
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnightRatifier.NotRatified.selector));

        ratifier.setOfferRatified(o, true);
        ratifier.setReturnWrongValue(true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.RatifierFailed.selector));
        ratifier.setReturnWrongValue(false);

        vm.prank(lender);
        midnight.setIsAuthorized(address(ratifier), false, lender);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.RatifierUnauthorized.selector));

        vm.prank(lender);
        midnight.setIsAuthorized(address(ratifier), true, lender);
        _take(o, 1e6);
        assertEq(midnight.debt(id, borrower), 1e6);
    }

    function testTakeOfferValidation() public {
        Offer memory o = _ratified(4214, "g");
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.TickNotAccessible.selector));

        o = _ratified(6748, "g");
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(TickLib.TickOutOfRange.selector));

        o = _offer(4212, "g");
        o.maxUnits = 1;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.InvalidOfferCaps.selector));

        o = _offer(4212, "g");
        o.receiverIfMakerIsSeller = stranger;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.UnusedReceiverMustBeZero.selector));

        midnight.setContinuousFee(id, 10);
        o = _offer(4212, "g");
        o.continuousFeeCap = 9;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.ContinuousFeeAboveOfferCap.selector));

        o = _offer(4212, "g");
        o.buy = false;
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.SellOffersNotSupported.selector));

        o = _ratified(4212, "g");
        vm.prank(borrower);
        vm.expectRevert(MockMidnight.CallbackNotSupported.selector);
        midnight.take(o, "", 1e6, borrower, box, stranger, "");
    }

    function testTakeMakerCallbackPaysAndLocksLiquidation() public {
        RecordingBuyCallback callback = new RecordingBuyCallback(midnight, oracle, market, borrower, box);
        usdc.mint(address(callback), 200_000e6);
        Offer memory o = _offer(4212, "cb");
        o.callback = address(callback);
        ratifier.setOfferRatified(o, true);

        uint256 lenderBefore = usdc.balanceOf(lender);
        (, uint256 sellerAssets) = _take(o, FACE_100K);

        assertEq(callback.calls(), 1);
        assertEq(callback.debtSeen(), FACE_100K, "debt already grown when the callback runs");
        assertEq(callback.receiverBalanceSeen(), 0, "proceeds not transferred yet");
        assertTrue(callback.liquidationBlocked(), "seller locked against liquidation during the take");
        assertEq(usdc.balanceOf(box), sellerAssets, "receiver paid after the callback");
        assertEq(usdc.balanceOf(address(callback)), 200_000e6 - sellerAssets, "callback is the payer");
        assertEq(usdc.balanceOf(lender), lenderBefore, "maker pays nothing");
        assertFalse(midnight.liquidationLocked(id, borrower), "lock released");

        callback.setAnswer(bytes32(0));
        o.group = "cb2";
        ratifier.setOfferRatified(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.WrongBuyCallbackReturnValue.selector));
    }

    function testTakeTakerChecks() public {
        Offer memory o = _ratified(4212, "g");

        vm.prank(stranger);
        vm.expectRevert(MockMidnight.TakerUnauthorized.selector);
        midnight.take(o, "", 1e6, borrower, box, address(0), "");

        vm.prank(lender);
        vm.expectRevert(MockMidnight.SelfTake.selector);
        midnight.take(o, "", 1e6, lender, box, address(0), "");

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        midnight.take(o, "", 1e6, borrower, address(0), address(0), "");
    }

    function testTakeRequiresHealthySeller() public {
        Offer memory o = _ratified(4212, "g");
        vm.prank(stranger);
        vm.expectRevert(MockMidnight.SellerIsLiquidatable.selector);
        midnight.take(o, "", 1e6, stranger, box, address(0), "");

        // 5 cbBTC at 84,251.5 with LLTV 0.86 support 362,281.45 USDC of face debt, not one unit more.
        _expectTakeRevert(o, 362_281_450_001, abi.encodeWithSelector(MockMidnight.SellerIsLiquidatable.selector));
        _take(o, 362_281_450_000);
        assertTrue(midnight.isHealthy(market, id, borrower));
    }

    function testForcedTakeRevert() public {
        Offer memory o = _ratified(4212, "g");
        midnight.setForcedTakeRevert(o, true);
        _expectTakeRevert(o, 1e6, abi.encodeWithSelector(MockMidnight.ForcedTakeRevert.selector));
        midnight.setForcedTakeRevert(o, false);
        _take(o, 1e6);
        assertEq(midnight.takeCount(), 1);
    }

    // ========== REPAY ==========

    function testRepayPullsExactFace() public {
        _take(_ratified(4212, "g"), FACE_100K);
        uint256 before = usdc.balanceOf(borrower);

        vm.prank(borrower);
        midnight.repay(market, 60_000e6, borrower, address(0), "");
        assertEq(before - usdc.balanceOf(borrower), 60_000e6, "partial repay pulls exactly the units");
        assertEq(midnight.debt(id, borrower), FACE_100K - 60_000e6);

        vm.prank(borrower);
        vm.expectRevert(stdError.arithmeticError);
        midnight.repay(market, FACE_100K - 60_000e6 + 1, borrower, address(0), "");

        vm.prank(borrower);
        midnight.repay(market, FACE_100K - 60_000e6, borrower, address(0), "");
        assertEq(midnight.debt(id, borrower), 0, "exact face closes with no dust");
        assertEq(before - usdc.balanceOf(borrower), FACE_100K);
    }

    function testRepayRequiresBorrowerOrAuthorized() public {
        _take(_ratified(4212, "g"), FACE_100K);
        usdc.mint(stranger, 1e6);
        vm.startPrank(stranger);
        usdc.approve(address(midnight), 1e6);
        vm.expectRevert(MockMidnight.Unauthorized.selector);
        midnight.repay(market, 1e6, borrower, address(0), "");
        vm.stopPrank();
    }

    function testRepayWorksAfterMaturity() public {
        _take(_ratified(4212, "g"), FACE_100K);
        vm.warp(market.maturity + 10 days);
        vm.prank(borrower);
        midnight.repay(market, FACE_100K, borrower, address(0), "");
        assertEq(midnight.debt(id, borrower), 0);
    }

    // ========== COLLATERAL ==========

    function testSupplyAndWithdrawCollateral() public {
        assertEq(midnight.collateral(id, borrower, 0), 5e8);
        assertEq(cbBtc.balanceOf(address(midnight)), 5e8);

        vm.prank(borrower);
        midnight.withdrawCollateral(market, 0, 2e8, borrower, box);
        assertEq(cbBtc.balanceOf(box), 2e8, "withdrawn to receiver");
        assertEq(midnight.collateral(id, borrower, 0), 3e8);

        vm.prank(borrower);
        vm.expectRevert(stdError.arithmeticError);
        midnight.withdrawCollateral(market, 0, 3e8 + 1, borrower, box);

        vm.prank(stranger);
        vm.expectRevert(MockMidnight.Unauthorized.selector);
        midnight.withdrawCollateral(market, 0, 1, borrower, stranger);

        vm.prank(stranger);
        vm.expectRevert(MockMidnight.Unauthorized.selector);
        midnight.supplyCollateral(market, 0, 1, borrower);

        vm.prank(borrower);
        vm.expectRevert(stdError.indexOOBError);
        midnight.supplyCollateral(market, 1, 1, borrower);
    }

    function testWithdrawCollateralRequiresHealth() public {
        _take(_ratified(4212, "g"), FACE_100K);
        // Face 101,515.33 needs ceil(face / (84,251.5 * 0.86)) cbBTC: 140,105,614 sats; withdrawable = 5e8 - that.
        vm.prank(borrower);
        vm.expectRevert(MockMidnight.UnhealthyBorrower.selector);
        midnight.withdrawCollateral(market, 0, 5e8 - 140_105_613, borrower, box);
        vm.prank(borrower);
        midnight.withdrawCollateral(market, 0, 5e8 - 140_105_614, borrower, box);
        assertEq(midnight.collateral(id, borrower, 0), 140_105_614);
    }

    function testOracleCalledOnFirstActivationOnlyAndNotWithoutDebt() public {
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IOracle.price.selector), "oracle down");

        vm.prank(borrower);
        midnight.supplyCollateral(market, 0, 1e8, borrower); // already active: no oracle call
        assertEq(midnight.collateral(id, borrower, 0), 6e8);

        vm.prank(borrower);
        midnight.withdrawCollateral(market, 0, 6e8, borrower, box); // debt 0: healthy without oracle
        assertEq(midnight.collateral(id, borrower, 0), 0);

        vm.prank(borrower);
        vm.expectRevert("oracle down");
        midnight.supplyCollateral(market, 0, 1e8, borrower); // first activation calls the oracle
    }

    // ========== LIQUIDATION / EXTERNAL FACE CUT ==========

    function testPostMaturityLiquidationLibraryExample() public {
        _take(_ratified(4212, "g"), FACE_100K);
        address liquidator = makeAddr("liquidator");
        usdc.mint(liquidator, FACE_100K);
        vm.prank(liquidator);
        usdc.approve(address(midnight), FACE_100K);

        vm.warp(market.maturity);
        vm.prank(liquidator);
        vm.expectRevert(MockMidnight.NotLiquidatable.selector);
        midnight.liquidate(market, 0, 0, FACE_100K, borrower, true, liquidator, address(0), "");

        vm.warp(market.maturity + 30 minutes);
        assertEq(midnight.liquidationIncentiveFactor(0.86e18, 0.3e18, market.maturity, true), 1_021_920_668_058_455_114);
        vm.prank(liquidator);
        (uint256 seized, uint256 repaid) = midnight.liquidate(market, 0, 0, FACE_100K, borrower, true, liquidator, address(0), "");
        assertEq(repaid, FACE_100K);
        assertEq(seized, 123_132_066);
        assertEq(cbBtc.balanceOf(liquidator), 123_132_066);
        assertEq(midnight.debt(id, borrower), 0);
        assertEq(midnight.collateral(id, borrower, 0), 5e8 - 123_132_066);
    }

    function testPreMaturityLiquidationOnlyWhenUnhealthy() public {
        _take(_ratified(4212, "g"), FACE_100K);
        address liquidator = makeAddr("liquidator");
        usdc.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(midnight), 10_000e6);

        vm.prank(liquidator);
        vm.expectRevert(MockMidnight.NotLiquidatable.selector);
        midnight.liquidate(market, 0, 0, 10_000e6, borrower, false, liquidator, address(0), "");

        oracle.setPrice(CBBTC_PRICE / 4);
        assertFalse(midnight.isHealthy(market, id, borrower));
        vm.prank(liquidator);
        (, uint256 repaid) = midnight.liquidate(market, 0, 0, 10_000e6, borrower, false, liquidator, address(0), "");
        assertEq(repaid, 10_000e6);
        assertEq(midnight.debt(id, borrower), FACE_100K - 10_000e6);
    }

    function testReduceDebtHook() public {
        _take(_ratified(4212, "g"), FACE_100K);
        midnight.reduceDebt(id, borrower, 10_000e6);
        assertEq(midnight.debt(id, borrower), FACE_100K - 10_000e6);
        vm.expectRevert(stdError.arithmeticError);
        midnight.reduceDebt(id, borrower, FACE_100K);
    }

    function testSetIsAuthorizedOnlyForSelf() public {
        vm.prank(stranger);
        vm.expectRevert(MockMidnight.Unauthorized.selector);
        midnight.setIsAuthorized(stranger, true, borrower);

        vm.prank(borrower);
        midnight.setIsAuthorized(stranger, true, borrower);
        assertTrue(midnight.isAuthorized(borrower, stranger));
        vm.prank(stranger);
        midnight.withdrawCollateral(market, 0, 1e8, borrower, stranger);
        assertEq(cbBtc.balanceOf(stranger), 1e8);
    }
}
