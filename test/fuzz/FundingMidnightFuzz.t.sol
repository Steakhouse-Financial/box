// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingBase} from "../../src/FundingBase.sol";
import {FundingMidnight, OfferFill} from "../../src/FundingMidnight.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {CollateralParams, Market, Offer} from "../../src/interfaces/midnight/IMidnight.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {IdLib} from "../../src/libraries/midnight/IdLib.sol";
import {TickLib} from "../../src/libraries/midnight/TickLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockMidnight} from "../mocks/MockMidnight.sol";
import {MockMidnightRatifier} from "../mocks/MockMidnightRatifier.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev The struct-wrapped encoding of a facility, which FundingMidnight must reject
struct WrappedMidnightFacility {
    Market market;
    uint256 collateralIndex;
    uint256 maxBorrowApr;
}

/// @dev Stateless fuzzing of FundingMidnight on a mock Midnight, driven through a real Box: full Box round trip, nav
/// against an independent reference, exact guard boundaries, canonical facilityData, access control and unknown tokens.
contract FundingMidnightFuzzTest is Test {
    using BoxLib for IBox;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant RATE_SCALE = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant TICK_SPACING = 4; // MockMidnight's tick spacing
    uint256 internal constant MAX_STEP = 1686; // TickLib.MAX_TICK / TICK_SPACING

    uint256 internal constant T0 = 1790212611;
    uint256 internal constant MATURITY = 1798210800; // about 92.6 days after T0
    uint256 internal constant MATURITY2 = 1793372400;
    uint256 internal constant CBBTC_PRICE = 842515000000000000000000000000000000000; // 84,251.5 USDC per cbBTC
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LLTV_CAP = 0.9e18;
    uint256 internal constant MAX_APR = 0.2e18;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal lender = makeAddr("lender");

    MockMidnight internal midnight;
    MockMidnightRatifier internal ratifier;
    ERC20MockDecimals internal usdc; // Box asset and loan token of the default facility
    ERC20MockDecimals internal cbBtc;
    ERC20MockDecimals internal weth;
    MockOracle internal midnightOracle; // Midnight market oracle of the default facility
    MockOracle internal boxCbBtcOracle;
    IBox internal box;
    FundingMidnight internal module;

    bytes internal fd; // default facility, registered
    bytes internal fd2; // valid facility of another maturity, never registered
    bytes32 internal id;

    struct NavSeeds {
        uint256 decimals;
        uint256 collateral0;
        uint256 amount0;
        uint256 tick0;
        uint256 collPrice0;
        uint256 collateral1;
        uint256 amount1;
        uint256 tick1;
        uint256 collPrice1;
        uint256 loanPrice1;
        uint256 wait0;
        uint256 wait1;
        uint256 waitCheck;
    }

    struct NavFacility {
        bytes fd;
        ERC20MockDecimals loan;
        ERC20MockDecimals coll;
        MockOracle midnightOracle;
        uint256 collPrice; // Box oracle price of the collateral
        uint256 loanPrice; // Box oracle price of the loan token; 1e36 for the Box asset, which is valued 1:1
        uint256 maturity;
        uint256 collateral;
        uint256 units;
        uint256 proceeds;
        uint256 borrowTime;
    }

    struct GuardCase {
        FundingMidnight m;
        MockOracle oracle;
        bytes fd;
        bytes32 id;
        uint256 lltv;
        uint256 maxLtv;
        uint256 collateral;
        uint256 price;
        uint256 collValue;
        uint256 sellerPrice;
        uint256 guardUnits; // largest face the module guard allows with the pledged collateral
        uint256 healthUnits; // largest face Midnight's own health check allows with the pledged collateral
    }

    function setUp() public {
        vm.warp(T0);
        midnight = new MockMidnight();
        ratifier = new MockMidnightRatifier();
        ratifier.setAcceptAll(true);
        usdc = new ERC20MockDecimals(6);
        cbBtc = new ERC20MockDecimals(8);
        weth = new ERC20MockDecimals(18);
        midnightOracle = new MockOracle(CBBTC_PRICE);
        boxCbBtcOracle = new MockOracle(CBBTC_PRICE);

        Market memory m = _defaultMarket();
        id = midnight.touchMarket(m);
        fd = abi.encode(m, uint256(0), MAX_APR);
        Market memory m2 = _market(address(usdc), address(cbBtc), LLTV, address(midnightOracle), MATURITY2);
        midnight.touchMarket(m2);
        fd2 = abi.encode(m2, uint256(0), MAX_APR);

        box = IBox(address(new Box(address(usdc), owner, curator, "Box Midnight Fuzz", "BMF", 0.01 ether, 7 days, 10 days, 7 days)));
        module = new FundingMidnight(address(box), address(midnight), LLTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(cbBtc, boxCbBtcOracle);
        box.setIsAllocator(allocator, true);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, cbBtc);
        box.addFundingDebtInstant(module, usdc);
        box.addFundingFacilityInstant(module, fd);
        vm.stopPrank();

        vm.startPrank(lender);
        midnight.setIsAuthorized(address(ratifier), true, lender);
        usdc.approve(address(midnight), type(uint256).max);
        vm.stopPrank();
    }

    /////////////////////////////
    /// BUILDERS
    /////////////////////////////

    function _market(
        address loanToken,
        address collateralToken,
        uint256 lltv,
        address oracle,
        uint256 maturity
    ) internal view returns (Market memory m) {
        m.chainId = block.chainid;
        m.midnight = address(midnight);
        m.loanToken = loanToken;
        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] = CollateralParams(collateralToken, lltv, 0.3e18, oracle);
        m.maturity = maturity;
        m.rcfThreshold = 3000e6;
    }

    function _defaultMarket() internal view returns (Market memory) {
        return _market(address(usdc), address(cbBtc), LLTV, address(midnightOracle), MATURITY);
    }

    function _bid(Market memory m, uint256 tick, bytes32 group) internal view returns (Offer memory o) {
        o.market = m;
        o.buy = true;
        o.maker = lender;
        o.start = vm.getBlockTimestamp();
        o.expiry = m.maturity;
        o.tick = tick;
        o.group = group;
        o.ratifier = address(ratifier);
        o.maxUnits = type(uint128).max;
        o.continuousFeeCap = type(uint256).max;
    }

    function _fills(Offer memory o) internal pure returns (OfferFill[] memory f) {
        f = new OfferFill[](1);
        f[0] = OfferFill(o, "", type(uint256).max);
    }

    /// @dev The allocator stages one uncapped lender bid at `tick` for the next borrow of `facilityData`
    function _stage(FundingMidnight m, bytes memory facilityData, uint256 tick) internal {
        (Market memory mk, , ) = abi.decode(facilityData, (Market, uint256, uint256));
        uint256 now_ = vm.getBlockTimestamp();
        OfferFill[] memory fills = _fills(_bid(mk, tick, keccak256(abi.encode(facilityData, now_))));
        vm.prank(allocator);
        m.stageBorrow(facilityData, fills, now_ + 1 hours);
    }

    /// @dev Pledges `collateral` and borrows `amount` on the default facility at the lowest tick above the APR floor
    function _open(uint256 collateral, uint256 amount) internal returns (uint256 units) {
        cbBtc.mint(address(box), collateral);
        vm.prank(allocator);
        box.pledge(module, fd, cbBtc, collateral);
        uint256 tick = TICK_SPACING * _floorStep(MAX_APR, MATURITY - vm.getBlockTimestamp(), 0);
        units = _unitsFor(amount, TickLib.tickToPrice(tick));
        usdc.mint(lender, units);
        _stage(module, fd, tick);
        vm.prank(allocator);
        box.borrow(module, fd, usdc, amount);
        assertEq(midnight.debt(id, address(module)), units, "opened face");
    }

    /// @dev A module owned by the Box (not attached to it) with the default tokens registered and no facility
    function _freshModule() internal returns (FundingMidnight m) {
        m = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.startPrank(address(box));
        m.addCollateralToken(cbBtc);
        m.addDebtToken(usdc);
        vm.stopPrank();
    }

    function _assertModuleHoldsNothing(string memory step) internal view {
        assertEq(usdc.balanceOf(address(module)), 0, string.concat("module holds no loan token after ", step));
        assertEq(cbBtc.balanceOf(address(module)), 0, string.concat("module holds no collateral after ", step));
    }

    /////////////////////////////
    /// MODULE MATH REPLICA
    /////////////////////////////

    /// @dev Lowest seller price the module accepts: ceil(1e36 / (1e18 + floor(maxApr * ttm / 365 days)))
    function _minSellerPrice(uint256 maxApr, uint256 ttm) internal pure returns (uint256) {
        uint256 denominator = WAD + (maxApr * ttm) / YEAR;
        return (WAD * WAD + denominator - 1) / denominator;
    }

    /// @dev Price per unit received by the seller of a bid at `tick` net of the settlement fee (0 when unusable)
    function _sellerPrice(uint256 tick, uint256 fee) internal pure returns (uint256) {
        uint256 price = TickLib.tickToPrice(tick);
        return price > fee ? price - fee : 0;
    }

    /// @dev Smallest step k such that tick 4k clears the APR floor (tick prices are non-decreasing in the tick).
    ///      Requires the maximum tick (price 1e18) to clear it.
    function _floorStep(uint256 maxApr, uint256 ttm, uint256 fee) internal pure returns (uint256 lo) {
        uint256 pMin = _minSellerPrice(maxApr, ttm);
        require(_sellerPrice(TickLib.MAX_TICK, fee) >= pMin, "no tick clears the floor");
        uint256 hi = MAX_STEP;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_sellerPrice(mid * TICK_SPACING, fee) >= pMin) hi = mid;
            else lo = mid + 1;
        }
    }

    /// @dev Units the module sells for `amount`: ceil(amount * 1e18 / sellerPrice)
    function _unitsFor(uint256 amount, uint256 sellerPrice) internal pure returns (uint256) {
        return Math.mulDiv(amount, WAD, sellerPrice, Math.Rounding.Ceil);
    }

    /// @dev What the seller receives for `units` (Midnight rounds down): floor(units * sellerPrice / 1e18)
    function _proceedsOf(uint256 units, uint256 sellerPrice) internal pure returns (uint256) {
        return Math.mulDiv(units, sellerPrice, WAD);
    }

    /////////////////////////////
    /// VAL-FUZZ-006: BOX ROUND TRIP
    /////////////////////////////

    /// @dev pledge -> stageBorrow -> borrow -> (warp) -> repay(max) -> depledge(max) -> removeFundingFacility, all driven
    ///      by the real Box. The borrowed amount ranges up to the largest one the guard allows.
    function testFuzz_RoundTripThroughBox(
        uint256 collateral,
        uint256 oraclePrice,
        uint256 amountSeed,
        uint256 tickSeed,
        uint256 fee,
        uint256 borrowDelay,
        uint256 repayDelay
    ) public {
        vm.warp(T0 + bound(borrowDelay, 0, MATURITY - T0 - 1));
        uint256 ttm = MATURITY - vm.getBlockTimestamp();
        collateral = bound(collateral, 1e4, 1e14); // 0.0001 to 1,000,000 cbBTC
        oraclePrice = bound(oraclePrice, 1e36, 1e40); // 100 to 1,000,000 USDC per cbBTC at Midnight's oracle
        midnightOracle.setPrice(oraclePrice);
        fee = bound(fee, 0, Math.min(0.005e18, WAD - _minSellerPrice(MAX_APR, ttm)));
        midnight.setSettlementFee(id, fee);
        uint256 tick = TICK_SPACING * bound(tickSeed, _floorStep(MAX_APR, ttm, fee), MAX_STEP);
        uint256 sellerPrice = _sellerPrice(tick, fee);

        // Guard: ceil(units * 1e18 / collValue) <= maxLtv  <=>  units <= floor(maxLtv * collValue / 1e18)
        uint256 maxLtv = (LLTV * LLTV_CAP) / WAD;
        uint256 maxUnits = (maxLtv * ((collateral * oraclePrice) / ORACLE_SCALE)) / WAD;
        // units(a) <= maxUnits  <=>  a <= floor(maxUnits * sellerPrice / 1e18)
        uint256 amount = bound(amountSeed, 1, _proceedsOf(maxUnits, sellerPrice));
        uint256 units = _unitsFor(amount, sellerPrice);
        uint256 proceeds = _proceedsOf(units, sellerPrice);

        cbBtc.mint(address(box), collateral);
        usdc.mint(address(box), units); // enough to repay the face whatever the proceeds
        usdc.mint(lender, units);
        uint256 boxCollateralStart = cbBtc.balanceOf(address(box));
        uint256 boxLoanStart = usdc.balanceOf(address(box));

        vm.prank(allocator);
        box.pledge(module, fd, cbBtc, collateral);
        assertEq(module.collateralBalance(fd, cbBtc), collateral, "pledged");
        assertEq(cbBtc.balanceOf(address(box)), boxCollateralStart - collateral, "Box sent the collateral");
        _assertModuleHoldsNothing("pledge");

        _stage(module, fd, tick);
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertGt(validUntil, 0, "staged");
        _assertModuleHoldsNothing("stageBorrow");

        vm.prank(allocator);
        box.borrow(module, fd, usdc, amount);
        uint256 received = usdc.balanceOf(address(box)) - boxLoanStart;
        assertEq(received, proceeds, "Box receives floor(ceil(amount / price) * price) exactly");
        assertGe(received, amount, "Box receives at least the amount");
        assertEq(module.debtBalance(fd, usdc), units, "face = ceil(amount * 1e18 / sellerPrice)");
        (validUntil, ) = module.stagedBorrow(fd);
        assertEq(validUntil, 0, "staging consumed");
        assertLe(module.ltv(fd), maxLtv, "guard");
        _assertModuleHoldsNothing("borrow");

        uint256 now_ = vm.getBlockTimestamp();
        vm.warp(now_ + bound(repayDelay, 0, MATURITY - 1 - now_));

        uint256 boxLoanBeforeRepay = usdc.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fd, usdc, type(uint256).max);
        assertEq(boxLoanBeforeRepay - usdc.balanceOf(address(box)), units, "repay(max) costs exactly the face");
        assertEq(module.debtBalance(fd, usdc), 0, "debt closed");
        assertEq(midnight.debt(id, address(module)), 0, "no dust at Midnight");
        _assertModuleHoldsNothing("repay");

        vm.prank(allocator);
        box.depledge(module, fd, cbBtc, type(uint256).max);
        assertEq(module.collateralBalance(fd, cbBtc), 0, "collateral withdrawn");
        assertEq(cbBtc.balanceOf(address(box)), boxCollateralStart, "Box collateral back to start");
        _assertModuleHoldsNothing("depledge");

        assertEq(boxLoanStart - usdc.balanceOf(address(box)), units - proceeds, "net cost = face - proceeds");
        assertEq(module.nav(IOracleCallback(address(box))), 0, "empty position");

        vm.prank(curator);
        box.removeFundingFacility(module, fd);
        assertFalse(module.isFacility(fd), "facility removed");
        assertEq(module.facilitiesLength(), 0);
        _assertModuleHoldsNothing("removal");
    }

    /////////////////////////////
    /// VAL-FUZZ-007: NAV
    /////////////////////////////

    function _decimals(uint256 seed) internal pure returns (uint8) {
        uint256 choice = seed % 3;
        return choice == 0 ? 6 : (choice == 1 ? 8 : 18);
    }

    /// @dev Box oracle price (1e36 scale, asset units per token unit) worth 1e-4 to 1e6 whole assets per whole token.
    ///      Odd, so never a round power of ten.
    function _boxPrice(uint256 seed, uint8 assetDecimals, uint8 tokenDecimals) internal pure returns (uint256) {
        uint256 parity = 10 ** (36 + uint256(assetDecimals) - uint256(tokenDecimals));
        return bound(seed, parity / 1e4, parity * 1e6) | 1;
    }

    /// @dev Reference accreted debt (loan-token units) of one borrow of `units` for `proceeds` at `borrowTime`, at `t`:
    ///        t >= maturity : debtValue = units
    ///        otherwise     : R = floor((units - proceeds) * 1e18 / (maturity - borrowTime))   (discount per second)
    ///                        D = floor(R * (maturity - t) / 1e18)                               (unearned discount)
    ///                        debtValue = units - D                                              (D down, debt up)
    function _refDebtValue(
        uint256 units,
        uint256 proceeds,
        uint256 borrowTime,
        uint256 maturity,
        uint256 t
    ) internal pure returns (uint256) {
        if (t >= maturity) return units;
        uint256 rate = ((units - proceeds) * RATE_SCALE) / (maturity - borrowTime);
        return units - (rate * (maturity - t)) / RATE_SCALE;
    }

    /// @dev Reference nav of one facility:
    ///        max(0, floor(collateral * collPrice / 1e36) - ceil(debtValue * loanPrice / 1e36))
    ///      with loanPrice = 1e36 for the Box asset (valued 1:1, no rounding).
    function _refFacilityNav(uint256 collateral, uint256 collPrice, uint256 debtValue, uint256 loanPrice) internal pure returns (uint256) {
        uint256 collateralValue = (collateral * collPrice) / ORACLE_SCALE;
        uint256 debtInAsset = (debtValue * loanPrice + ORACLE_SCALE - 1) / ORACLE_SCALE;
        return collateralValue > debtInAsset ? collateralValue - debtInAsset : 0;
    }

    function _navBorrow(
        IBox navBox,
        FundingMidnight navModule,
        NavFacility memory f,
        uint256 collSeed,
        uint256 amountSeed,
        uint256 tickSeed
    ) internal {
        f.collateral = bound(collSeed, 1, 1e9 * 10 ** uint256(f.coll.decimals()));
        uint256 amount = bound(amountSeed, 1, 1e9 * 10 ** uint256(f.loan.decimals()));
        // Midnight's oracle only drives the guard: valuing the collateral at 4x the amount keeps the guard slack, so the
        // sizes and the Box prices are fuzzed independently (including facilities worth less than their debt)
        f.midnightOracle.setPrice(Math.mulDiv(4 * amount, ORACLE_SCALE, f.collateral, Math.Rounding.Ceil));
        f.borrowTime = vm.getBlockTimestamp();
        uint256 tick = TICK_SPACING * bound(tickSeed, _floorStep(WAD, f.maturity - f.borrowTime, 0), MAX_STEP);
        uint256 sellerPrice = TickLib.tickToPrice(tick);
        uint256 expectedUnits = _unitsFor(amount, sellerPrice);

        f.coll.mint(address(navBox), f.collateral);
        f.loan.mint(lender, expectedUnits);
        vm.prank(lender);
        f.loan.approve(address(midnight), type(uint256).max);

        vm.prank(allocator);
        navBox.pledge(navModule, f.fd, f.coll, f.collateral);
        _stage(navModule, f.fd, tick);
        uint256 before = f.loan.balanceOf(address(navBox));
        vm.prank(allocator);
        navBox.borrow(navModule, f.fd, f.loan, amount);
        f.proceeds = f.loan.balanceOf(address(navBox)) - before;
        f.units = navModule.debtBalance(f.fd, f.loan);
        assertEq(f.units, expectedUnits, "units sold");
        assertEq(f.proceeds, _proceedsOf(expectedUnits, sellerPrice), "proceeds at the Box");
    }

    function _checkNav(IBox navBox, FundingMidnight navModule, NavFacility[2] memory f) internal view {
        uint256 t = vm.getBlockTimestamp();
        uint256 expectedNav;
        for (uint256 i; i < 2; i++) {
            uint256 dv = _refDebtValue(f[i].units, f[i].proceeds, f[i].borrowTime, f[i].maturity, t);
            assertEq(navModule.debtValue(f[i].fd), dv, "debtValue = reference accretion");
            assertLe(f[i].proceeds, dv, "proceeds <= debtValue");
            assertLe(dv, f[i].units, "debtValue <= face");
            if (t >= f[i].maturity) {
                assertEq(dv, f[i].units, "debtValue = face at and after maturity");
            } else {
                // The reference discount D against the exact linear one (units - proceeds) * (M - t) / (M - borrowTime):
                // D <= exact (debt rounded up) and exact < D + 2 (two floors lose less than 2 wei)
                uint256 span = f[i].maturity - f[i].borrowTime;
                uint256 exactDiscountTimesSpan = (f[i].units - f[i].proceeds) * (f[i].maturity - t);
                assertLe((f[i].units - dv) * span, exactDiscountTimesSpan, "discount never above the linear one");
                assertLt(exactDiscountTimesSpan, (f[i].units - dv + 2) * span, "discount within 2 wei of the linear one");
            }

            uint256 facilityNav = _refFacilityNav(f[i].collateral, f[i].collPrice, dv, f[i].loanPrice);
            // nav <= exact unrounded equity: facilityNav <= (collateral * collPrice - dv * loanPrice) / 1e36, and dv is
            // at least the exact linear debt value (checked above), so this bounds nav by the unrounded equity
            uint256 collateralValueScaled = f[i].collateral * f[i].collPrice;
            uint256 debtValueScaled = dv * f[i].loanPrice;
            if (collateralValueScaled > debtValueScaled) {
                assertLe(facilityNav * ORACLE_SCALE, collateralValueScaled - debtValueScaled, "nav <= unrounded equity");
            } else {
                assertEq(facilityNav, 0, "negative equity floored at 0 per facility");
            }
            expectedNav += facilityNav;
        }
        uint256 nav = navModule.nav(IOracleCallback(address(navBox)));
        assertEq(nav, expectedNav, "nav = sum of per-facility references");

        // Box totalAssets = asset balance + Box-held tokens at the Box oracles + the module nav (collateral all pledged)
        uint256 boxLoan1 = (f[1].loan.balanceOf(address(navBox)) * f[1].loanPrice) / ORACLE_SCALE;
        assertEq(navBox.totalAssets(), f[0].loan.balanceOf(address(navBox)) + boxLoan1 + nav, "Box totalAssets uses the nav");
    }

    /// @dev Two facilities on two markets with tokens of 6, 8 or 18 decimals: facility 0 borrows the Box asset (valued
    ///      1:1), facility 1 borrows another token priced by a Box oracle. nav is checked right after the second borrow,
    ///      at a fuzzed time, at both maturities and after them.
    function testFuzz_NavMatchesReference(NavSeeds memory s) public {
        (IBox navBox, FundingMidnight navModule, NavFacility[2] memory f) = _navScenario(s);
        uint256[5] memory times = [
            f[1].borrowTime,
            f[1].borrowTime + bound(s.waitCheck, 0, 220 days),
            f[1].maturity,
            f[0].maturity,
            f[0].maturity + 7 days
        ];
        for (uint256 k; k < times.length; k++) {
            vm.warp(times[k]);
            _checkNav(navBox, navModule, f);
        }
    }

    /// @dev Pinned case of the fuzz test above where facility 0 is under water at the Box prices and facility 1 is not:
    ///      nav counts facility 1 in full (a netted nav would be lower)
    function testNavFloorsEachFacilityAtZero() public {
        NavSeeds memory s;
        s.decimals = 0; // every token has 6 decimals
        s.collateral0 = 1;
        s.amount0 = 1_000e6;
        s.tick0 = MAX_STEP;
        s.collPrice0 = 2e36;
        s.collateral1 = 1_000e6;
        s.amount1 = 100e6;
        s.tick1 = MAX_STEP;
        s.collPrice1 = 3e36;
        s.loanPrice1 = 1e36;
        (IBox navBox, FundingMidnight navModule, NavFacility[2] memory f) = _navScenario(s);

        uint256 t = vm.getBlockTimestamp();
        uint256 dv0 = _refDebtValue(f[0].units, f[0].proceeds, f[0].borrowTime, f[0].maturity, t);
        uint256 dv1 = _refDebtValue(f[1].units, f[1].proceeds, f[1].borrowTime, f[1].maturity, t);
        assertEq(_refFacilityNav(f[0].collateral, f[0].collPrice, dv0, f[0].loanPrice), 0, "facility 0 under water");
        assertGt(dv0, (f[0].collateral * f[0].collPrice) / ORACLE_SCALE, "facility 0 deficit");
        uint256 nav1 = _refFacilityNav(f[1].collateral, f[1].collPrice, dv1, f[1].loanPrice);
        assertGt(nav1, 0, "facility 1 positive");
        assertEq(navModule.nav(IOracleCallback(address(navBox))), nav1, "only facility 1 counts");
        _checkNav(navBox, navModule, f);
    }

    function _navScenario(NavSeeds memory s) internal returns (IBox navBox, FundingMidnight navModule, NavFacility[2] memory f) {
        ERC20MockDecimals asset = new ERC20MockDecimals(_decimals(s.decimals));
        navBox = IBox(address(new Box(address(asset), owner, curator, "Box Midnight Nav", "BMN", 0.01 ether, 7 days, 10 days, 7 days)));
        navModule = new FundingMidnight(address(navBox), address(midnight), WAD);
        uint8 assetDecimals = asset.decimals();

        f[0].loan = asset;
        f[0].loanPrice = ORACLE_SCALE;
        f[0].coll = new ERC20MockDecimals(_decimals(s.decimals / 3));
        f[0].collPrice = _boxPrice(s.collPrice0, assetDecimals, f[0].coll.decimals());
        f[0].maturity = T0 + 180 days;
        f[1].loan = new ERC20MockDecimals(_decimals(s.decimals / 9));
        f[1].loanPrice = _boxPrice(s.loanPrice1, assetDecimals, f[1].loan.decimals());
        f[1].coll = new ERC20MockDecimals(_decimals(s.decimals / 27));
        f[1].collPrice = _boxPrice(s.collPrice1, assetDecimals, f[1].coll.decimals());
        f[1].maturity = T0 + 90 days;

        MockOracle collOracle0 = new MockOracle(f[0].collPrice);
        MockOracle collOracle1 = new MockOracle(f[1].collPrice);
        MockOracle loanOracle1 = new MockOracle(f[1].loanPrice);
        for (uint256 i; i < 2; i++) {
            f[i].midnightOracle = new MockOracle(1);
            Market memory mk = _market(address(f[i].loan), address(f[i].coll), LLTV, address(f[i].midnightOracle), f[i].maturity);
            midnight.touchMarket(mk);
            f[i].fd = abi.encode(mk, uint256(0), WAD);
        }

        vm.startPrank(curator);
        navBox.setIsAllocator(allocator, true);
        navBox.addTokenInstant(f[0].coll, collOracle0);
        navBox.addTokenInstant(f[1].coll, collOracle1);
        navBox.addTokenInstant(f[1].loan, loanOracle1);
        navBox.addFundingInstant(navModule);
        for (uint256 i; i < 2; i++) {
            navBox.addFundingCollateralInstant(navModule, f[i].coll);
            navBox.addFundingDebtInstant(navModule, f[i].loan);
            navBox.addFundingFacilityInstant(navModule, f[i].fd);
        }
        vm.stopPrank();

        vm.warp(T0 + bound(s.wait0, 0, 60 days));
        _navBorrow(navBox, navModule, f[0], s.collateral0, s.amount0, s.tick0);
        vm.warp(f[0].borrowTime + bound(s.wait1, 0, 20 days));
        _navBorrow(navBox, navModule, f[1], s.collateral1, s.amount1, s.tick1);
    }

    /////////////////////////////
    /// VAL-FUZZ-008: GUARD BOUNDARIES
    /////////////////////////////

    /// @dev A new module (lltvCap), market (lltv, own Midnight oracle) and facility attached to the Box, with fuzzed
    ///      collateral pledged and one uncapped bid staged. The collateral value at Midnight's oracle lies in
    ///      [cvNeed, 1e33]: cvNeed makes the guard allow at least 2 units whenever maxLtv > 0 (so at least 1 wei can be
    ///      borrowed), and 1e33 keeps every face within Midnight's uint128.
    function _guardCase(
        uint256 lltv,
        uint256 lltvCap,
        uint256 collSeed,
        uint256 priceSeed,
        uint256 tickSeed
    ) internal returns (GuardCase memory g) {
        g.lltv = lltv;
        g.maxLtv = (lltv * lltvCap) / WAD;
        g.m = new FundingMidnight(address(box), address(midnight), lltvCap);
        g.oracle = new MockOracle(0);
        Market memory mk = _market(address(usdc), address(cbBtc), lltv, address(g.oracle), MATURITY);
        g.id = midnight.touchMarket(mk);
        g.fd = abi.encode(mk, uint256(0), WAD);

        vm.startPrank(curator);
        box.addFundingInstant(g.m);
        box.addFundingCollateralInstant(g.m, cbBtc);
        box.addFundingDebtInstant(g.m, usdc);
        box.addFundingFacilityInstant(g.m, g.fd);
        vm.stopPrank();

        g.collateral = bound(collSeed, 1, 1e30);
        uint256 cvNeed = g.maxLtv == 0 ? 1 : (2 * WAD + g.maxLtv - 1) / g.maxLtv;
        g.price = bound(priceSeed, (cvNeed * ORACLE_SCALE + g.collateral - 1) / g.collateral, (1e33 * ORACLE_SCALE) / g.collateral);
        g.oracle.setPrice(g.price);
        g.collValue = (g.collateral * g.price) / ORACLE_SCALE;
        g.guardUnits = (g.maxLtv * g.collValue) / WAD;
        g.healthUnits = (g.collValue * lltv) / WAD;

        uint256 tick = TICK_SPACING * bound(tickSeed, _floorStep(WAD, MATURITY - vm.getBlockTimestamp(), 0), MAX_STEP);
        g.sellerPrice = TickLib.tickToPrice(tick);

        cbBtc.mint(address(box), g.collateral);
        vm.prank(allocator);
        box.pledge(g.m, g.fd, cbBtc, g.collateral);
        _stage(g.m, g.fd, tick);
    }

    /// @dev The module guard after a borrow or a depledge, replicated: ltv = ceil(face * 1e18 / collValue) <= maxLtv,
    ///      with ltv = max when the collateral value is 0
    function _guardHolds(GuardCase memory g, uint256 units, uint256 collateral) internal pure returns (bool) {
        uint256 collValue = (collateral * g.price) / ORACLE_SCALE;
        return collValue > 0 && (units * WAD + collValue - 1) / collValue <= g.maxLtv;
    }

    /// @dev Borrow amounts map to units in steps: units(a) = ceil(a * 1e18 / sellerPrice). The largest allowed amount is
    ///      a* = floor(guardUnits * sellerPrice / 1e18) and "one more" is a* + 1, the smallest amount that sells more units
    ///      than the guard allows (it can sell one or two more units since sellerPrice < 1).
    ///      a* + 1 reverts with ExcessiveLTV when only the module guard is broken. When Midnight's own health check is
    ///      broken too (face > floor(collValue * lltv / 1e18), always the case with lltvCap = 1e18), the mock take reverts
    ///      SellerIsLiquidatable inside the module's try/catch, the fill is skipped and the module reverts
    ///      InsufficientLiquidity.
    function testFuzz_BorrowGuardBoundaryExact(
        uint256 lltv,
        uint256 lltvCap,
        uint256 capMode,
        uint256 collSeed,
        uint256 priceSeed,
        uint256 tickSeed
    ) public {
        lltv = bound(lltv, 1, WAD - 1); // MockMidnight requires lltv < 1e18
        lltvCap = capMode % 4 == 0 ? WAD : bound(lltvCap, 1, WAD);
        _borrowGuardBoundary(_guardCase(lltv, lltvCap, collSeed, priceSeed, tickSeed));
    }

    /// @dev Pins each predicted error of the borrow boundary
    function testBorrowGuardBoundaryErrorBranches() public {
        bytes4 excessive = ErrorsLib.ExcessiveLTV.selector;
        GuardCase memory g = _guardCase(LLTV, WAD, 5e8, CBBTC_PRICE, MAX_STEP);
        assertEq(_borrowGuardBoundary(g), ErrorsLib.InsufficientLiquidity.selector, "lltvCap = 1e18: Midnight binds");
        assertEq(_borrowGuardBoundary(_guardCase(LLTV, 0.5e18, 5e8, CBBTC_PRICE, MAX_STEP)), excessive, "module guard binds");
        assertEq(_borrowGuardBoundary(_guardCase(0.5e18, 1, 5e8, CBBTC_PRICE, MAX_STEP)), excessive, "maxLtv = 0: no debt");
    }

    /// @dev Returns the (predicted and observed) error of one wei above the largest allowed amount
    function _borrowGuardBoundary(GuardCase memory g) internal returns (bytes4 expected) {
        uint256 maxAmount = _proceedsOf(g.guardUnits, g.sellerPrice);
        uint256 nextUnits = _unitsFor(maxAmount + 1, g.sellerPrice);
        assertGt(nextUnits, g.guardUnits, "one more wei sells more units than allowed");
        assertLe(g.guardUnits, g.healthUnits, "the module guard is never looser than Midnight");
        usdc.mint(lender, nextUnits);

        expected = nextUnits > g.healthUnits ? ErrorsLib.InsufficientLiquidity.selector : ErrorsLib.ExcessiveLTV.selector;
        vm.prank(allocator);
        vm.expectRevert(expected);
        box.borrow(g.m, g.fd, usdc, maxAmount + 1);

        if (g.maxLtv == 0) {
            assertEq(maxAmount, 0, "a zero cap allows no debt");
            return expected;
        }
        uint256 units = _unitsFor(maxAmount, g.sellerPrice);
        assertLe(units, g.guardUnits, "largest amount fits");

        uint256 boxBefore = usdc.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(g.m, g.fd, usdc, maxAmount);
        assertEq(midnight.debt(g.id, address(g.m)), units, "face");
        assertEq(usdc.balanceOf(address(box)) - boxBefore, _proceedsOf(units, g.sellerPrice), "proceeds");
        uint256 ltv = g.m.ltv(g.fd);
        assertEq(ltv, (units * WAD + g.collValue - 1) / g.collValue, "ltv = ceil(face * 1e18 / collValue)");
        assertLe(ltv, g.maxLtv, "within lltv * lltvCap");
    }

    /// @dev After a fuzzed borrow (possibly none), the largest allowed withdrawal leaves minCollateral, the smallest
    ///      remaining collateral whose value keeps the guard: cv(r) = floor(r * price / 1e36) >= ceil(face * 1e18 / maxLtv).
    ///      One more unit reverts with ExcessiveLTV, or with Midnight's UnhealthyBorrower when its own health check (face
    ///      <= floor(cv * lltv / 1e18)) binds first; the mock's withdrawCollateral error is not caught by the module.
    ///      Without debt the guard does not apply (ltv is 0), the whole balance is allowed and one more unit makes
    ///      Midnight's collateral subtraction underflow: Panic(0x11), also uncaught (the module has no amount check).
    function testFuzz_DepledgeGuardBoundaryExact(
        uint256 lltv,
        uint256 lltvCap,
        uint256 capMode,
        uint256 collSeed,
        uint256 priceSeed,
        uint256 tickSeed,
        uint256 amountSeed
    ) public {
        lltv = bound(lltv, 1, WAD - 1);
        // A cap with lltv * lltvCap < 1e18 gives maxLtv = 0, where only the no-debt case is possible
        lltvCap = capMode % 4 == 0 ? WAD : bound(lltvCap, 1, WAD);
        bool noDebt = (capMode / 4) % 4 == 0;
        _depledgeGuardBoundary(_guardCase(lltv, lltvCap, collSeed, priceSeed, tickSeed), amountSeed, noDebt);
    }

    /// @dev Pins each predicted error of the depledge boundary
    function testDepledgeGuardBoundaryErrorBranches() public {
        GuardCase memory g = _guardCase(LLTV, WAD, 5e8, CBBTC_PRICE, MAX_STEP);
        bytes memory unhealthy = abi.encodeWithSelector(MockMidnight.UnhealthyBorrower.selector);
        assertEq(_depledgeGuardBoundary(g, 100_000e6, false), unhealthy, "lltvCap = 1e18: Midnight binds");
        g = _guardCase(LLTV, 0.5e18, 5e8, CBBTC_PRICE, MAX_STEP);
        bytes memory excessive = abi.encodeWithSelector(ErrorsLib.ExcessiveLTV.selector);
        assertEq(_depledgeGuardBoundary(g, 100_000e6, false), excessive, "module guard binds");
        g = _guardCase(LLTV, 0.5e18, 5e8, CBBTC_PRICE, MAX_STEP);
        assertEq(_depledgeGuardBoundary(g, 100_000e6, true), stdError.arithmeticError, "no debt: whole balance, then underflow");
        g = _guardCase(0.5e18, 1, 5e8, CBBTC_PRICE, MAX_STEP);
        assertEq(_depledgeGuardBoundary(g, 100_000e6, false), stdError.arithmeticError, "maxLtv = 0: no debt possible");
    }

    /// @dev Borrows a fuzzed amount (none when `noDebt` or when the guard allows no debt), then returns the (predicted
    ///      and observed) revert data of one unit above the largest allowed withdrawal
    function _depledgeGuardBoundary(GuardCase memory g, uint256 amountSeed, bool noDebt) internal returns (bytes memory expected) {
        uint256 amount = noDebt ? 0 : bound(amountSeed, 0, _proceedsOf(g.guardUnits, g.sellerPrice));
        uint256 units;
        if (amount > 0) {
            units = _unitsFor(amount, g.sellerPrice);
            usdc.mint(lender, units);
            vm.prank(allocator);
            box.borrow(g.m, g.fd, usdc, amount);
        }
        assertEq(midnight.debt(g.id, address(g.m)), units, "face");

        uint256 minCollateral;
        if (units == 0) {
            expected = stdError.arithmeticError;
        } else {
            uint256 minCollValue = (units * WAD + g.maxLtv - 1) / g.maxLtv;
            minCollateral = (minCollValue * ORACLE_SCALE + g.price - 1) / g.price;
            assertLe(minCollateral, g.collateral, "the guard held after the borrow");
            assertTrue(_guardHolds(g, units, minCollateral), "guard holds at minCollateral");
            assertFalse(_guardHolds(g, units, minCollateral - 1), "guard broken one unit below");
            uint256 collValueAfter = ((minCollateral - 1) * g.price) / ORACLE_SCALE;
            bool midnightBinds = units > (collValueAfter * g.lltv) / WAD;
            expected = abi.encodeWithSelector(midnightBinds ? MockMidnight.UnhealthyBorrower.selector : ErrorsLib.ExcessiveLTV.selector);
        }
        uint256 maxWithdrawal = g.collateral - minCollateral;

        vm.prank(allocator);
        vm.expectRevert(expected);
        box.depledge(g.m, g.fd, cbBtc, maxWithdrawal + 1);

        uint256 boxBefore = cbBtc.balanceOf(address(box));
        vm.prank(allocator);
        box.depledge(g.m, g.fd, cbBtc, maxWithdrawal);
        assertEq(cbBtc.balanceOf(address(box)) - boxBefore, maxWithdrawal, "Box receives the withdrawal");
        assertEq(g.m.collateralBalance(g.fd, cbBtc), minCollateral, "remaining collateral");
        uint256 ltv = g.m.ltv(g.fd);
        if (units == 0) {
            assertEq(ltv, 0, "no debt: ltv 0");
        } else {
            uint256 remainingValue = (minCollateral * g.price) / ORACLE_SCALE;
            assertEq(ltv, (units * WAD + remainingValue - 1) / remainingValue, "ltv = ceil(face * 1e18 / collValue)");
            assertLe(ltv, g.maxLtv, "within lltv * lltvCap");
        }
    }

    /////////////////////////////
    /// VAL-FUZZ-009: FACILITY DATA
    /////////////////////////////

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = data[i];
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), offset))
        }
    }

    function _withWord(bytes memory data, uint256 offset, bytes32 w) internal pure returns (bytes memory out) {
        out = bytes.concat(data);
        assembly ("memory-safe") {
            mstore(add(add(out, 32), offset), w)
        }
    }

    /// @dev Decodes from memory like FundingMidnight.decodeFacilityData; external so that a failure can be caught
    function decodeFacility(bytes memory data) external pure returns (Market memory, uint256, uint256) {
        return abi.decode(data, (Market, uint256, uint256));
    }

    /// @dev Replica of FundingMidnight.addFacility's checks, in order. Returns the expected revert data, or success.
    ///      A decoding failure is predicted with the revert data of the same decoder (empty, or Panic(0x41) when the
    ///      collateralParams length is too large to allocate).
    function _predictAddFacility(FundingMidnight m, bytes memory data) internal view returns (bool success, bytes memory revertData) {
        try this.decodeFacility(data) returns (Market memory mk, uint256 collateralIndex, uint256 maxBorrowApr) {
            if (keccak256(abi.encode(mk, collateralIndex, maxBorrowApr)) != keccak256(data)) {
                return (false, abi.encodeWithSelector(ErrorsLib.InvalidFacilityData.selector));
            }
            if (
                mk.midnight != address(midnight) ||
                mk.chainId != block.chainid ||
                collateralIndex >= mk.collateralParams.length ||
                mk.maturity <= vm.getBlockTimestamp() ||
                maxBorrowApr == 0 ||
                maxBorrowApr > WAD
            ) return (false, abi.encodeWithSelector(ErrorsLib.InvalidValue.selector));
            bytes32 marketId = IdLib.toId(mk);
            if (midnight.tickSpacing(marketId) == 0) return (false, abi.encodeWithSelector(ErrorsLib.InvalidValue.selector));
            if (!m.isCollateralToken(IERC20(mk.collateralParams[collateralIndex].token)) || !m.isDebtToken(IERC20(mk.loanToken))) {
                return (false, abi.encodeWithSelector(ErrorsLib.TokenNotWhitelisted.selector));
            }
            if (m.facilityOfMarket(marketId) != bytes32(0) || m.isFacility(data)) {
                return (false, abi.encodeWithSelector(ErrorsLib.AlreadyWhitelisted.selector));
            }
            return (true, "");
        } catch (bytes memory reason) {
            return (false, reason);
        }
    }

    /// @dev Calls addFacility as the owner and checks the outcome against the replica
    function _assertAddFacilityMatchesReplica(FundingMidnight m, bytes memory data) internal returns (bool ok) {
        (bool expectOk, bytes memory expectedRevert) = _predictAddFacility(m, data);
        uint256 lengthBefore = m.facilitiesLength();
        bytes memory ret;
        vm.prank(address(box));
        (ok, ret) = address(m).call(abi.encodeCall(FundingMidnight.addFacility, (data)));
        assertEq(ok, expectOk, "outcome predicted by the replica");
        if (ok) {
            (Market memory mk, uint256 collateralIndex, uint256 maxBorrowApr) = this.decodeFacility(data);
            assertEq(keccak256(abi.encode(mk, collateralIndex, maxBorrowApr)), keccak256(data), "accepted bytes are canonical");
            assertTrue(m.isFacility(data), "registered");
            assertEq(m.facilityOfMarket(IdLib.toId(mk)), keccak256(data));
            assertEq(m.facilitiesLength(), lengthBefore + 1);
        } else {
            assertEq(ret, expectedRevert, "exact revert data");
            assertEq(m.facilitiesLength(), lengthBefore, "nothing registered");
            assertFalse(m.isFacility(data));
        }
    }

    /// @dev Checks that addFacility reverts with exactly `expected` (empty for an ABI decoding failure)
    function _assertAddFacilityReverts(FundingMidnight m, bytes memory data, bytes memory expected, string memory what) internal {
        (bool expectOk, bytes memory predicted) = _predictAddFacility(m, data);
        assertFalse(expectOk, what);
        assertEq(predicted, expected, string.concat(what, ": replica agrees"));
        uint256 lengthBefore = m.facilitiesLength();
        vm.prank(address(box));
        (bool ok, bytes memory ret) = address(m).call(abi.encodeCall(FundingMidnight.addFacility, (data)));
        assertFalse(ok, what);
        assertEq(ret, expected, what);
        assertEq(m.facilitiesLength(), lengthBefore, what);
        assertFalse(m.isFacility(data), what);
    }

    /// @dev Arbitrary bytes, or a canonical prefix followed by arbitrary bytes, never register (unless canonical and valid)
    function testFuzz_AddFacilityArbitraryBytes(bytes memory data, uint256 mode, uint256 cut) public {
        if (mode % 2 == 1) data = bytes.concat(_slice(fd, 0, bound(cut, 0, fd.length)), data);
        _assertAddFacilityMatchesReplica(_freshModule(), data);
    }

    /// @dev One word of a canonical encoding XORed with a fuzzed mask: accepted exactly when the result is the canonical
    ///      encoding of a valid facility (e.g. another maxBorrowApr in range), otherwise the replica's error
    function testFuzz_AddFacilityMutatedWord(uint256 maxBorrowApr, uint256 wordIndex, uint256 mask) public {
        maxBorrowApr = bound(maxBorrowApr, 1, WAD);
        bytes memory canonical = abi.encode(_defaultMarket(), uint256(0), maxBorrowApr);
        uint256 at = 32 * bound(wordIndex, 0, canonical.length / 32 - 1);
        bytes memory data = _withWord(canonical, at, _word(canonical, at) ^ bytes32(mask));
        bool ok = _assertAddFacilityMatchesReplica(_freshModule(), data);
        if (mask == 0) assertTrue(ok, "the canonical bytes register");
    }

    /// @dev Layout of abi.encode(Market, uint256, uint256) with one collateral (512 bytes): [0] market offset 0x60,
    ///      [32] collateralIndex, [64] maxBorrowApr, [96..352) market head (chainId, midnight, loanToken, collateralParams
    ///      offset 0x100, maturity, rcfThreshold, enterGate, liquidatorGate), [352] collateralParams length, [384..512)
    ///      collateral 0 (token, lltv, liquidationCursor, oracle).
    ///      Expected errors: trailing bytes and alternative layouts decode to the same values and fail the re-encoding
    ///      check (InvalidFacilityData); dirty address bits, truncation, a longer array and the struct-wrapped encoding
    ///      make the ABI decoder itself revert, with empty revert data (Panic(0x41) for an array length above 2^64 - 1).
    function testFuzz_NonCanonicalFacilityDataExactErrors(
        bytes memory tail,
        uint256 wordSel,
        uint256 dirt,
        uint256 cut,
        uint256 newLength,
        uint256 maxBorrowApr
    ) public {
        maxBorrowApr = bound(maxBorrowApr, 1, WAD);
        bytes memory canonical = abi.encode(_defaultMarket(), uint256(0), maxBorrowApr);
        assertEq(canonical.length, 512, "layout");
        assertEq(uint256(_word(canonical, 192)), 0x100, "layout");
        FundingMidnight fresh = _freshModule();
        bytes memory invalidFacilityData = abi.encodeWithSelector(ErrorsLib.InvalidFacilityData.selector);

        _assertAddFacilityReverts(
            fresh,
            bytes.concat(canonical, tail.length == 0 ? bytes(hex"00") : tail),
            invalidFacilityData,
            "appended"
        );

        uint256[6] memory addressWords = [uint256(128), 160, 288, 320, 384, 480];
        uint256 at = addressWords[wordSel % 6];
        bytes32 dirty = _word(canonical, at) | bytes32(bound(dirt, 1, type(uint96).max) << 160);
        _assertAddFacilityReverts(fresh, _withWord(canonical, at, dirty), "", "dirty address bits");

        _assertAddFacilityReverts(fresh, _slice(canonical, 0, canonical.length - bound(cut, 1, canonical.length)), "", "truncated");

        uint256 mode = newLength % 3;
        uint256 length = mode == 0 ? 0 : (mode == 1 ? bound(newLength, 2, type(uint32).max) : bound(newLength, 2 ** 64, type(uint256).max));
        bytes memory expected = mode == 0 ? invalidFacilityData : (mode == 1 ? bytes("") : abi.encodeWithSignature("Panic(uint256)", 0x41));
        _assertAddFacilityReverts(fresh, _withWord(canonical, 352, bytes32(length)), expected, "collateralParams length");

        _assertAddFacilityReverts(fresh, abi.encode(WrappedMidnightFacility(_defaultMarket(), 0, maxBorrowApr)), "", "struct-wrapped");

        bytes memory shiftedMarket = bytes.concat(
            bytes32(uint256(0x80)),
            _slice(canonical, 32, 96),
            bytes32(0),
            _slice(canonical, 96, 512)
        );
        _assertAddFacilityReverts(fresh, shiftedMarket, invalidFacilityData, "market offset 0x80");

        vm.prank(address(box));
        fresh.addFacility(canonical);
        assertTrue(fresh.isFacility(canonical), "the canonical bytes register");
    }

    /// @dev Facility data that is not byte for byte the registered encoding
    function _otherFacilityData(uint256 kind, bytes memory rnd, uint256 seed) internal view returns (bytes memory x) {
        kind = kind % 8;
        if (kind == 0) {
            x = rnd;
        } else if (kind == 1) {
            x = bytes.concat(fd, rnd.length == 0 ? bytes(hex"00") : rnd);
        } else if (kind == 2) {
            uint256[6] memory addressWords = [uint256(128), 160, 288, 320, 384, 480];
            uint256 at = addressWords[seed % 6];
            x = _withWord(fd, at, _word(fd, at) | bytes32(uint256(keccak256(abi.encode(seed))) << 160));
            if (keccak256(x) == keccak256(fd)) x = _withWord(fd, at, _word(fd, at) | bytes32(uint256(1) << 255));
        } else if (kind == 3) {
            x = _slice(fd, 0, fd.length - bound(seed, 1, fd.length));
        } else if (kind == 4) {
            x = abi.encode(WrappedMidnightFacility(_defaultMarket(), 0, MAX_APR));
        } else if (kind == 5) {
            uint256 apr = bound(seed, 1, WAD - 1);
            x = abi.encode(_defaultMarket(), uint256(0), apr >= MAX_APR ? apr + 1 : apr); // same market, other bound
        } else if (kind == 6) {
            x = fd2;
        } else {
            x = _withWord(fd, 32 * (seed % 16), _word(fd, 32 * (seed % 16)) ^ bytes32(uint256(keccak256(abi.encode(seed))) | 1));
        }
        if (keccak256(x) == keccak256(fd)) x = bytes.concat(x, hex"00");
    }

    /// @dev With a live position on the registered facility, any other bytes are not a facility: views read 0 and every
    ///      action (through the Box and directly as owner) and stageBorrow revert with NotWhitelisted
    function testFuzz_OnlyRegisteredFacilityDataIsUsable(uint256 kind, bytes memory rnd, uint256 seed, uint256 amount) public {
        uint256 units = _open(5e8, 100_000e6);
        bytes memory x = _otherFacilityData(kind, rnd, seed);
        assertTrue(keccak256(x) != keccak256(fd), "not the registered bytes");
        amount = bound(amount, 1, 1e8);

        assertFalse(module.isFacility(x), "isFacility");
        assertEq(module.debtBalance(x, usdc), 0);
        assertEq(module.collateralBalance(x, cbBtc), 0);
        assertEq(module.ltv(x), 0);
        assertEq(module.debtValue(x), 0);

        cbBtc.mint(address(box), amount);
        OfferFill[] memory fills = _fills(_bid(_defaultMarket(), TickLib.MAX_TICK, "x"));
        bytes4 notWhitelisted = ErrorsLib.NotWhitelisted.selector;
        vm.startPrank(allocator);
        vm.expectRevert(notWhitelisted);
        box.pledge(module, x, cbBtc, amount);
        vm.expectRevert(notWhitelisted);
        box.depledge(module, x, cbBtc, type(uint256).max);
        vm.expectRevert(notWhitelisted);
        box.borrow(module, x, usdc, amount);
        vm.expectRevert(notWhitelisted);
        box.repay(module, x, usdc, type(uint256).max);
        vm.expectRevert(notWhitelisted);
        module.stageBorrow(x, fills, vm.getBlockTimestamp());
        vm.stopPrank();

        vm.startPrank(address(box));
        vm.expectRevert(notWhitelisted);
        module.pledge(x, cbBtc, amount);
        vm.expectRevert(notWhitelisted);
        module.depledge(x, cbBtc, amount);
        vm.expectRevert(notWhitelisted);
        module.borrow(x, usdc, amount);
        vm.expectRevert(notWhitelisted);
        module.repay(x, usdc, amount);
        vm.expectRevert(notWhitelisted);
        module.removeFacility(x);
        vm.stopPrank();

        assertEq(midnight.debt(id, address(module)), units, "position untouched");
        assertEq(midnight.collateral(id, address(module), 0), 5e8, "position untouched");
        assertTrue(module.isFacility(fd));
        _assertModuleHoldsNothing("rejected actions");
    }

    /////////////////////////////
    /// VAL-FUZZ-010: CALLERS
    /////////////////////////////

    function _ownerGatedCalls(uint256 amount) internal view returns (bytes[] memory calls) {
        IERC20 c = IERC20(address(cbBtc));
        IERC20 d = IERC20(address(usdc));
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(FundingMidnight.addFacility, (fd2));
        calls[1] = abi.encodeCall(FundingMidnight.removeFacility, (fd));
        calls[2] = abi.encodeCall(IFunding.addCollateralToken, (IERC20(address(weth))));
        calls[3] = abi.encodeCall(IFunding.addDebtToken, (IERC20(address(weth))));
        calls[4] = abi.encodeCall(FundingMidnight.removeCollateralToken, (c));
        calls[5] = abi.encodeCall(FundingMidnight.removeDebtToken, (d));
        calls[6] = abi.encodeCall(IFunding.skim, (d));
        calls[7] = abi.encodeCall(FundingMidnight.pledge, (fd, c, amount));
        calls[8] = abi.encodeCall(FundingMidnight.depledge, (fd, c, amount));
        calls[9] = abi.encodeCall(FundingMidnight.borrow, (fd, d, amount));
        calls[10] = abi.encodeCall(FundingMidnight.repay, (fd, d, amount));
    }

    function _moduleState() internal view returns (bytes32) {
        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        return
            keccak256(
                abi.encode(
                    midnight.debt(id, address(module)),
                    midnight.collateral(id, address(module), 0),
                    module.facilitiesArray(),
                    module.collateralTokensArray(),
                    module.debtTokensArray(),
                    usdc.balanceOf(address(module)),
                    cbBtc.balanceOf(address(module)),
                    validUntil,
                    staged
                )
            );
    }

    /// @dev Every owner-gated function, called directly or wrapped in multicall, reverts OnlyOwner for `caller`
    function _assertGatedCallsRevert(address caller, uint256 amount) internal {
        bytes32 stateBefore = _moduleState();
        bytes[] memory calls = _ownerGatedCalls(amount);
        bytes memory onlyOwner = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(module).call(calls[i]);
            assertFalse(ok, "gated call");
            assertEq(ret, onlyOwner, "gated call reverts OnlyOwner");

            bytes[] memory inner = new bytes[](2);
            inner[0] = abi.encodeCall(IFunding.isFacility, (fd));
            inner[1] = calls[i];
            vm.prank(caller);
            (ok, ret) = address(module).call(abi.encodeCall(FundingBase.multicall, (inner)));
            assertFalse(ok, "multicall");
            assertEq(ret, onlyOwner, "multicall reverts OnlyOwner");
        }
        assertEq(_moduleState(), stateBefore, "nothing changed");
    }

    /// @dev A live position, a staging and idle tokens make every gated call meaningful
    function _liveModule() internal {
        _open(5e8, 100_000e6);
        _stage(module, fd, TickLib.MAX_TICK);
        usdc.mint(address(module), 5_000e6);
        cbBtc.mint(address(module), 1e8);
    }

    function testFuzz_NonOwnerCannotCallGatedFunctions(address caller, uint256 amount) public {
        if (caller == address(box)) caller = address(uint160(caller) ^ 1);
        _liveModule();
        _assertGatedCallsRevert(caller, bound(amount, 1, 1e12));
    }

    /// @dev stageBorrow is open to Box allocators only, and a revoked allocator's staging cannot be borrowed against
    function testFuzz_StageBorrowOnlyAllocators(address caller, uint256 validity) public {
        uint256 validUntil = vm.getBlockTimestamp() + bound(validity, 0, 30 days);
        OfferFill[] memory fills = _fills(_bid(_defaultMarket(), 4212, "fuzz"));

        if (!box.isAllocator(caller)) {
            vm.prank(caller);
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            module.stageBorrow(fd, fills, validUntil);
            (uint256 none, ) = module.stagedBorrow(fd);
            assertEq(none, 0, "nothing staged");
        }

        address registered = caller == address(0) ? makeAddr("zeroCaller") : caller; // Box rejects a zero allocator
        if (!box.isAllocator(registered)) {
            vm.prank(curator);
            box.setIsAllocator(registered, true);
        }
        assertTrue(box.isAllocator(registered), "registered allocator");
        vm.prank(registered);
        module.stageBorrow(fd, fills, validUntil);
        (uint256 storedUntil, OfferFill[] memory stored) = module.stagedBorrow(fd);
        assertEq(storedUntil, validUntil, "validUntil stored");
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(fills)), "fills stored");

        if (registered != allocator) {
            vm.prank(curator);
            box.setIsAllocator(registered, false);
            vm.prank(registered);
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            module.stageBorrow(fd, fills, validUntil);
            vm.prank(allocator);
            vm.expectRevert(ErrorsLib.NoValidStaging.selector);
            box.borrow(module, fd, usdc, 1);
        }
    }

    function _eligibleRole(address candidate, address current, string memory label) internal returns (address) {
        return candidate == address(0) || candidate == address(box) || candidate == current ? makeAddr(label) : candidate;
    }

    /// @dev A real Box owning the module, with fuzzed curator, guardian and registered allocator (plus the original
    ///      roles): none of them can call an owner-gated function directly, and the allocator can still stage
    function testFuzz_BoxRolesCannotCallGatedFunctions(
        address newCurator,
        address newGuardian,
        address newAllocator,
        uint256 amount
    ) public {
        _liveModule();
        assertEq(module.owner(), address(box), "the Box owns the module");
        newCurator = _eligibleRole(newCurator, curator, "newCurator");
        newGuardian = _eligibleRole(newGuardian, guardian, "newGuardian");
        newAllocator = _eligibleRole(newAllocator, address(0), "newAllocator");

        vm.prank(owner);
        box.setCurator(newCurator);
        vm.startPrank(newCurator);
        box.setGuardianInstant(newGuardian);
        if (!box.isAllocator(newAllocator)) box.setIsAllocator(newAllocator, true);
        vm.stopPrank();
        assertEq(box.curator(), newCurator, "curator");
        assertEq(box.guardian(), newGuardian, "guardian");
        assertTrue(box.isAllocator(newAllocator), "allocator registered");
        assertTrue(box.isAllocator(allocator), "allocator registered");

        address[6] memory callers = [allocator, curator, guardian, newAllocator, newCurator, newGuardian];
        amount = bound(amount, 1, 1e12);
        for (uint256 i; i < callers.length; i++) _assertGatedCallsRevert(callers[i], amount);

        OfferFill[] memory fills = _fills(_bid(_defaultMarket(), 4212, "role"));
        vm.prank(newAllocator);
        module.stageBorrow(fd, fills, vm.getBlockTimestamp() + 1);
        (uint256 validUntil, OfferFill[] memory stored) = module.stagedBorrow(fd);
        assertEq(validUntil, vm.getBlockTimestamp() + 1, "the allocator can stage");
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(fills)));
    }

    /////////////////////////////
    /// VAL-FUZZ-011: UNKNOWN TOKENS
    /////////////////////////////

    function _assertUnknownTokenReadsZero(address token) internal view {
        assertEq(module.debtBalance(IERC20(token)), 0, "debtBalance(token)");
        assertEq(module.collateralBalance(IERC20(token)), 0, "collateralBalance(token)");
        assertEq(module.debtBalance(fd, IERC20(token)), 0, "debtBalance(fd, token)");
        assertEq(module.collateralBalance(fd, IERC20(token)), 0, "collateralBalance(fd, token)");
    }

    /// @dev With a live position, unregistered tokens (fuzzed, zero, an EOA, a contract without balanceOf, an ERC20
    ///      nobody knows) read 0 without reverting, and so do per-facility views of unregistered or malformed data
    function testFuzz_UnknownTokensReadZeroWithLivePosition(
        address token,
        bytes memory otherFd,
        uint256 collateral,
        uint256 amount
    ) public {
        collateral = bound(collateral, 1e6, 1e10);
        amount = bound(amount, 1, (collateral * 50_000e6) / 1e8); // at most 50,000 USDC per cbBTC
        uint256 units = _open(collateral, amount);
        assertEq(module.debtBalance(usdc), units, "live debt");
        assertEq(module.collateralBalance(cbBtc), collateral, "live collateral");
        assertEq(module.debtBalance(fd, usdc), units, "live debt");
        assertEq(module.collateralBalance(fd, cbBtc), collateral, "live collateral");

        if (token == address(usdc) || token == address(cbBtc)) token = address(uint160(uint256(keccak256(abi.encode(token)))));
        if (token == VM_ADDRESS || token == CONSOLE || token == CREATE2_FACTORY) token = address(uint160(token) ^ 1);
        _assertUnknownTokenReadsZero(token);
        _assertUnknownTokenReadsZero(address(0));
        address eoa = makeAddr("eoa");
        assertEq(eoa.code.length, 0, "the EOA has no code");
        _assertUnknownTokenReadsZero(eoa);
        assertGt(address(ratifier).code.length, 0, "the ratifier is a contract");
        (bool hasBalanceOf, ) = address(ratifier).staticcall(abi.encodeCall(IERC20.balanceOf, (address(module))));
        assertFalse(hasBalanceOf, "the ratifier has no balanceOf");
        _assertUnknownTokenReadsZero(address(ratifier));
        _assertUnknownTokenReadsZero(address(new ERC20MockDecimals(18))); // an ERC20 neither Midnight nor the module knows
        _assertUnknownTokenReadsZero(address(weth));
        // Registered tokens in the other role
        assertEq(module.debtBalance(cbBtc), 0);
        assertEq(module.collateralBalance(usdc), 0);
        assertEq(module.debtBalance(fd, cbBtc), 0);
        assertEq(module.collateralBalance(fd, usdc), 0);

        if (keccak256(otherFd) == keccak256(fd)) otherFd = bytes.concat(otherFd, hex"00");
        bytes memory otherValid = fd2;
        bytes[6] memory unregistered = [
            otherFd,
            otherValid,
            bytes.concat(fd, hex"00"),
            _slice(fd, 0, fd.length - 1),
            abi.encode(WrappedMidnightFacility(_defaultMarket(), 0, MAX_APR)),
            _withWord(fd, 160, _word(fd, 160) | bytes32(uint256(1) << 200))
        ];
        for (uint256 i; i < unregistered.length; i++) {
            assertEq(module.debtBalance(unregistered[i], usdc), 0, "debtBalance(bad fd, loan)");
            assertEq(module.collateralBalance(unregistered[i], cbBtc), 0, "collateralBalance(bad fd, collateral)");
            assertEq(module.debtBalance(unregistered[i], IERC20(token)), 0, "debtBalance(bad fd, token)");
            assertEq(module.collateralBalance(unregistered[i], IERC20(token)), 0, "collateralBalance(bad fd, token)");
            assertEq(module.ltv(unregistered[i]), 0, "ltv(bad fd)");
            assertEq(module.debtValue(unregistered[i]), 0, "debtValue(bad fd)");
        }
    }
}
