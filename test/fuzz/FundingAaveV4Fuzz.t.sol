// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingAaveV4} from "../../src/FundingAaveV4.sol";
import {IAaveV4Spoke} from "../../src/interfaces/aave-v4/IAaveV4Spoke.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {ORACLE_PRECISION} from "../../src/libraries/Constants.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Deployed code with no function at all (in particular no balanceOf)
contract NoBalanceOfContract {}

/// @dev Stateless fuzzing of FundingAaveV4 on MockAaveV4Spoke: a round trip driven by a real Box, nav against a reference
/// computed in the test, exact guard boundaries from a replica of the mock's account math, facilityData canonicality,
/// access control (including every Box role) and unknown-token views with a live position.
contract FundingAaveV4FuzzTest is Test {
    using BoxLib for IBox;

    bytes internal constant EMPTY = "";
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    /// @dev Amount bounds in whole tokens
    uint256 internal constant MAX_UNITS = 1e12;

    // Fixture Spoke reserves
    uint256 internal constant COLL = 0; // 18 decimals, collateral factor 80%, not borrowable
    uint256 internal constant DEBT = 1; // 6 decimals, the Box asset, borrowable
    uint256 internal constant SPARE = 2; // 8 decimals, configured in the module but never registered

    uint16 internal constant COLL_CF = 8000;
    uint256 internal constant COLL_SPOKE_PRICE = 300_012_345_678; // 3000.12345678 (8 decimals)
    uint256 internal constant DEBT_SPOKE_PRICE = 99_987_654; // 0.99987654
    uint256 internal constant LLTV_CAP = 0.9e18;
    /// @dev ~3000.12 asset units (6 decimals) per collateral token (18 decimals)
    uint256 internal constant COLL_BOX_PRICE = 3_000_123_456_789_012_345_678_901;

    address internal boxOwner = address(0x1);
    address internal allocator = address(0x2);
    address internal curator = address(0x3);
    address internal guardian = address(0x4);
    address internal moduleOwner = address(0x123);

    MockAaveV4Spoke internal spoke;
    ERC20MockDecimals internal collToken;
    ERC20MockDecimals internal debtToken;
    ERC20MockDecimals internal spareToken;
    IBox internal box;
    FundingAaveV4 internal module;

    /// @dev Inputs of MockAaveV4Spoke's account math for one collateral reserve and one debt reserve
    struct SpokeCase {
        uint256 collPrice; // Spoke price, 8 decimals per whole token
        uint256 collUnit; // 10 ** (18 - decimals)
        uint256 debtPrice;
        uint256 debtUnit;
        uint256 cf; // collateral factor, basis points
        uint256 supplyIndex;
        uint256 drawnIndex;
        uint256 minHf; // module guard floor
    }

    struct GuardCase {
        uint256 lltvCap;
        bool fullCap;
        uint256 collPrice;
        uint256 debtPrice;
        uint256 collateralFactor;
        uint256 collateral;
        uint256 decimalsSeed;
        uint256 supplyIndex;
        uint256 drawnIndex;
    }

    struct GuardEnv {
        MockAaveV4Spoke spoke;
        FundingAaveV4 module;
        ERC20MockDecimals coll;
        ERC20MockDecimals debt;
        SpokeCase s;
        uint256 shares; // supplied shares after the pledge
        uint256 supplied;
    }

    struct NavCase {
        uint256 decimalsSeed;
        uint256 mode;
        uint256 coll0;
        uint256 coll1;
        uint256 debtShare0;
        uint256 debtShare1;
        uint256 price0;
        uint256 price1;
        uint256 price2;
        uint256 price3;
        uint256 supplyIndex0;
        uint256 supplyIndex1;
        uint256 drawnIndex0;
        uint256 drawnIndex1;
        uint256 premium0;
        uint256 premium1;
    }

    /// @dev Tokens 0 and 1 are collateral, 2 and 3 are debt; reserve id i on the Spoke is token i
    struct NavEnv {
        IBox box;
        MockAaveV4Spoke spoke;
        FundingAaveV4 module;
        ERC20MockDecimals asset;
        ERC20MockDecimals[4] tokens;
        uint8[4] decimals;
        uint256[4] prices; // Box oracle prices, ORACLE_PRECISION for the Box asset
    }

    function setUp() public {
        spoke = new MockAaveV4Spoke();
        collToken = new ERC20MockDecimals(18);
        debtToken = new ERC20MockDecimals(6);
        spareToken = new ERC20MockDecimals(8);
        assertEq(spoke.addReserve(address(collToken), 18, COLL_CF, false), COLL);
        assertEq(spoke.addReserve(address(debtToken), 6, 0, true), DEBT);
        assertEq(spoke.addReserve(address(spareToken), 8, 7000, true), SPARE);
        spoke.setPrice(COLL, COLL_SPOKE_PRICE);
        spoke.setPrice(DEBT, DEBT_SPOKE_PRICE);
        debtToken.mint(address(spoke), 1e30);
        spareToken.mint(address(spoke), 1e30);

        box = IBox(
            address(new Box(address(debtToken), boxOwner, curator, "Box Fuzz Aave v4", "BFA4", 0.01 ether, 7 days, 10 days, 7 days))
        );
        module = new FundingAaveV4(address(box), address(spoke), _fixtureIds(), LLTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.setIsAllocator(allocator, true);
        box.addTokenInstant(collToken, new MockOracle(COLL_BOX_PRICE));
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, EMPTY);
        box.addFundingCollateralInstant(module, collToken);
        box.addFundingDebtInstant(module, debtToken);
        vm.stopPrank();
    }

    /////////////////////////////
    /// ROUND TRIP THROUGH THE BOX
    /////////////////////////////

    /// @dev Round trip driven by a real Box: pledge(c) -> borrow(b) -> accrual -> repay(max) -> depledge(max) -> removal,
    ///      with b strictly below the guard limit and interest accrued through the mock's drawn index and premium.
    function testFuzz_BoxRoundTrip(
        uint256 collateral,
        uint256 borrowSeed,
        uint256 borrowIndex,
        uint256 accruedIndex,
        uint256 premium
    ) public {
        collateral = bound(collateral, 1e12, MAX_UNITS * 1e18);
        SpokeCase memory s = _fixtureCase(bound(borrowIndex, RAY, 2 * RAY));
        spoke.setDrawnIndex(DEBT, s.drawnIndex);
        uint256 maxBorrow = _maxBorrow(s, collateral);
        assertGt(maxBorrow, 1, "room below the limit");
        uint256 borrowed = bound(borrowSeed, 1, maxBorrow - 1);

        collToken.mint(address(box), collateral);
        uint256 boxCollateralStart = collToken.balanceOf(address(box));
        uint256 boxDebtStart = debtToken.balanceOf(address(box));
        uint256 totalAssetsStart = box.totalAssets();

        vm.prank(allocator);
        box.pledge(module, EMPTY, collToken, collateral);
        _assertModuleIdle();
        assertEq(module.collateralBalance(EMPTY, collToken), collateral, "supplied");
        assertEq(collToken.balanceOf(address(box)), boxCollateralStart - collateral, "Box sent the collateral");

        vm.prank(allocator);
        box.borrow(module, EMPTY, debtToken, borrowed);
        _assertModuleIdle();
        assertEq(debtToken.balanceOf(address(box)), boxDebtStart + borrowed, "Box receives exactly the borrowed amount");
        uint256 debtAfterBorrow = module.debtBalance(EMPTY, debtToken);
        assertEq(debtAfterBorrow, _debtOf(_borrowShares(borrowed, s.drawnIndex), s.drawnIndex), "debt replica");
        assertEq(spoke.getUserAccountData(address(module)).healthFactor, _hf(s, collateral, debtAfterBorrow), "health factor replica");

        spoke.setDrawnIndex(DEBT, bound(accruedIndex, s.drawnIndex, 2 * s.drawnIndex));
        spoke.setPremiumDebt(DEBT, address(module), bound(premium, 0, borrowed));
        uint256 debtBeforeRepay = module.debtBalance(EMPTY, debtToken);
        assertGe(debtBeforeRepay, debtAfterBorrow, "debt never decreases with accrual");
        uint256 interest = debtBeforeRepay - debtAfterBorrow;
        uint256 topUp = debtBeforeRepay - borrowed;
        debtToken.mint(address(box), topUp);

        vm.prank(allocator);
        box.repay(module, EMPTY, debtToken, type(uint256).max);
        _assertModuleIdle();
        assertEq(module.debtBalance(EMPTY, debtToken), 0, "debt closed");
        assertEq(spoke.getUserPosition(DEBT, address(module)).drawnShares, 0, "no drawn shares left");

        vm.prank(allocator);
        box.depledge(module, EMPTY, collToken, type(uint256).max);
        _assertModuleIdle();
        assertEq(module.collateralBalance(EMPTY, collToken), 0, "collateral withdrawn");
        assertEq(spoke.getUserSuppliedShares(COLL, address(module)), 0, "no supplied shares left");
        assertEq(collToken.balanceOf(address(box)), boxCollateralStart, "Box collateral back to start");

        uint256 netCost = boxDebtStart + topUp - debtToken.balanceOf(address(box));
        // The Spoke rounds drawn shares up and their debt up: at most 2 wei above the amount for a drawn index <= 2
        assertEq(netCost, interest + (debtAfterBorrow - borrowed), "cost = accrued interest + borrow rounding");
        assertLe(netCost, interest + 4, "cost within the accrued interest plus 1 wei per Box action");
        assertEq(box.totalAssets(), totalAssetsStart + topUp - netCost, "totalAssets only lost the cost");

        vm.startPrank(curator);
        box.removeFundingFacility(module, EMPTY);
        box.removeFundingCollateral(module, collToken);
        box.removeFundingDebt(module, debtToken);
        box.removeFunding(module);
        vm.stopPrank();
        assertEq(module.facilitiesLength(), 0, "facility removed");
        assertFalse(box.isFunding(module), "module removed");
    }

    /////////////////////////////
    /// NAV
    /////////////////////////////

    /// @dev nav with a real Box as oracle provider equals an account-level reference computed here, for 6/8/18 decimals
    ///      (asset, collateral and debt), non-round Box oracle prices, and the Box asset outside the position, as a
    ///      collateral or as a debt.
    function testFuzz_NavMatchesReference(NavCase memory n) public {
        NavEnv memory e = _deployNavCase(n);
        _openNavPositions(e, n);

        // Reference, account level, the Box asset valued 1:1 (p = 1e36):
        //   nav = max(0, Σ_collateral floor(balance × p / 1e36) − Σ_debt ceil(balance × p / 1e36))
        // Exact equity without intermediate rounding (the products fit in 256 bits under the fuzz bounds):
        //   exact = floor(max(0, Σ_collateral balance × p − Σ_debt balance × p) / 1e36)
        uint256 collateralValue;
        uint256 debtValue;
        uint256 collateralExact;
        uint256 debtExact;
        for (uint256 i; i < 2; i++) {
            uint256 balance = e.spoke.getUserSuppliedAssets(i, address(e.module));
            assertEq(e.module.collateralBalance(e.tokens[i]), balance, "collateral view matches the Spoke");
            collateralValue += Math.mulDiv(balance, e.prices[i], ORACLE_PRECISION);
            collateralExact += balance * e.prices[i];
        }
        for (uint256 i = 2; i < 4; i++) {
            uint256 balance = e.spoke.getUserTotalDebt(i, address(e.module));
            assertEq(e.module.debtBalance(e.tokens[i]), balance, "debt view matches the Spoke");
            debtValue += Math.mulDiv(balance, e.prices[i], ORACLE_PRECISION, Math.Rounding.Ceil);
            debtExact += balance * e.prices[i];
        }
        uint256 expected = collateralValue > debtValue ? collateralValue - debtValue : 0;
        uint256 exact = collateralExact > debtExact ? (collateralExact - debtExact) / ORACLE_PRECISION : 0;

        try e.module.nav(IOracleCallback(address(e.box))) returns (uint256 nav) {
            assertEq(nav, expected, "nav equals the reference");
            assertLe(nav, exact, "nav never above the exact equity");
            // Two collateral floors and two debt ceilings each lose less than 1 wei
            assertLe(exact - nav, 3, "nav at most 3 wei below the exact equity");
        } catch {
            assertTrue(false, "nav reverted");
        }
    }

    /////////////////////////////
    /// GUARD BOUNDARIES
    /////////////////////////////

    /// @dev The largest borrow allowed by the guard (computed with a replica of the mock's account math) succeeds and
    ///      one more unit reverts with the predicted error: ExcessiveLTV, or the Spoke's own HealthFactorBelowThreshold
    ///      when the Spoke limit binds first (always the case at lltvCap = 1e18).
    function testFuzz_BorrowGuardBoundaryIsExact(GuardCase memory g) public {
        GuardEnv memory e = _deployGuardCase(g);
        uint256 idx = e.s.drawnIndex;
        uint256 maxBorrow = _maxBorrow(e.s, e.supplied);
        assertGt(maxBorrow, 0, "collateral lower bound allows one debt unit");
        e.debt.mint(address(e.spoke), maxBorrow + 1);

        // One unit above the boundary, from the same state
        bytes4 expected = _predictGuardRevert(e.s, _hf(e.s, e.supplied, _debtOf(_borrowShares(maxBorrow + 1, idx), idx)));
        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        e.module.borrow(EMPTY, e.debt, maxBorrow + 1);
        assertEq(e.spoke.getUserTotalDebt(1, address(e.module)), 0, "no debt after the revert");

        vm.prank(moduleOwner);
        e.module.borrow(EMPTY, e.debt, maxBorrow);
        uint256 shares = _borrowShares(maxBorrow, idx);
        uint256 debtAssets = _debtOf(shares, idx);
        assertEq(e.spoke.getUserTotalDebt(1, address(e.module)), debtAssets, "debt replica");
        uint256 hf = e.spoke.getUserAccountData(address(e.module)).healthFactor;
        assertEq(hf, _hf(e.s, e.supplied, debtAssets), "health factor replica");
        assertGe(hf, e.s.minHf, "boundary inside the guard");
        assertEq(e.debt.balanceOf(moduleOwner), maxBorrow, "owner receives the amount");
        assertEq(e.debt.balanceOf(address(e.module)), 0, "module holds nothing");

        // One more unit on top of the boundary position
        expected = _predictGuardRevert(e.s, _hf(e.s, e.supplied, _debtOf(shares + _borrowShares(1, idx), idx)));
        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        e.module.borrow(EMPTY, e.debt, 1);
    }

    /// @dev The largest withdrawal allowed by the guard succeeds and one more unit reverts with the predicted error. With
    ///      debt open that is ExcessiveLTV or the Spoke's HealthFactorBelowThreshold. Without debt (a quarter of the runs)
    ///      the whole supply is allowed and one more unit reverts InvalidAmount.
    function testFuzz_DepledgeGuardBoundaryIsExact(GuardCase memory g, uint256 borrowSeed) public {
        GuardEnv memory e = _deployGuardCase(g);
        uint256 idx = e.s.drawnIndex;
        uint256 borrowAmount = borrowSeed % 4 == 0 ? 0 : bound(borrowSeed, 1, _maxBorrow(e.s, e.supplied));
        uint256 debtAssets;
        if (borrowAmount > 0) {
            e.debt.mint(address(e.spoke), borrowAmount);
            vm.prank(moduleOwner);
            e.module.borrow(EMPTY, e.debt, borrowAmount);
            debtAssets = _debtOf(_borrowShares(borrowAmount, idx), idx);
        }
        assertEq(e.spoke.getUserTotalDebt(1, address(e.module)), debtAssets, "debt replica");

        uint256 maxWithdraw;
        bytes4 expected;
        if (debtAssets == 0) {
            maxWithdraw = e.supplied;
            // The Spoke silently caps the withdrawal at the supply, then the module reverts on the shortfall
            expected = ErrorsLib.InvalidAmount.selector;
        } else {
            maxWithdraw = _maxWithdraw(e.s, e.shares, debtAssets);
            expected = _predictGuardRevert(e.s, _hf(e.s, _suppliedAfterWithdraw(e.s, e.shares, maxWithdraw + 1), debtAssets));
        }

        // One unit above the boundary, from the same state
        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        e.module.depledge(EMPTY, e.coll, maxWithdraw + 1);
        assertEq(e.spoke.getUserSuppliedShares(0, address(e.module)), e.shares, "no shares burned after the revert");
        if (maxWithdraw == 0) return;

        vm.prank(moduleOwner);
        e.module.depledge(EMPTY, e.coll, maxWithdraw);
        uint256 sharesLeft = e.shares - _withdrawnShares(e.s, e.shares, maxWithdraw);
        assertEq(e.spoke.getUserSuppliedShares(0, address(e.module)), sharesLeft, "shares replica");
        uint256 hf = e.spoke.getUserAccountData(address(e.module)).healthFactor;
        assertEq(hf, _hf(e.s, _suppliedOf(sharesLeft, e.s.supplyIndex), debtAssets), "health factor replica");
        assertGe(hf, e.s.minHf, "boundary inside the guard");
        assertEq(e.coll.balanceOf(moduleOwner), maxWithdraw, "owner receives the amount");
        assertEq(e.coll.balanceOf(address(e.module)), 0, "module holds nothing");

        // One more unit on top of the boundary position
        if (debtAssets == 0) {
            assertEq(sharesLeft, 0, "whole supply withdrawn");
            // Nothing left to withdraw: the Spoke itself rejects it (its InvalidAmount() shares ErrorsLib's selector)
            expected = MockAaveV4Spoke.InvalidAmount.selector;
        } else {
            expected = _predictGuardRevert(e.s, _hf(e.s, _suppliedAfterWithdraw(e.s, sharesLeft, 1), debtAssets));
        }
        vm.prank(moduleOwner);
        vm.expectRevert(expected);
        e.module.depledge(EMPTY, e.coll, 1);
    }

    /////////////////////////////
    /// FACILITY DATA
    /////////////////////////////

    /// @dev Any non-empty facilityData is rejected by addFacility, on a fresh module, on the Box-owned module that already
    ///      has "" and through the Box's timelocked addFundingFacility.
    function testFuzz_AddFacilityRejectsNonEmptyBytes(bytes memory facilityData) public {
        vm.assume(facilityData.length > 0);
        FundingAaveV4 fresh = new FundingAaveV4(address(box), address(spoke), _fixtureIds(), LLTV_CAP);

        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        fresh.addFacility(facilityData);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.addFacility(facilityData);
        vm.stopPrank();

        vm.startPrank(curator);
        box.submit(abi.encodeWithSelector(IBox.addFundingFacility.selector, address(module), facilityData));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFundingFacility(module, facilityData);
        vm.stopPrank();

        assertEq(fresh.facilitiesLength(), 0, "nothing registered on the fresh module");
        assertFalse(fresh.isFacility(facilityData), "fresh: not a facility");
        assertEq(module.facilitiesLength(), 1, "only the empty facility");
        assertFalse(module.isFacility(facilityData), "not a facility");

        vm.prank(address(box));
        fresh.addFacility(EMPTY);
        assertTrue(fresh.isFacility(EMPTY), "the empty facility is accepted");
        assertFalse(fresh.isFacility(facilityData), "still not a facility");
    }

    /// @dev With "" registered and a live position, a non-empty facilityData is not a facility and every action with it
    ///      reverts NotWhitelisted, called directly by the owner or through the Box.
    function testFuzz_NonEmptyFacilityDataIsNeverWhitelisted(
        bytes memory facilityData,
        uint256 amount,
        uint256 collateralSeed,
        uint256 borrowSeed
    ) public {
        vm.assume(facilityData.length > 0);
        (uint256 collateral, uint256 borrowed) = _openLivePosition(collateralSeed, borrowSeed);
        assertTrue(module.isFacility(EMPTY), "empty facility registered");
        assertFalse(module.isFacility(facilityData), "not a facility");
        uint256 actions = spoke.actionCount();

        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.pledge(facilityData, collToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.depledge(facilityData, collToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.borrow(facilityData, debtToken, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.repay(facilityData, debtToken, amount);
        vm.stopPrank();

        // Through the Box, depledge(max) and repay(max) resolve to 0 from the per-facility views before the module rejects
        uint256 boxAmount = bound(amount, 1, MAX_UNITS * 1e18);
        collToken.mint(address(box), boxAmount);
        vm.startPrank(allocator);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.pledge(module, facilityData, collToken, boxAmount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.depledge(module, facilityData, collToken, type(uint256).max);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.borrow(module, facilityData, debtToken, boxAmount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.repay(module, facilityData, debtToken, type(uint256).max);
        vm.stopPrank();

        assertEq(spoke.actionCount(), actions, "no Spoke action");
        assertEq(module.collateralBalance(EMPTY, collToken), collateral, "collateral unchanged");
        assertEq(module.debtBalance(EMPTY, debtToken), borrowed, "debt unchanged");
        _assertModuleIdle();
    }

    /////////////////////////////
    /// ACCESS CONTROL
    /////////////////////////////

    /// @dev Any caller other than the owner gets OnlyOwner on the 11 owner-gated functions, directly and wrapped in multicall.
    function testFuzz_NonOwnerCannotCallGatedFunctions(address caller, uint256 amount) public {
        vm.assume(caller != address(box));
        assumeNotForgeAddress(caller);
        _openLivePosition(100e18, 50_000e6);
        collToken.mint(address(module), 1e18); // something to skim
        uint256 actions = spoke.actionCount();
        uint256 navBefore = module.nav(IOracleCallback(address(box)));

        _assertGatedCallsRevertOnlyOwner(caller, amount);

        bytes memory onlyOwner = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        bytes[] memory calls = _ownerGatedCalls(amount);
        for (uint256 i; i < calls.length; i++) {
            bytes[] memory inner = new bytes[](1);
            inner[0] = calls[i];
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(module).call(abi.encodeCall(module.multicall, (inner)));
            assertFalse(ok, "multicall must revert");
            assertEq(ret, onlyOwner, "multicall bubbles OnlyOwner");
        }
        vm.prank(caller);
        (bool success, bytes memory data) = address(module).call(abi.encodeCall(module.multicall, (calls)));
        assertFalse(success, "batched multicall must revert");
        assertEq(data, onlyOwner, "batched multicall bubbles OnlyOwner");

        assertEq(spoke.actionCount(), actions, "no Spoke action");
        assertEq(module.nav(IOracleCallback(address(box))), navBefore, "nav unchanged");
        assertEq(collToken.balanceOf(address(module)), 1e18, "nothing skimmed");
        assertEq(module.facilitiesLength(), 1, "facilities unchanged");
        assertEq(module.collateralTokensLength(), 1, "collateral tokens unchanged");
        assertEq(module.debtTokensLength(), 1, "debt tokens unchanged");

        // The same multicall from the owner goes through
        bytes[] memory ownerCall = new bytes[](1);
        ownerCall[0] = abi.encodeCall(module.addDebtToken, (IERC20(address(spareToken))));
        vm.prank(address(box));
        module.multicall(ownerCall);
        assertTrue(module.isDebtToken(spareToken), "owner multicall works");
    }

    /// @dev A registered allocator, the curator, the guardian and the Box owner of the Box owning the module, and fuzzed
    ///      addresses promoted to each of these roles, all get OnlyOwner when calling the module directly.
    function testFuzz_BoxRolesCannotCallModuleDirectly(
        address newAllocator,
        address newGuardian,
        address newCurator,
        uint256 amount
    ) public {
        vm.assume(newAllocator != address(0) && newAllocator != address(box) && newAllocator != allocator);
        vm.assume(newGuardian != address(0) && newGuardian != address(box) && newGuardian != guardian);
        vm.assume(newCurator != address(0) && newCurator != address(box) && newCurator != curator);
        assumeNotForgeAddress(newAllocator);
        assumeNotForgeAddress(newGuardian);
        assumeNotForgeAddress(newCurator);

        assertEq(module.owner(), address(box), "the Box owns the module");
        assertTrue(box.isFunding(module), "module attached to the Box");
        assertTrue(box.isAllocator(allocator), "allocator registered");
        assertEq(box.curator(), curator, "curator");
        assertEq(box.guardian(), guardian, "guardian");
        assertEq(box.owner(), boxOwner, "Box owner");

        _openLivePosition(100e18, 50_000e6);
        collToken.mint(address(module), 1e18);
        uint256 actions = spoke.actionCount();

        _assertGatedCallsRevertOnlyOwner(allocator, amount);
        _assertGatedCallsRevertOnlyOwner(curator, amount);
        _assertGatedCallsRevertOnlyOwner(guardian, amount);
        _assertGatedCallsRevertOnlyOwner(boxOwner, amount);

        vm.startPrank(curator);
        box.setIsAllocator(newAllocator, true);
        box.setGuardianInstant(newGuardian);
        vm.stopPrank();
        vm.prank(boxOwner);
        box.setCurator(newCurator);
        assertTrue(box.isAllocator(newAllocator), "new allocator registered");
        assertEq(box.guardian(), newGuardian, "new guardian");
        assertEq(box.curator(), newCurator, "new curator");

        _assertGatedCallsRevertOnlyOwner(newAllocator, amount);
        _assertGatedCallsRevertOnlyOwner(newGuardian, amount);
        _assertGatedCallsRevertOnlyOwner(newCurator, amount);

        assertEq(spoke.actionCount(), actions, "no Spoke action");
        assertEq(collToken.balanceOf(address(module)), 1e18, "nothing skimmed");
    }

    /////////////////////////////
    /// UNKNOWN TOKENS
    /////////////////////////////

    /// @dev With a live position, the four balance views return 0 (no revert) for any token that is not registered in that
    ///      role, including address(0), an EOA, a contract without balanceOf, an ERC20 the Spoke does not list and a token
    ///      configured in the module but never registered (carrying real debt); per-facility views return 0 for non-empty
    ///      facilityData.
    function testFuzz_UnknownTokenViewsReturnZero(
        address token,
        bytes memory facilityData,
        uint256 collateralSeed,
        uint256 borrowSeed
    ) public {
        vm.assume(token != address(collToken) && token != address(debtToken));
        assumeNotForgeAddress(token);
        vm.assume(facilityData.length > 0);
        (uint256 collateral, uint256 borrowed) = _openLivePosition(collateralSeed, borrowSeed);
        spoke.setPremiumDebt(SPARE, address(module), 1e8 + 1);
        assertEq(module.collateralBalance(EMPTY, collToken), collateral, "live collateral");
        assertEq(module.debtBalance(EMPTY, debtToken), borrowed, "live debt");
        assertGt(module.ltv(EMPTY), 0, "live ltv");

        address[8] memory unknown = [
            token,
            address(0),
            makeAddr("eoa"),
            address(new NoBalanceOfContract()),
            address(new ERC20MockDecimals(18)),
            address(spareToken),
            address(spoke),
            address(box)
        ];
        for (uint256 i; i < unknown.length; i++) {
            _assertZeroViews(IERC20(unknown[i]), facilityData);
        }

        // Registered tokens queried in the other role
        assertEq(module.debtBalance(collToken), 0, "collateral token as debt");
        assertEq(module.debtBalance(EMPTY, collToken), 0, "collateral token as debt, empty facility");
        assertEq(module.collateralBalance(debtToken), 0, "debt token as collateral");
        assertEq(module.collateralBalance(EMPTY, debtToken), 0, "debt token as collateral, empty facility");

        // Registered tokens under a non-empty facilityData
        assertEq(module.collateralBalance(facilityData, collToken), 0, "collateral, non-empty facility");
        assertEq(module.debtBalance(facilityData, debtToken), 0, "debt, non-empty facility");
        assertEq(module.ltv(facilityData), 0, "ltv, non-empty facility");
    }

    /////////////////////////////
    /// HELPERS
    /////////////////////////////

    function _fixtureIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = COLL;
        ids[1] = DEBT;
        ids[2] = SPARE;
    }

    function _fixtureCase(uint256 drawnIndex) internal view returns (SpokeCase memory) {
        return
            SpokeCase({
                collPrice: COLL_SPOKE_PRICE,
                collUnit: 1,
                debtPrice: DEBT_SPOKE_PRICE,
                debtUnit: 1e12,
                cf: COLL_CF,
                supplyIndex: RAY,
                drawnIndex: drawnIndex,
                minHf: module.minHealthFactor()
            });
    }

    /// @dev Pledges and borrows through the Box on the fixture module (drawn index 1, so the debt equals the amount)
    function _openLivePosition(uint256 collateralSeed, uint256 borrowSeed) internal returns (uint256 collateral, uint256 borrowed) {
        collateral = bound(collateralSeed, 1e15, MAX_UNITS * 1e18);
        borrowed = bound(borrowSeed, 1, _maxBorrow(_fixtureCase(RAY), collateral));
        collToken.mint(address(box), collateral);
        vm.startPrank(allocator);
        box.pledge(module, EMPTY, collToken, collateral);
        box.borrow(module, EMPTY, debtToken, borrowed);
        vm.stopPrank();
    }

    function _assertModuleIdle() internal view {
        assertEq(collToken.balanceOf(address(module)), 0, "module holds no collateral token");
        assertEq(debtToken.balanceOf(address(module)), 0, "module holds no debt token");
    }

    function _assertZeroViews(IERC20 token, bytes memory facilityData) internal view {
        assertEq(module.debtBalance(token), 0, "debtBalance(token)");
        assertEq(module.collateralBalance(token), 0, "collateralBalance(token)");
        assertEq(module.debtBalance(EMPTY, token), 0, "debtBalance(empty, token)");
        assertEq(module.collateralBalance(EMPTY, token), 0, "collateralBalance(empty, token)");
        assertEq(module.debtBalance(facilityData, token), 0, "debtBalance(facilityData, token)");
        assertEq(module.collateralBalance(facilityData, token), 0, "collateralBalance(facilityData, token)");
    }

    function _ownerGatedCalls(uint256 amount) internal view returns (bytes[] memory calls) {
        IERC20 coll = IERC20(address(collToken));
        IERC20 debt = IERC20(address(debtToken));
        IERC20 spare = IERC20(address(spareToken));
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(module.addFacility, (EMPTY));
        calls[1] = abi.encodeCall(module.removeFacility, (EMPTY));
        calls[2] = abi.encodeCall(module.addCollateralToken, (spare));
        calls[3] = abi.encodeCall(module.addDebtToken, (spare));
        calls[4] = abi.encodeCall(module.removeCollateralToken, (coll));
        calls[5] = abi.encodeCall(module.removeDebtToken, (debt));
        calls[6] = abi.encodeCall(module.skim, (coll));
        calls[7] = abi.encodeCall(module.pledge, (EMPTY, coll, amount));
        calls[8] = abi.encodeCall(module.depledge, (EMPTY, coll, amount));
        calls[9] = abi.encodeCall(module.borrow, (EMPTY, debt, amount));
        calls[10] = abi.encodeCall(module.repay, (EMPTY, debt, amount));
    }

    function _assertGatedCallsRevertOnlyOwner(address caller, uint256 amount) internal {
        bytes memory onlyOwner = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        bytes[] memory calls = _ownerGatedCalls(amount);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(module).call(calls[i]);
            assertFalse(ok, "gated call must revert");
            assertEq(ret, onlyOwner, "gated call reverts OnlyOwner");
        }
    }

    /// @dev Picks 6, 8 or 18 decimals
    function _pickDecimals(uint256 seed) internal pure returns (uint8) {
        uint256 choice = seed % 3;
        if (choice == 0) return 6;
        if (choice == 1) return 8;
        return 18;
    }

    // ---------- guard cases ----------

    /// @dev Fresh Spoke with one collateral and one debt reserve, a module with a fuzzed lltvCap owned by `moduleOwner`,
    ///      and a pledge large enough for at least one debt unit to pass the guard.
    function _deployGuardCase(GuardCase memory g) internal returns (GuardEnv memory e) {
        uint8 collDecimals = _pickDecimals(g.decimalsSeed);
        uint8 debtDecimals = _pickDecimals(g.decimalsSeed / 3);
        uint256 lltvCap = g.fullCap ? WAD : bound(g.lltvCap, 1, WAD);
        e.s = SpokeCase({
            collPrice: bound(g.collPrice, 1, 1e14),
            collUnit: 10 ** (18 - collDecimals),
            debtPrice: bound(g.debtPrice, 1, 1e14),
            debtUnit: 10 ** (18 - debtDecimals),
            cf: bound(g.collateralFactor, 1, 10_000),
            supplyIndex: bound(g.supplyIndex, RAY, 2 * RAY),
            drawnIndex: bound(g.drawnIndex, RAY, 2 * RAY),
            minHf: Math.ceilDiv(WAD * WAD, lltvCap)
        });

        e.spoke = new MockAaveV4Spoke();
        e.coll = new ERC20MockDecimals(collDecimals);
        e.debt = new ERC20MockDecimals(debtDecimals);
        e.spoke.addReserve(address(e.coll), collDecimals, uint16(e.s.cf), false);
        e.spoke.addReserve(address(e.debt), debtDecimals, 0, true);
        e.spoke.setPrice(0, e.s.collPrice);
        e.spoke.setPrice(1, e.s.debtPrice);
        e.spoke.setSupplyIndex(0, e.s.supplyIndex);
        e.spoke.setDrawnIndex(1, e.s.drawnIndex);

        uint256[] memory ids = new uint256[](2);
        ids[1] = 1;
        e.module = new FundingAaveV4(moduleOwner, address(e.spoke), ids, lltvCap);
        assertEq(e.module.minHealthFactor(), e.s.minHf, "guard floor");

        // One debt unit is at most 2 wei of debt (drawn index <= 2); it passes the guard once
        // cf * 1e14 * collateralValue > minHf * 2 * debtPrice * debtUnit. The supply round trip loses at most 2 wei.
        uint256 minValue = Math.mulDiv(e.s.minHf, 2 * e.s.debtPrice * e.s.debtUnit, e.s.cf * 1e14) + 1;
        uint256 minCollateral = Math.ceilDiv(minValue, e.s.collPrice * e.s.collUnit) + 2;
        uint256 collateral = bound(g.collateral, minCollateral, Math.max(minCollateral, MAX_UNITS * 10 ** collDecimals));

        vm.startPrank(moduleOwner);
        e.module.addFacility(EMPTY);
        e.module.addCollateralToken(e.coll);
        e.module.addDebtToken(e.debt);
        e.coll.mint(address(e.module), collateral);
        e.module.pledge(EMPTY, e.coll, collateral);
        vm.stopPrank();

        e.shares = e.spoke.getUserSuppliedShares(0, address(e.module));
        assertEq(e.shares, Math.mulDiv(collateral, RAY, e.s.supplyIndex), "supply shares replica");
        e.supplied = _suppliedOf(e.shares, e.s.supplyIndex);
        assertEq(e.spoke.getUserSuppliedAssets(0, address(e.module)), e.supplied, "supplied replica");
        IAaveV4Spoke.UserAccountData memory data = e.spoke.getUserAccountData(address(e.module));
        assertEq(data.totalCollateralValue, e.supplied * e.s.collPrice * e.s.collUnit, "collateral value replica");
        assertEq(data.avgCollateralFactor, e.s.cf * 1e14, "collateral factor replica");
    }

    /// @dev Error expected from a borrow or depledge leaving health factor `hf`, which must be outside the guard. The Spoke
    ///      checks its own limit (hf >= 1e18) before the module applies its guard.
    function _predictGuardRevert(SpokeCase memory s, uint256 hf) internal pure returns (bytes4 expected) {
        assertLt(hf, s.minHf, "outside the guard");
        expected = hf < WAD ? MockAaveV4Spoke.HealthFactorBelowThreshold.selector : ErrorsLib.ExcessiveLTV.selector;
        if (s.minHf == WAD) {
            assertEq(expected, MockAaveV4Spoke.HealthFactorBelowThreshold.selector, "full cap: the Spoke limit binds");
        }
    }

    // ---------- replica of the MockAaveV4Spoke math ----------

    /// @dev Drawn shares minted by borrow: rounded up
    function _borrowShares(uint256 amount, uint256 drawnIndex) internal pure returns (uint256) {
        return Math.mulDiv(amount, RAY, drawnIndex, Math.Rounding.Ceil);
    }

    /// @dev Debt of drawn shares: rounded up
    function _debtOf(uint256 shares, uint256 drawnIndex) internal pure returns (uint256) {
        return Math.mulDiv(shares, drawnIndex, RAY, Math.Rounding.Ceil);
    }

    /// @dev Supplied assets of supplied shares: rounded down
    function _suppliedOf(uint256 shares, uint256 supplyIndex) internal pure returns (uint256) {
        return Math.mulDiv(shares, supplyIndex, RAY);
    }

    /// @dev Shares burned by withdraw(amount), 0 <= amount <= supplied: all of them for the full balance, otherwise the
    ///      amount rounded up to shares
    function _withdrawnShares(SpokeCase memory s, uint256 shares, uint256 amount) internal pure returns (uint256) {
        if (amount >= _suppliedOf(shares, s.supplyIndex)) return shares;
        return Math.min(Math.mulDiv(amount, RAY, s.supplyIndex, Math.Rounding.Ceil), shares);
    }

    function _suppliedAfterWithdraw(SpokeCase memory s, uint256 shares, uint256 amount) internal pure returns (uint256) {
        return _suppliedOf(shares - _withdrawnShares(s, shares, amount), s.supplyIndex);
    }

    /// @dev getUserAccountData health factor. With a single collateral reserve,
    ///      avgCollateralFactor = value * cf * 1e14 / value = cf * 1e14 exactly (0 without collateral value).
    function _hf(SpokeCase memory s, uint256 supplied, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = supplied * s.collPrice * s.collUnit;
        uint256 avgCollateralFactor = collateralValue == 0 ? 0 : s.cf * 1e14;
        return Math.mulDiv(avgCollateralFactor * collateralValue, RAY, debt * s.debtPrice * s.debtUnit * RAY);
    }

    /// @dev Largest amount borrowable from a debt-free position with `supplied` collateral that keeps hf >= minHf
    function _maxBorrow(SpokeCase memory s, uint256 supplied) internal pure returns (uint256 lo) {
        // Once the debt value exceeds the collateral value, hf < avgCollateralFactor <= 1e18 <= minHf
        uint256 hi = (supplied * s.collPrice * s.collUnit) / (s.debtPrice * s.debtUnit) + 1;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_hf(s, supplied, _debtOf(_borrowShares(mid, s.drawnIndex), s.drawnIndex)) >= s.minHf) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }

    /// @dev Largest withdrawal from `shares` supplied shares with `debt` open that keeps hf >= minHf (the current position
    ///      must satisfy it)
    function _maxWithdraw(SpokeCase memory s, uint256 shares, uint256 debt) internal pure returns (uint256 lo) {
        // Withdrawing everything leaves no collateral value: hf = 0
        uint256 hi = _suppliedOf(shares, s.supplyIndex);
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_hf(s, _suppliedAfterWithdraw(s, shares, mid), debt) >= s.minHf) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
    }

    // ---------- nav cases ----------

    /// @dev Fresh Spoke, Box and module (lltvCap 1e18) with two collateral and two debt reserves. Mode 0: the Box asset is
    ///      outside the position; mode 1: the first collateral is the Box asset; mode 2: the first debt is the Box asset.
    function _deployNavCase(NavCase memory n) internal returns (NavEnv memory e) {
        uint256 mode = n.mode % 3;
        uint8 assetDecimals = _pickDecimals(n.decimalsSeed);
        e.asset = new ERC20MockDecimals(assetDecimals);
        e.spoke = new MockAaveV4Spoke();
        e.box = IBox(address(new Box(address(e.asset), boxOwner, curator, "Box Nav", "BNAV", 0.01 ether, 7 days, 10 days, 7 days)));

        uint256[] memory ids = new uint256[](4);
        uint256[4] memory priceSeeds = [n.price0, n.price1, n.price2, n.price3];
        bool[4] memory isAsset = [mode == 1, false, mode == 2, false];
        for (uint256 i; i < 4; i++) {
            e.decimals[i] = isAsset[i] ? assetDecimals : _pickDecimals(n.decimalsSeed / (3 ** (i + 1)));
            e.tokens[i] = isAsset[i] ? e.asset : new ERC20MockDecimals(e.decimals[i]);
            ids[i] = e.spoke.addReserve(address(e.tokens[i]), e.decimals[i], i < 2 ? uint16(9000) : uint16(0), i >= 2);
            e.prices[i] = isAsset[i] ? ORACLE_PRECISION : _boxPrice(priceSeeds[i], assetDecimals, e.decimals[i]);
        }
        e.module = new FundingAaveV4(address(e.box), address(e.spoke), ids, WAD);

        vm.startPrank(curator);
        for (uint256 i; i < 4; i++) {
            if (!isAsset[i]) e.box.addTokenInstant(e.tokens[i], new MockOracle(e.prices[i]));
        }
        vm.stopPrank();

        vm.startPrank(address(e.box));
        e.module.addFacility(EMPTY);
        e.module.addCollateralToken(e.tokens[0]);
        e.module.addCollateralToken(e.tokens[1]);
        e.module.addDebtToken(e.tokens[2]);
        e.module.addDebtToken(e.tokens[3]);
        vm.stopPrank();
    }

    /// @dev Box oracle price (1e36 scale) of a token in asset units, up to 1e6 asset per whole token, forced odd so it is
    ///      never a round number
    function _boxPrice(uint256 seed, uint8 assetDecimals, uint8 tokenDecimals) internal pure returns (uint256) {
        return bound(seed, 1, (1e6 * ORACLE_PRECISION * 10 ** assetDecimals) / 10 ** tokenDecimals) | 1;
    }

    /// @dev Pledges both collaterals, borrows both debts (at most 85% of the collateral at the Spoke, which prices every
    ///      token at 1 with a 90% collateral factor), then accrues supply yield, debt interest and premium on the Spoke.
    function _openNavPositions(NavEnv memory e, NavCase memory n) internal {
        uint256[2] memory collateralSeeds = [n.coll0, n.coll1];
        uint256[2] memory debtShares = [n.debtShare0, n.debtShare1];
        uint256 collateralValue18;

        vm.startPrank(address(e.box));
        for (uint256 i; i < 2; i++) {
            uint256 amount = bound(collateralSeeds[i], 1, MAX_UNITS * 10 ** e.decimals[i]);
            e.tokens[i].mint(address(e.module), amount);
            e.module.pledge(EMPTY, e.tokens[i], amount);
            collateralValue18 += amount * 10 ** (18 - e.decimals[i]);
        }
        for (uint256 j; j < 2; j++) {
            uint256 amount = (collateralValue18 * bound(debtShares[j], 0, 0.425e18)) / WAD / 10 ** (18 - e.decimals[2 + j]);
            if (amount == 0) continue;
            e.tokens[2 + j].mint(address(e.spoke), amount);
            e.module.borrow(EMPTY, e.tokens[2 + j], amount);
        }
        vm.stopPrank();

        e.spoke.setSupplyIndex(0, bound(n.supplyIndex0, RAY, 3 * RAY));
        e.spoke.setSupplyIndex(1, bound(n.supplyIndex1, RAY, 3 * RAY));
        e.spoke.setDrawnIndex(2, bound(n.drawnIndex0, RAY, 3 * RAY));
        e.spoke.setDrawnIndex(3, bound(n.drawnIndex1, RAY, 3 * RAY));
        e.spoke.setPremiumDebt(2, address(e.module), bound(n.premium0, 0, MAX_UNITS * 10 ** e.decimals[2]));
        e.spoke.setPremiumDebt(3, address(e.module), bound(n.premium1, 0, MAX_UNITS * 10 ** e.decimals[3]));
    }
}
