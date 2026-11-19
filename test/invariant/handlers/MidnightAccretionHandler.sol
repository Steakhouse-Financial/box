// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundingMidnight, OfferFill} from "../../../src/FundingMidnight.sol";
import {IBox} from "../../../src/interfaces/IBox.sol";
import {Market, Offer} from "../../../src/interfaces/midnight/IMidnight.sol";
import {TickLib} from "../../../src/libraries/midnight/TickLib.sol";
import {ERC20MockDecimals} from "../../mocks/ERC20MockDecimals.sol";
import {MockMidnight} from "../../mocks/MockMidnight.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";

/// @dev Contracts, roles and facilities of the Midnight accretion invariant suite
struct MidnightAccretionSystem {
    IBox box;
    FundingMidnight module;
    MockMidnight midnight;
    ERC20MockDecimals usdc; // Box asset and loan token of both facilities
    MockOracle collateralOracle; // Midnight market oracle and Box oracle of the collateral
    address ratifier;
    address allocator;
    address lender;
    bytes[2] fds;
    uint256 maxBorrowApr;
}

/// @notice Handler of the FundingMidnight debt-accretion invariant suite, the only target contract of the campaign.
/// @dev Actions: staged borrows (one or two lender bids at fuzzed ticks at or above the APR floor, the first one possibly
///      capped so that the second one is used), partial and full face-value repays through the Box, external face
///      reductions on the mock (as a liquidation would do), warps (arbitrary, and exactly to or just past a maturity).
///      As in the Box + Morpho handler, an action either executes or reverts (`Skipped` for a pointless call), and
///      violations are recorded in ghosts that the invariant functions check.
contract MidnightAccretionHandler is Test {
    error Skipped();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant TICK_SPACING = 4; // MockMidnight's tick spacing
    uint256 internal constant MAX_STEP = 1686; // TickLib.MAX_TICK / TICK_SPACING
    uint256 internal constant MATURITY_AFTER_BORROWS = 6;

    IBox public immutable box;
    FundingMidnight public immutable module;
    MockMidnight public immutable midnight;
    ERC20MockDecimals public immutable usdc;
    MockOracle public immutable collateralOracle;
    address public immutable ratifier;
    address public immutable allocator;
    address public immutable lender;
    uint256 public immutable maxBorrowApr;
    bytes[2] internal fds;
    Market[2] internal markets;
    bytes32[2] internal ids;
    uint256 internal nonce;

    // ========== SUCCESS COUNTERS ==========

    uint256 public borrowOk;
    uint256 public twoFillBorrows; // borrows filled by both staged bids
    uint256 public repayOk;
    uint256 public fullRepays;
    uint256 public reduceOk;
    uint256 public warpOk;
    uint256 public maturityWarpOk;
    uint256 public exactMaturityHits; // warps landing exactly on a maturity

    // ========== GHOSTS ==========

    /// @notice Proceeds delivered to the Box, scaled down by every repay and face reduction (rounded down)
    uint256[2] public outstandingProceeds;
    uint256 public timeDecreases;
    uint256 public discountIncreases;
    uint256 public borrowDebtMismatches;
    uint256 public borrowTotalAssetsMismatches;

    constructor(MidnightAccretionSystem memory s) {
        box = s.box;
        module = s.module;
        midnight = s.midnight;
        usdc = s.usdc;
        collateralOracle = s.collateralOracle;
        ratifier = s.ratifier;
        allocator = s.allocator;
        lender = s.lender;
        maxBorrowApr = s.maxBorrowApr;
        for (uint256 i; i < 2; i++) {
            fds[i] = s.fds[i];
            (markets[i], , ) = module.decodeFacilityData(s.fds[i]);
            ids[i] = module.marketId(s.fds[i]);
        }
    }

    // ========== ACTIONS ==========

    /// @dev Stages one or two bids at ticks at or above the APR floor and borrows a fuzzed amount the guard allows.
    ///      Checks (e): the facility's debt value rises by the proceeds the Box received, plus at most 1 wei per fill,
    ///      and Box totalAssets is unchanged within the same rounding.
    function borrow(uint256 facilitySeed, uint256 amount, uint256 tick0Seed, uint256 tick1Seed, uint256 capSeed) external {
        uint256 i = facilitySeed % 2;
        bytes memory fd = fds[i];
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ >= markets[i].maturity) revert Skipped();
        uint256 ttm = markets[i].maturity - now_;
        uint256 fee = midnight.settlementFee(ids[i], ttm);
        // Close to maturity with a fee, even the maximum tick can be below the floor
        if (_sellerPrice(TickLib.MAX_TICK, fee) < _minSellerPrice(ttm)) revert Skipped();
        uint256 floorStep = _floorStep(ttm, fee);
        uint256 tick0 = TICK_SPACING * _bound(tick0Seed, floorStep, MAX_STEP);
        uint256 price0 = _sellerPrice(tick0, fee);
        uint256 tick1 = TICK_SPACING * _bound(tick1Seed, floorStep, MAX_STEP);
        uint256 price1 = _sellerPrice(tick1, fee);

        // Two fills cost at most 2 units of rounding over amount / min(price)
        uint256 headroom = _guardUnits(i);
        uint256 face = midnight.debt(ids[i], address(module));
        if (headroom <= face + 2) revert Skipped();
        headroom -= face + 2;
        uint256 maxAmount = Math.mulDiv(headroom, Math.min(price0, price1), WAD);
        if (maxAmount == 0) revert Skipped();
        // Log-scaled: a seed-picked cap of maxAmount / 10^k keeps small (rounding-sensitive) amounts frequent and leaves
        // headroom for later borrows
        amount = _bound(amount / 6, 1, Math.max(1, maxAmount / 10 ** (amount % 6)));

        OfferFill[] memory fills = new OfferFill[](2);
        // A cap below the units the whole amount needs forces the second bid
        fills[0] = OfferFill(_bid(i, tick0), "", _bound(capSeed, 1, Math.mulDiv(amount, WAD, price0, Math.Rounding.Ceil)));
        fills[1] = OfferFill(_bid(i, tick1), "", type(uint256).max);
        usdc.mint(lender, headroom + 2);
        vm.prank(allocator);
        module.stageBorrow(fd, fills, now_ + 1 hours);

        uint256 debtValueBefore = module.debtValue(fd);
        uint256 totalAssetsBefore = box.totalAssets();
        uint256 boxBalanceBefore = usdc.balanceOf(address(box));
        uint256 takesBefore = midnight.takeCount();
        vm.prank(allocator);
        box.borrow(module, fd, usdc, amount);

        uint256 proceeds = usdc.balanceOf(address(box)) - boxBalanceBefore;
        uint256 takes = midnight.takeCount() - takesBefore;
        uint256 debtIncrease = module.debtValue(fd) - debtValueBefore;
        if (debtIncrease < proceeds || debtIncrease > proceeds + takes) borrowDebtMismatches++;
        uint256 totalAssetsAfter = box.totalAssets();
        if (totalAssetsAfter > totalAssetsBefore || totalAssetsAfter + takes < totalAssetsBefore) borrowTotalAssetsMismatches++;

        outstandingProceeds[i] += proceeds;
        borrowOk++;
        if (takes == 2) twoFillBorrows++;
    }

    /// @dev Face-value repay through the Box: a quarter of the calls repay type(uint256).max (the whole face). Checks (d):
    ///      the unearned discount does not increase.
    function repay(uint256 facilitySeed, uint256 amount) external {
        uint256 i = facilitySeed % 2;
        bytes memory fd = fds[i];
        uint256 face = module.debtBalance(fd, usdc);
        if (face == 0) revert Skipped();
        uint256 repaid;
        if (amount % 4 == 0) {
            amount = type(uint256).max;
            repaid = face;
        } else {
            amount = _bound(amount, 1, face);
            repaid = amount;
        }
        usdc.mint(address(box), repaid);
        uint256 discountBefore = face - module.debtValue(fd);
        vm.prank(allocator);
        box.repay(module, fd, usdc, amount);

        uint256 faceAfter = module.debtBalance(fd, usdc);
        if (faceAfter - module.debtValue(fd) > discountBefore) discountIncreases++;
        outstandingProceeds[i] = Math.mulDiv(outstandingProceeds[i], face - repaid, face);
        repayOk++;
        if (faceAfter == 0) fullRepays++;
    }

    /// @dev Midnight's face drops without the module (liquidation, bad-debt realisation). Checks (d) on the view that has
    ///      not synced yet.
    function reduceFace(uint256 facilitySeed, uint256 units) external {
        uint256 i = facilitySeed % 2;
        bytes memory fd = fds[i];
        uint256 face = midnight.debt(ids[i], address(module));
        if (face == 0) revert Skipped();
        units = _bound(units, 1, face);
        uint256 discountBefore = face - module.debtValue(fd);
        midnight.reduceDebt(ids[i], address(module), units);

        if (face - units - module.debtValue(fd) > discountBefore) discountIncreases++;
        outstandingProceeds[i] = Math.mulDiv(outstandingProceeds[i], face - units, face);
        reduceOk++;
    }

    function warp(uint256 elapsed) external {
        _warpTo(vm.getBlockTimestamp() + _bound(elapsed, 1, 5 days));
        warpOk++;
    }

    /// @dev Half of the calls land exactly on the maturity, the others up to 3 days past it. Only a facility with debt is
    ///      matured, and only once the sequence has borrowed a few times, so that runs do not jump past both maturities
    ///      (which ends borrowing) within their first calls.
    function warpToMaturity(uint256 facilitySeed, uint256 offset) external {
        uint256 i = facilitySeed % 2;
        uint256 target = markets[i].maturity + (offset % 2 == 0 ? 0 : _bound(offset, 1, 3 days));
        if (borrowOk < MATURITY_AFTER_BORROWS || target <= vm.getBlockTimestamp() || midnight.debt(ids[i], address(module)) == 0) {
            revert Skipped();
        }
        _warpTo(target);
        maturityWarpOk++;
    }

    // ========== VIEWS FOR THE INVARIANTS ==========

    function facilityData(uint256 index) external view returns (bytes memory) {
        return fds[index];
    }

    function maturityOf(uint256 index) external view returns (uint256) {
        return markets[index].maturity;
    }

    function marketIdOf(uint256 index) external view returns (bytes32) {
        return ids[index];
    }

    function successfulActions() external view returns (uint256) {
        return borrowOk + repayOk + reduceOk + warpOk + maturityWarpOk;
    }

    // ========== INTERNAL ==========

    /// @dev Checks (b): no facility's debt value decreases while only time passes
    function _warpTo(uint256 target) internal {
        uint256[2] memory before = [module.debtValue(fds[0]), module.debtValue(fds[1])];
        vm.warp(target);
        for (uint256 i; i < 2; i++) {
            if (module.debtValue(fds[i]) < before[i]) timeDecreases++;
            if (target == markets[i].maturity) exactMaturityHits++;
        }
    }

    /// @dev Largest face the module guard allows with the pledged collateral: floor(lltv * lltvCap * value / 1e36)
    function _guardUnits(uint256 i) internal view returns (uint256) {
        uint256 collateral = midnight.collateral(ids[i], address(module), 0);
        uint256 value = Math.mulDiv(collateral, collateralOracle.price(), ORACLE_SCALE);
        uint256 maxLtv = (markets[i].collateralParams[0].lltv * module.lltvCap()) / WAD;
        return Math.mulDiv(maxLtv, value, WAD);
    }

    function _bid(uint256 i, uint256 tick) internal returns (Offer memory o) {
        o.market = markets[i];
        o.buy = true;
        o.maker = lender;
        o.start = vm.getBlockTimestamp();
        o.expiry = markets[i].maturity;
        o.tick = tick;
        o.group = keccak256(abi.encode(i, nonce++));
        o.ratifier = ratifier;
        o.maxUnits = type(uint128).max;
        o.continuousFeeCap = type(uint256).max;
    }

    /// @dev Lowest seller price the module accepts: ceil(1e36 / (1e18 + floor(maxApr * ttm / 365 days)))
    function _minSellerPrice(uint256 ttm) internal view returns (uint256) {
        uint256 denominator = WAD + (maxBorrowApr * ttm) / YEAR;
        return (WAD * WAD + denominator - 1) / denominator;
    }

    function _sellerPrice(uint256 tick, uint256 fee) internal pure returns (uint256) {
        uint256 price = TickLib.tickToPrice(tick);
        return price > fee ? price - fee : 0;
    }

    /// @dev Smallest step k such that tick 4k clears the APR floor net of the fee (tick prices are non-decreasing)
    function _floorStep(uint256 ttm, uint256 fee) internal view returns (uint256 lo) {
        uint256 minPrice = _minSellerPrice(ttm);
        uint256 hi = MAX_STEP;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_sellerPrice(mid * TICK_SPACING, fee) >= minPrice) hi = mid;
            else lo = mid + 1;
        }
    }
}
