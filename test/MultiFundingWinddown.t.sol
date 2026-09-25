// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IrmMock} from "@morpho-blue/mocks/IrmMock.sol";
import {OracleMock} from "@morpho-blue/mocks/OracleMock.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingAave, IPool} from "../src/FundingAave.sol";
import {FundingAaveV4} from "../src/FundingAaveV4.sol";
import {FundingEuler} from "../src/FundingEuler.sol";
import {FundingMidnight, OfferFill} from "../src/FundingMidnight.sol";
import {FundingMorpho} from "../src/FundingMorpho.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {IFunding, IOracleCallback} from "../src/interfaces/IFunding.sol";
import {CollateralParams, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockAaveV3Pool} from "./mocks/MockAaveV3Pool.sol";
import {MockAaveV4Spoke} from "./mocks/MockAaveV4Spoke.sol";
import {MockEVault, MockEulerRouter} from "./mocks/MockEVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockMidnight} from "./mocks/MockMidnight.sol";
import {MockMidnightRatifier} from "./mocks/MockMidnightRatifier.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice One real Box with all five funding module types attached, each with an open position: FundingMorpho on a
/// local Morpho Blue, FundingAave on MockAaveV3Pool, FundingAaveV4 on MockAaveV4Spoke, FundingMidnight on MockMidnight
/// and FundingEuler on MockEVC/MockEVault. The Box also holds a token T that no module knows. After shutdown, an address
/// with no role must be able to exit everything.
/// @dev All positions pledge WBTC; Morpho and Midnight borrow USDC (the Box asset), the three others borrow WETH (a Box
///      token), so that winddown needs an allocation of the outstanding debt token.
contract MultiFundingWinddownTest is Test {
    using BoxLib for IBox;

    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_SLIPPAGE_LIMIT = 0.01e18;
    address internal constant USD = address(840);
    uint256 internal constant WBTC_PRICE = 600_000_000_000_000_000_000_000_000_000_000_000_003; // 60,000 USDC, odd
    uint256 internal constant WETH_PRICE = 3_000_000_000_000_000_000_000_000_001; // 3,000 USDC, odd
    uint256 internal constant T_PRICE = 50_000_000_000_000_000_000_000_000_000_001; // 5 USDC per T (8 decimals), odd
    uint256 internal constant MIDNIGHT_TICK = 4212; // price 0.9850729, below 20% a year over 90 days
    uint256 internal constant PLEDGED = 5e8; // 5 WBTC per module

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal feeder = makeAddr("feeder");
    address internal lender = makeAddr("lender");
    address internal nobody = makeAddr("nobody");

    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal wbtc;
    ERC20MockDecimals internal weth;
    ERC20MockDecimals internal tToken;
    MockOracle internal wethOracle;
    MockSwapper internal swapper;
    IBox internal box;

    MockAaveV3Pool internal aavePool;
    MockMidnightRatifier internal midnightRatifier;
    IFunding[5] internal modules;
    bytes[5] internal fds;
    IERC20[5] internal debtTokens;
    string[5] internal names = ["FundingMorpho", "FundingAave", "FundingAaveV4", "FundingMidnight", "FundingEuler"];

    function setUp() public {
        usdc = new ERC20MockDecimals(6);
        wbtc = new ERC20MockDecimals(8);
        weth = new ERC20MockDecimals(18);
        tToken = new ERC20MockDecimals(8);
        wethOracle = new MockOracle(WETH_PRICE);
        MockOracle wbtcOracle = new MockOracle(WBTC_PRICE);
        MockOracle tOracle = new MockOracle(T_PRICE);

        box = IBox(address(new Box(address(usdc), boxOwner, curator, "Box Five Modules", "BOX5", 0.01 ether, 7 days, 10 days, 1 days)));
        _deployMorpho();
        _deployAave();
        _deployAaveV4();
        _deployMidnight();
        _deployEuler();

        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.setGuardianInstant(guardian);
        box.addFeederInstant(feeder);
        box.addTokenInstant(wbtc, wbtcOracle);
        box.addTokenInstant(weth, wethOracle);
        box.addTokenInstant(tToken, tOracle);
        for (uint256 i; i < 5; i++) {
            box.addFundingInstant(modules[i]);
            box.addFundingCollateralInstant(modules[i], wbtc);
            box.addFundingDebtInstant(modules[i], debtTokens[i]);
            box.addFundingFacilityInstant(modules[i], fds[i]);
        }
        vm.stopPrank();

        swapper = new MockSwapper();
        swapper.setOracle(usdc, new MockOracle(ORACLE_SCALE));
        swapper.setOracle(wbtc, wbtcOracle);
        swapper.setOracle(weth, wethOracle);
        swapper.setOracle(tToken, tOracle);
        usdc.mint(address(swapper), 1e30);
        weth.mint(address(swapper), 1e30);

        usdc.mint(feeder, 10_000_000e6);
        vm.startPrank(feeder);
        usdc.approve(address(box), 10_000_000e6);
        box.deposit(10_000_000e6, feeder);
        vm.stopPrank();
        wbtc.mint(address(box), 5 * PLEDGED);
        tToken.mint(address(box), 1_000e8);

        vm.startPrank(allocator);
        for (uint256 i; i < 5; i++) {
            box.pledge(modules[i], fds[i], wbtc, PLEDGED);
            if (i == 3) _stageMidnight();
            box.borrow(modules[i], fds[i], debtTokens[i], debtTokens[i] == usdc ? 100_000e6 : 30e18);
        }
        vm.stopPrank();
    }

    function testWinddownExitWithEveryModuleType() public {
        for (uint256 i; i < 5; i++) {
            assertGt(modules[i].debtBalance(fds[i], debtTokens[i]), 0, string.concat(names[i], " has open debt"));
        }
        assertEq(box.totalAssets(), _independentTotalAssets(), "totalAssets = asset + floored token values + five navs");

        // The allocator sells every WETH, so repaying the WETH debts in winddown needs an allocation; interest accrues
        vm.startPrank(allocator);
        box.deallocate(weth, weth.balanceOf(address(box)), swapper, "");
        vm.stopPrank();
        aavePool.accrueDebt(address(modules[1]), address(weth), 0.05e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        vm.prank(guardian);
        box.shutdown();
        vm.warp(vm.getBlockTimestamp() + box.shutdownWarmup() + 5 days);
        assertTrue(box.isWinddown(), "winddown");
        _assertTotalAssetsLive("at winddown start");

        // T is unknown to every module: every view returns 0 and anyone can sell it
        for (uint256 i; i < 5; i++) {
            assertEq(modules[i].debtBalance(tToken), 0, string.concat(names[i], " debtBalance(T)"));
            assertEq(modules[i].collateralBalance(tToken), 0, string.concat(names[i], " collateralBalance(T)"));
        }
        uint256 tBalance = tToken.balanceOf(address(box));
        uint256 usdcBefore = usdc.balanceOf(address(box));
        vm.prank(nobody);
        box.deallocate(tToken, tBalance, swapper, "");
        assertEq(tToken.balanceOf(address(box)), 0, "T sold");
        assertEq(usdc.balanceOf(address(box)) - usdcBefore, Math.mulDiv(tBalance, T_PRICE, ORACLE_SCALE), "T sold at the oracle");
        _assertTotalAssetsLive("after selling T");

        // Anyone may buy the outstanding debt token, up to the winddown cap
        uint256 wethDebt = modules[1].debtBalance(weth) + modules[2].debtBalance(weth) + modules[4].debtBalance(weth);
        assertEq(_boxDebtBalance(weth), wethDebt, "only the three WETH borrowers report WETH debt");
        uint256 cap = _winddownMaxAllocation(wethDebt);
        vm.startPrank(nobody);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        box.allocate(weth, cap + 1, swapper, "");
        box.allocate(weth, cap, swapper, "");
        vm.stopPrank();
        assertGe(weth.balanceOf(address(box)), wethDebt, "the allocation covers the WETH debt");
        _assertTotalAssetsLive("after the allocation");

        // Anyone repays every debt in full, then withdraws every collateral
        for (uint256 i; i < 5; i++) {
            vm.startPrank(nobody);
            box.repay(modules[i], fds[i], debtTokens[i], type(uint256).max);
            box.depledge(modules[i], fds[i], wbtc, type(uint256).max);
            vm.stopPrank();
            assertEq(modules[i].debtBalance(fds[i], debtTokens[i]), 0, string.concat(names[i], " debt closed"));
            assertEq(modules[i].collateralBalance(fds[i], wbtc), 0, string.concat(names[i], " collateral withdrawn"));
            assertEq(modules[i].nav(IOracleCallback(address(box))), 0, string.concat(names[i], " nav"));
            _assertTotalAssetsLive(names[i]);
        }
        assertEq(wbtc.balanceOf(address(box)), 5 * PLEDGED, "all the collateral is back in the Box");
        assertEq(_boxDebtBalance(weth), 0, "no WETH debt left");
        assertEq(_boxDebtBalance(usdc), 0, "no USDC debt left");
        assertEq(box.totalAssets(), _independentTotalAssets(), "totalAssets = idle holdings once every module is empty");
    }

    // ========== MODULE DEPLOYMENTS ==========

    function _deployMorpho() internal {
        IMorpho morpho = IMorpho(address(new Morpho(address(this))));
        address irm = address(new IrmMock());
        morpho.enableIrm(irm);
        morpho.enableLltv(0.86e18);
        OracleMock oracle = new OracleMock();
        oracle.setPrice(WBTC_PRICE);
        MarketParams memory mp = MarketParams(address(usdc), address(wbtc), address(oracle), irm, 0.86e18);
        morpho.createMarket(mp);
        usdc.mint(lender, 10_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(morpho), 10_000_000e6);
        morpho.supply(mp, 10_000_000e6, 0, lender, "");
        vm.stopPrank();

        modules[0] = new FundingMorpho(address(box), address(morpho), 0.9e18);
        fds[0] = abi.encode(mp);
        debtTokens[0] = usdc;
    }

    function _deployAave() internal {
        aavePool = new MockAaveV3Pool();
        aavePool.listReserve(address(usdc), 1e8);
        aavePool.listReserve(address(wbtc), 60_000e8);
        aavePool.listReserve(address(weth), 3_000e8);
        weth.mint(address(aavePool), 10_000e18);

        modules[1] = new FundingAave(address(box), IPool(address(aavePool)), 0, 0.9e18);
        fds[1] = "";
        debtTokens[1] = weth;
    }

    function _deployAaveV4() internal {
        MockAaveV4Spoke spoke = new MockAaveV4Spoke();
        uint256[] memory reserveIds = new uint256[](2);
        reserveIds[0] = spoke.addReserve(address(wbtc), 8, 8000, false);
        reserveIds[1] = spoke.addReserve(address(weth), 18, 0, true);
        spoke.setPrice(reserveIds[0], 60_000e8);
        spoke.setPrice(reserveIds[1], 3_000e8);
        weth.mint(address(spoke), 10_000e18);

        modules[2] = new FundingAaveV4(address(box), address(spoke), reserveIds, 0.9e18);
        fds[2] = "";
        debtTokens[2] = weth;
    }

    function _deployMidnight() internal {
        MockMidnight midnight = new MockMidnight();
        midnightRatifier = new MockMidnightRatifier();
        midnightRatifier.setAcceptAll(true);
        Market memory market;
        market.chainId = block.chainid;
        market.midnight = address(midnight);
        market.loanToken = address(usdc);
        market.collateralParams = new CollateralParams[](1);
        market.collateralParams[0] = CollateralParams(address(wbtc), 0.86e18, 0.3e18, address(new MockOracle(WBTC_PRICE)));
        market.maturity = vm.getBlockTimestamp() + 90 days;
        market.rcfThreshold = 3000e6;
        midnight.touchMarket(market);

        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        midnight.setIsAuthorized(address(midnightRatifier), true, lender);
        usdc.approve(address(midnight), type(uint256).max);
        vm.stopPrank();

        modules[3] = new FundingMidnight(address(box), address(midnight), 0.9e18);
        fds[3] = abi.encode(market, uint256(0), uint256(0.2e18));
        debtTokens[3] = usdc;
    }

    function _deployEuler() internal {
        MockEVC evc = new MockEVC();
        MockEulerRouter router = new MockEulerRouter();
        MockEVault collateralVault = new MockEVault(address(evc), address(wbtc), address(router), USD);
        MockEVault borrowVault = new MockEVault(address(evc), address(weth), address(router), USD);
        borrowVault.setLTV(address(collateralVault), 8100, 8300);
        router.setResolvedVault(address(collateralVault), true);
        router.setPrice(address(wbtc), USD, 6e32); // 1 WBTC unit = 6e14 USD wei
        router.setPrice(address(weth), USD, 3_000e18);
        weth.mint(lender, 10_000e18);
        vm.startPrank(lender);
        weth.approve(address(borrowVault), 10_000e18);
        borrowVault.deposit(10_000e18, lender);
        vm.stopPrank();

        modules[4] = new FundingEuler(address(box), address(evc), 0.95e18);
        fds[4] = abi.encode(address(collateralVault), address(borrowVault));
        debtTokens[4] = weth;
    }

    /// @dev Stages one uncapped lender bid at MIDNIGHT_TICK for the Midnight facility (called while pranking the allocator)
    function _stageMidnight() internal {
        (Market memory market, , ) = abi.decode(fds[3], (Market, uint256, uint256));
        Offer memory offer;
        offer.market = market;
        offer.buy = true;
        offer.maker = lender;
        offer.start = vm.getBlockTimestamp();
        offer.expiry = market.maturity;
        offer.tick = MIDNIGHT_TICK;
        offer.ratifier = address(midnightRatifier);
        offer.maxUnits = type(uint128).max;
        offer.continuousFeeCap = type(uint256).max;
        OfferFill[] memory fills = new OfferFill[](1);
        fills[0] = OfferFill(offer, "", type(uint256).max);
        FundingMidnight(payable(address(modules[3]))).stageBorrow(fds[3], fills, vm.getBlockTimestamp() + 1 hours);
    }

    // ========== HELPERS ==========

    function _independentTotalAssets() internal view returns (uint256 expected) {
        expected = usdc.balanceOf(address(box));
        IERC20[3] memory tokens = [IERC20(address(wbtc)), IERC20(address(weth)), IERC20(address(tToken))];
        for (uint256 i; i < 3; i++) {
            expected += Math.mulDiv(tokens[i].balanceOf(address(box)), box.oracles(tokens[i]).price(), ORACLE_SCALE);
        }
        for (uint256 i; i < 5; i++) {
            expected += modules[i].nav(IOracleCallback(address(box)));
        }
    }

    function _assertTotalAssetsLive(string memory step) internal view {
        try box.totalAssets() returns (uint256) {} catch {
            assertTrue(false, string.concat("totalAssets reverts ", step));
        }
    }

    function _boxDebtBalance(IERC20 token) internal view returns (uint256 total) {
        for (uint256 i; i < 5; i++) {
            total += modules[i].debtBalance(token);
        }
    }

    /// @dev Box's winddown cap on an allocation: the debt shortfall at the oracle, grossed up by the winddown tolerance
    function _winddownMaxAllocation(uint256 debt) internal view returns (uint256) {
        uint256 balance = weth.balanceOf(address(box));
        uint256 needed = debt > balance ? debt - balance : 0;
        uint256 neededValue = Math.mulDiv(needed, WETH_PRICE, ORACLE_SCALE, Math.Rounding.Ceil);
        uint256 elapsed = vm.getBlockTimestamp() - box.shutdownWarmup() - box.shutdownTime();
        uint256 duration = box.shutdownSlippageDuration();
        uint256 tolerance = elapsed < duration ? Math.mulDiv(elapsed, MAX_SLIPPAGE_LIMIT, duration) : MAX_SLIPPAGE_LIMIT;
        return Math.mulDiv(neededValue, WAD, WAD - tolerance, Math.Rounding.Ceil);
    }
}
