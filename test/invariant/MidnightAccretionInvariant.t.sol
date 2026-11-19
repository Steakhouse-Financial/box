// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Box} from "../../src/Box.sol";
import {FundingMidnight} from "../../src/FundingMidnight.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {CollateralParams, Market} from "../../src/interfaces/midnight/IMidnight.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockMidnight} from "../mocks/MockMidnight.sol";
import {MockMidnightRatifier} from "../mocks/MockMidnightRatifier.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MidnightAccretionHandler, MidnightAccretionSystem} from "./handlers/MidnightAccretionHandler.sol";

/// @notice Stateful invariants of FundingMidnight's debt accretion on MockMidnight, driven through a real Box: staged
/// borrows at fuzzed prices at or above the APR floor, partial and full repays, external face reductions and warps,
/// including exactly to and past each maturity.
/// @dev Two facilities on the same tokens (USDC loan, the Box asset; cbBTC collateral, 100 cbBTC pledged in each) with
///      different maturities, the second one with a settlement fee. Collateral is never repriced, so both facilities stay
///      healthy in Box terms and a borrow moves totalAssets only by its accretion rounding.
contract MidnightAccretionInvariantTest is Test {
    using BoxLib for IBox;

    uint256 internal constant T0 = 1790212611;
    uint256 internal constant CBBTC_PRICE = 842515000000000000000000000000000000000; // 84,251.5 USDC per cbBTC
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LLTV_CAP = 0.9e18;
    uint256 internal constant MAX_APR = 0.2e18;
    uint256 internal constant FEE_B = 0.0005e18;

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal lender = makeAddr("lender");

    IBox internal box;
    FundingMidnight internal module;
    MockMidnight internal midnight;
    ERC20MockDecimals internal usdc;
    MidnightAccretionHandler internal handler;

    function setUp() public {
        vm.warp(T0);
        midnight = new MockMidnight();
        MockMidnightRatifier ratifier = new MockMidnightRatifier();
        ratifier.setAcceptAll(true);
        usdc = new ERC20MockDecimals(6);
        ERC20MockDecimals cbBtc = new ERC20MockDecimals(8);
        MockOracle oracle = new MockOracle(CBBTC_PRICE);

        Market memory marketA = _market(address(usdc), address(cbBtc), address(oracle), T0 + 45 days);
        Market memory marketB = _market(address(usdc), address(cbBtc), address(oracle), T0 + 120 days);
        midnight.touchMarket(marketA);
        midnight.setSettlementFee(midnight.touchMarket(marketB), FEE_B);
        bytes[2] memory fds = [abi.encode(marketA, uint256(0), MAX_APR), abi.encode(marketB, uint256(0), MAX_APR)];

        box = IBox(
            address(new Box(address(usdc), boxOwner, curator, "Box Midnight Invariant", "BMI", 0.01 ether, 7 days, 10 days, 7 days))
        );
        module = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.startPrank(curator);
        box.addTokenInstant(cbBtc, oracle);
        box.setIsAllocator(allocator, true);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, cbBtc);
        box.addFundingDebtInstant(module, usdc);
        box.addFundingFacilityInstant(module, fds[0]);
        box.addFundingFacilityInstant(module, fds[1]);
        vm.stopPrank();

        cbBtc.mint(address(box), 200e8);
        vm.startPrank(allocator);
        box.pledge(module, fds[0], cbBtc, 100e8);
        box.pledge(module, fds[1], cbBtc, 100e8);
        vm.stopPrank();

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(ratifier), true, lender);
        usdc.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        handler = new MidnightAccretionHandler(
            MidnightAccretionSystem({
                box: box,
                module: module,
                midnight: midnight,
                usdc: usdc,
                collateralOracle: oracle,
                ratifier: address(ratifier),
                allocator: allocator,
                lender: lender,
                fds: fds,
                maxBorrowApr: MAX_APR
            })
        );
        targetContract(address(handler));
    }

    // ========== INVARIANTS ==========

    /// @dev (a) outstanding proceeds (scaled by repays and face reductions) <= debt value <= face, per facility
    function invariant_debtValueBetweenProceedsAndFace() public view {
        for (uint256 i; i < 2; i++) {
            bytes memory fd = handler.facilityData(i);
            uint256 debtValue = module.debtValue(fd);
            assertLe(handler.outstandingProceeds(i), debtValue, "outstanding proceeds <= debt value");
            assertLe(debtValue, midnight.debt(handler.marketIdOf(i), address(module)), "debt value <= face");
        }
    }

    /// @dev (c) the debt value equals the face at and after maturity
    function invariant_debtValueIsFaceFromMaturity() public view {
        for (uint256 i; i < 2; i++) {
            if (vm.getBlockTimestamp() < handler.maturityOf(i)) continue;
            assertEq(
                module.debtValue(handler.facilityData(i)),
                midnight.debt(handler.marketIdOf(i), address(module)),
                "debt value = face from maturity on"
            );
        }
    }

    /// @dev (b) the debt value never decreased while only time passed
    function invariant_debtValueNeverDecreasesOverTime() public view {
        assertEq(handler.timeDecreases(), 0, "debt value is non-decreasing in time");
    }

    /// @dev (d) no partial or full repay and no external face reduction increased the unearned discount
    function invariant_discountNeverIncreasesOnRepayOrReduction() public view {
        assertEq(handler.discountIncreases(), 0, "unearned discount never increases on repay or face reduction");
    }

    /// @dev (e) each borrow raised the debt value by the proceeds within 1 wei per fill, leaving totalAssets unchanged
    ///      within that rounding
    function invariant_borrowAddsProceedsToDebtValue() public view {
        assertEq(handler.borrowDebtMismatches(), 0, "debt value rises by the proceeds within 1 wei per fill");
        assertEq(handler.borrowTotalAssetsMismatches(), 0, "a borrow leaves totalAssets unchanged within 1 wei per fill");
    }

    /// @dev Non-vacuity: every sequence executes actions (reverted calls are not counted)
    function afterInvariant() public view {
        assertGt(handler.successfulActions(), 0, "the sequence executed at least one action");
    }

    // ========== HANDLER COVERAGE ==========

    /// @dev Drives every handler action, including a two-fill borrow, a borrow after an external face reduction and warps
    ///      exactly to and past the maturities, checking the invariants after each step
    function testHandlerExecutesEveryAction() public {
        handler.borrow(0, 1_000_000e6, 0, 0, 1); // one unit into the first bid, the rest into the second
        _checkAllInvariants();
        handler.borrow(1, 2_000_000e6, 1_000, 1_200, type(uint256).max);
        _checkAllInvariants();
        handler.warp(10 days);
        _checkAllInvariants();
        handler.repay(0, 123_456e6 + 1);
        _checkAllInvariants();
        handler.reduceFace(1, 77_777e6);
        _checkAllInvariants();
        handler.borrow(1, 500_000e6, 900, 1_686, 3);
        _checkAllInvariants();
        handler.reduceFace(0, 1);
        _checkAllInvariants();
        handler.repay(1, 1_000e6 + 1);
        _checkAllInvariants();
        for (uint256 k; k < 3; k++) {
            handler.borrow(k, 10_000e6 + k, 100 * k, 1_686, type(uint256).max);
            _checkAllInvariants();
        }
        handler.warpToMaturity(0, 0); // exactly at the first maturity
        _checkAllInvariants();
        handler.repay(0, 0); // type(uint256).max
        _checkAllInvariants();
        handler.warpToMaturity(1, 1); // one second past the second maturity
        _checkAllInvariants();
        handler.repay(1, 0);
        _checkAllInvariants();

        assertEq(handler.borrowOk(), 6, "borrow");
        assertGe(handler.twoFillBorrows(), 1, "a borrow used both bids");
        assertEq(handler.repayOk(), 4, "repay");
        assertEq(handler.fullRepays(), 2, "full repays");
        assertEq(handler.reduceOk(), 2, "face reductions");
        assertEq(handler.warpOk(), 1, "warp");
        assertEq(handler.maturityWarpOk(), 2, "maturity warps");
        assertEq(handler.exactMaturityHits(), 1, "a warp landed exactly on a maturity");
        assertEq(module.debtBalance(handler.facilityData(0), usdc), 0, "facility A closed");
        assertEq(module.debtBalance(handler.facilityData(1), usdc), 0, "facility B closed");
    }

    // ========== HELPERS ==========

    function _checkAllInvariants() internal view {
        invariant_debtValueBetweenProceedsAndFace();
        invariant_debtValueIsFaceFromMaturity();
        invariant_debtValueNeverDecreasesOverTime();
        invariant_discountNeverIncreasesOnRepayOrReduction();
        invariant_borrowAddsProceedsToDebtValue();
    }

    function _market(address loanToken, address collateralToken, address oracle, uint256 maturity) internal view returns (Market memory m) {
        m.chainId = block.chainid;
        m.midnight = address(midnight);
        m.loanToken = loanToken;
        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] = CollateralParams(collateralToken, LLTV, 0.3e18, oracle);
        m.maturity = maturity;
        m.rcfThreshold = 3000e6;
    }
}
