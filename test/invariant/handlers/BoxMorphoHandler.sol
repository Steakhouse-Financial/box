// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {OracleMock} from "@morpho-blue/mocks/OracleMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../../src/Box.sol";
import {FundingMorpho} from "../../../src/FundingMorpho.sol";
import {IBox} from "../../../src/interfaces/IBox.sol";
import {IOracleCallback} from "../../../src/interfaces/IFunding.sol";
import {ERC20MockDecimals} from "../../mocks/ERC20MockDecimals.sol";
import {MockOracle} from "../../mocks/MockOracle.sol";
import {MockSwapper} from "../../mocks/MockSwapper.sol";

/// @dev Contracts and roles of the Box + FundingMorpho invariant suite
struct BoxMorphoSystem {
    IBox box;
    FundingMorpho module;
    IMorpho morpho;
    ERC20MockDecimals usdc; // Box asset
    ERC20MockDecimals weth; // Box token priced by `wethOracle`
    MockOracle wethOracle;
    MockSwapper swapper;
    MarketParams[3] markets;
    address allocator;
    address guardian;
    address[3] feeders;
}

/// @notice Handler of the Box + FundingMorpho invariant suite, the only target contract of the campaign.
/// @dev Every action either performs its Box call successfully or reverts: a precondition that makes the action pointless
///      reverts `Skipped` and a failing Box call bubbles up, so forge's metrics (calls minus reverts) count the actions that
///      really executed. Success counters and violation ghosts are only written on successful paths, so they survive.
///      Violations are recorded, not asserted, because an assertion inside a handler would just be a discarded revert.
contract BoxMorphoHandler is Test {
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    error Skipped();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant MAX_SLIPPAGE_LIMIT = 0.01e18;
    /// @dev WETH price bounds in USDC units per WETH wei, 1e36 scale: 500 to 20,000 USDC per WETH
    uint256 internal constant MIN_WETH_PRICE = 500e24;
    uint256 internal constant MAX_WETH_PRICE = 20_000e24;
    /// @dev Actions required before a shutdown is accepted, so that most runs explore the normal regime first
    uint256 internal constant SHUTDOWN_AFTER = 16;

    IBox public immutable box;
    FundingMorpho public immutable module;
    IMorpho public immutable morpho;
    ERC20MockDecimals public immutable usdc;
    ERC20MockDecimals public immutable weth;
    MockOracle public immutable wethOracle;
    MockSwapper public immutable swapper;
    address public immutable allocator;
    address public immutable guardian;
    address public immutable stranger;
    uint256 internal immutable virtualShares;
    MarketParams[3] internal markets;
    address[3] internal feeders;

    // ========== SUCCESS COUNTERS ==========

    uint256 public depositOk;
    uint256 public withdrawOk;
    uint256 public redeemOk;
    uint256 public allocateOk;
    uint256 public deallocateOk;
    uint256 public pledgeOk;
    uint256 public borrowOk;
    uint256 public repayOk;
    uint256 public depledgeOk;
    uint256 public warpOk;
    uint256 public priceOk;
    uint256 public donateOk;
    uint256 public skimOk;
    uint256 public shutdownOk;
    uint256 public winddownActionOk; // actions performed by the role-less `stranger` during winddown

    // ========== GHOSTS ==========

    /// @notice Tokens donated to the module and not skimmed since
    mapping(address token => uint256) public donations;
    uint256 public navFailures;
    uint256 public ltvViolations;
    uint256 public sharePriceDecreases;
    uint256 public skimNavChanges;
    uint256 public skimFailures;

    constructor(BoxMorphoSystem memory s) {
        box = s.box;
        module = s.module;
        morpho = s.morpho;
        usdc = s.usdc;
        weth = s.weth;
        wethOracle = s.wethOracle;
        swapper = s.swapper;
        allocator = s.allocator;
        guardian = s.guardian;
        stranger = makeAddr("stranger");
        virtualShares = Box(payable(address(s.box))).virtualShares();
        for (uint256 i; i < 3; i++) {
            markets[i] = s.markets[i];
            feeders[i] = s.feeders[i];
        }
    }

    // ========== ERC-4626 ==========

    function deposit(uint256 actorSeed, uint256 assets) external {
        if (box.isShutdown()) revert Skipped();
        address feeder = feeders[actorSeed % 3];
        assets = _bound(assets, 1, 1_000_000e6);
        usdc.mint(feeder, assets);
        (uint256 totalAssetsBefore, uint256 supplyBefore) = (box.totalAssets(), box.totalSupply());
        vm.startPrank(feeder);
        usdc.approve(address(box), assets);
        box.deposit(assets, feeder);
        vm.stopPrank();
        _checkSharePrice(totalAssetsBefore, supplyBefore);
        depositOk++;
        _afterAction();
    }

    function withdraw(uint256 actorSeed, uint256 assets) external {
        address feeder = feeders[actorSeed % 3];
        uint256 maxAssets = box.maxWithdraw(feeder);
        if (maxAssets == 0) revert Skipped();
        assets = _bound(assets, 1, maxAssets);
        (uint256 totalAssetsBefore, uint256 supplyBefore) = (box.totalAssets(), box.totalSupply());
        vm.prank(feeder);
        box.withdraw(assets, feeder, feeder);
        _checkSharePrice(totalAssetsBefore, supplyBefore);
        withdrawOk++;
        _afterAction();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address feeder = feeders[actorSeed % 3];
        uint256 maxShares = box.maxRedeem(feeder);
        if (maxShares == 0) revert Skipped();
        shares = _bound(shares, 1, maxShares);
        (uint256 totalAssetsBefore, uint256 supplyBefore) = (box.totalAssets(), box.totalSupply());
        vm.prank(feeder);
        box.redeem(shares, feeder, feeder);
        _checkSharePrice(totalAssetsBefore, supplyBefore);
        redeemOk++;
        _afterAction();
    }

    // ========== SWAPS ==========

    /// @dev Buys WETH with the Box asset: the allocator in the normal regime, anyone during winddown while WETH is owed
    ///      (bounded by the Box's winddown cap)
    function allocate(uint256 assets) external {
        uint256 balance = usdc.balanceOf(address(box));
        address caller = allocator;
        uint256 upper = balance;
        if (box.isWinddown()) {
            caller = stranger;
            upper = Math.min(upper, _winddownMaxAllocation());
        }
        if (upper < 1e6) revert Skipped();
        assets = _bound(assets, 1e6, upper);
        vm.prank(caller);
        box.allocate(weth, assets, swapper, "");
        allocateOk++;
        if (caller == stranger) winddownActionOk++;
        _afterAction();
    }

    /// @dev Sells WETH for the Box asset: the allocator in the normal regime, anyone during winddown once no WETH is owed
    function deallocate(uint256 tokens) external {
        uint256 balance = weth.balanceOf(address(box));
        if (balance < 1e15) revert Skipped();
        tokens = _bound(tokens, 1e15, balance);
        address caller = box.isWinddown() ? stranger : allocator;
        vm.prank(caller);
        box.deallocate(weth, tokens, swapper, "");
        deallocateOk++;
        if (caller == stranger) winddownActionOk++;
        _afterAction();
    }

    // ========== FUNDING ==========

    function pledge(uint256 facilitySeed, uint256 amount) external {
        if (box.isWinddown()) revert Skipped();
        MarketParams memory mp = markets[facilitySeed % 3];
        uint256 balance = IERC20(mp.collateralToken).balanceOf(address(box));
        if (balance == 0) revert Skipped();
        amount = _bound(amount, 1, balance);
        vm.prank(allocator);
        box.pledge(module, abi.encode(mp), IERC20(mp.collateralToken), amount);
        pledgeOk++;
        _afterAction();
    }

    /// @dev Amounts range up to 10% beyond the room the guard leaves, so the guard boundary is crossed regularly: a borrow
    ///      that succeeds must leave the facility within the cap
    function borrow(uint256 facilitySeed, uint256 amount) external {
        if (box.isWinddown()) revert Skipped();
        MarketParams memory mp = markets[facilitySeed % 3];
        uint256 maxDebt = (_collateralValue(mp) * _maxLtv(mp)) / WAD;
        uint256 debt = morpho.expectedBorrowAssets(mp, address(module));
        if (maxDebt <= debt) revert Skipped();
        uint256 room = maxDebt - debt;
        (uint256 totalSupplyAssets, , uint256 totalBorrowAssets, ) = morpho.expectedMarketBalances(mp);
        uint256 upper = Math.min(room + room / 10 + 1, totalSupplyAssets - totalBorrowAssets);
        if (upper == 0) revert Skipped();
        amount = _bound(amount, 1, upper);
        bytes memory fd = abi.encode(mp);
        vm.prank(allocator);
        box.borrow(module, fd, IERC20(mp.loanToken), amount);
        _checkLtv(mp, fd);
        borrowOk++;
        _afterAction();
    }

    /// @dev A quarter of the calls repay type(uint256).max (capped at the debt by the Box) when the Box holds the debt
    function repay(uint256 facilitySeed, uint256 amount) external {
        MarketParams memory mp = markets[facilitySeed % 3];
        bytes memory fd = abi.encode(mp);
        IERC20 loanToken = IERC20(mp.loanToken);
        uint256 debt = module.debtBalance(fd, loanToken);
        uint256 balance = loanToken.balanceOf(address(box));
        if (debt == 0 || balance == 0) revert Skipped();
        if (amount % 4 == 0 && balance >= debt) amount = type(uint256).max;
        else amount = _bound(amount, 1, Math.min(debt, balance));
        address caller = _actionCaller();
        vm.prank(caller);
        box.repay(module, fd, loanToken, amount);
        repayOk++;
        if (caller == stranger) winddownActionOk++;
        _afterAction();
    }

    /// @dev Amounts range up to 10% beyond what the guard frees; a quarter of the calls use type(uint256).max
    function depledge(uint256 facilitySeed, uint256 amount) external {
        MarketParams memory mp = markets[facilitySeed % 3];
        bytes memory fd = abi.encode(mp);
        uint256 collateral = morpho.position(mp.id(), address(module)).collateral;
        if (collateral == 0) revert Skipped();
        if (amount % 4 == 0) {
            amount = type(uint256).max;
        } else {
            uint256 debt = morpho.expectedBorrowAssets(mp, address(module));
            uint256 price = OracleMock(mp.oracle).price();
            // Collateral the guard keeps: debt / (price * maxLtv), rounded up
            uint256 locked = debt == 0
                ? 0
                : Math.mulDiv(Math.mulDiv(debt, WAD, _maxLtv(mp), Math.Rounding.Ceil), ORACLE_SCALE, price, Math.Rounding.Ceil);
            uint256 free = collateral > locked ? collateral - locked : 0;
            amount = _bound(amount, 1, Math.min(collateral, free + free / 10 + 1));
        }
        address caller = _actionCaller();
        vm.prank(caller);
        box.depledge(module, fd, IERC20(mp.collateralToken), amount);
        _checkLtv(mp, fd);
        depledgeOk++;
        if (caller == stranger) winddownActionOk++;
        _afterAction();
    }

    // ========== ENVIRONMENT ==========

    /// @dev Time passes: Morpho interest accrues (IrmMock, APR = utilization) and the shutdown warmup elapses
    function warp(uint256 elapsed) external {
        elapsed = _bound(elapsed, 1 minutes, 2 days);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        warpOk++;
        _afterAction();
    }

    /// @dev Moves the WETH price by up to ±20%, consistently on the Box oracle (also used by the swapper) and on the three
    ///      Morpho market oracles. Only this action and `warp` may push a facility above its LTV cap.
    function movePrice(uint256 seed) external {
        uint256 current = wethOracle.price();
        uint256 lower = Math.max(MIN_WETH_PRICE, (current * 8) / 10);
        uint256 upper = Math.min(MAX_WETH_PRICE, (current * 12) / 10);
        uint256 price = _bound(seed, lower, upper);
        _setWethPrice(price);
        priceOk++;
        _afterAction();
    }

    /// @dev Sends a registered token straight to the module (not a position)
    function donate(bool toWeth, uint256 amount) external {
        ERC20MockDecimals token = toWeth ? weth : usdc;
        amount = _bound(amount, 1, toWeth ? 10e18 : 10_000e6);
        token.mint(address(module), amount);
        donations[address(token)] += amount;
        donateOk++;
        _afterAction();
    }

    /// @dev Skims a donated token back to the Box. A skim of a non-zero balance that reverts or changes nav is a
    ///      violation: donations are never part of nav.
    function skim(bool ofWeth) external {
        ERC20MockDecimals token = ofWeth ? weth : usdc;
        if (token.balanceOf(address(module)) == 0) revert Skipped();
        address caller = _actionCaller();
        uint256 navBefore = module.nav(IOracleCallback(address(box)));
        vm.prank(caller);
        try box.skimFunding(module, token) {
            if (module.nav(IOracleCallback(address(box))) != navBefore) skimNavChanges++;
            donations[address(token)] = 0;
            skimOk++;
            if (caller == stranger) winddownActionOk++;
        } catch {
            skimFailures++;
        }
        _afterAction();
    }

    /// @dev The guardian shuts the Box down (winddown starts after the warmup) once enough actions ran in this sequence
    function shutdown() external {
        if (box.isShutdown() || _successfulActions() < SHUTDOWN_AFTER) revert Skipped();
        vm.prank(guardian);
        box.shutdown();
        shutdownOk++;
        _afterAction();
    }

    // ========== VIEWS FOR THE INVARIANTS ==========

    function market(uint256 index) external view returns (MarketParams memory) {
        return markets[index];
    }

    function successfulActions() external view returns (uint256) {
        return _successfulActions();
    }

    // ========== INTERNAL ==========

    function _successfulActions() internal view returns (uint256) {
        return
            depositOk +
            withdrawOk +
            redeemOk +
            allocateOk +
            deallocateOk +
            pledgeOk +
            borrowOk +
            repayOk +
            depledgeOk +
            warpOk +
            priceOk +
            donateOk +
            skimOk +
            shutdownOk;
    }

    /// @dev The allocator in the normal regime; the role-less stranger during winddown, when anyone may act
    function _actionCaller() internal view returns (address) {
        return box.isWinddown() ? stranger : allocator;
    }

    function _maxLtv(MarketParams memory mp) internal view returns (uint256) {
        return (mp.lltv * module.lltvCap()) / WAD;
    }

    /// @dev Collateral value in loan-token units at the Morpho market price, rounded down
    function _collateralValue(MarketParams memory mp) internal view returns (uint256) {
        uint256 collateral = morpho.position(mp.id(), address(module)).collateral;
        return Math.mulDiv(collateral, OracleMock(mp.oracle).price(), ORACLE_SCALE);
    }

    function _setWethPrice(uint256 price) internal {
        wethOracle.setPrice(price);
        for (uint256 i; i < 3; i++) {
            MarketParams memory mp = markets[i];
            // Morpho price of one collateral unit in loan-token units: WETH-collateral markets use the WETH price, the
            // USDC-collateral market its inverse
            uint256 morphoPrice = mp.collateralToken == address(weth) ? price : Math.mulDiv(ORACLE_SCALE, ORACLE_SCALE, price);
            OracleMock(mp.oracle).setPrice(morphoPrice);
        }
    }

    /// @dev Box's winddown cap on an allocation of WETH: the debt shortfall valued at the oracle, grossed up by the current
    ///      winddown slippage tolerance
    function _winddownMaxAllocation() internal view returns (uint256) {
        uint256 debt = module.debtBalance(weth);
        if (debt == 0) return 0;
        uint256 balance = weth.balanceOf(address(box));
        uint256 needed = debt > balance ? debt - balance : 0;
        uint256 neededValue = Math.mulDiv(needed, wethOracle.price(), ORACLE_SCALE, Math.Rounding.Ceil);
        uint256 elapsed = vm.getBlockTimestamp() - box.shutdownWarmup() - box.shutdownTime();
        uint256 duration = box.shutdownSlippageDuration();
        uint256 tolerance = elapsed < duration ? Math.mulDiv(elapsed, MAX_SLIPPAGE_LIMIT, duration) : MAX_SLIPPAGE_LIMIT;
        return Math.mulDiv(neededValue, WAD, WAD - tolerance, Math.Rounding.Ceil);
    }

    /// @dev Share price (TA + 1) / (S + V) must not decrease: (TA' + 1) * (S + V) >= (TA + 1) * (S' + V)
    function _checkSharePrice(uint256 totalAssetsBefore, uint256 supplyBefore) internal {
        uint256 lhs = Math.mulDiv(box.totalAssets() + 1, supplyBefore + virtualShares, box.totalSupply() + virtualShares);
        if (lhs < totalAssetsBefore + 1) sharePriceDecreases++;
    }

    function _checkLtv(MarketParams memory mp, bytes memory fd) internal {
        if (module.ltv(fd) > _maxLtv(mp)) ltvViolations++;
    }

    /// @dev Liveness of the two nav entry points after every action
    function _afterAction() internal {
        try box.totalAssets() returns (uint256) {} catch {
            navFailures++;
        }
        try module.nav(IOracleCallback(address(box))) returns (uint256) {} catch {
            navFailures++;
        }
    }
}
