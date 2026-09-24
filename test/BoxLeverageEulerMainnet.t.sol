// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {FundingEuler} from "../src/FundingEuler.sol";
import {FundingEulerFactory} from "../src/factories/FundingEulerFactory.sol";
import {IEVault} from "../src/interfaces/euler/IEVault.sol";
import {IEVC} from "../src/interfaces/euler/IEVC.sol";
import {IPriceOracle} from "../src/interfaces/euler/IPriceOracle.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {EulerForkTest, IEVCTest} from "./helpers/EulerForkTest.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/**
 * @title Box + FundingEuler against the real Euler v2 deployment on Ethereum
 * @dev Markets: ewstETH-2 collateral against eWETH-2 (LTVBorrow 93%) and eUSDC-2 (81%), esUSDe-4 collateral against
 *      eUSDC-2 (90%). The Euler ETH/USD feed has about 94 minutes of staleness budget left at the fork block, so every
 *      path that reads Euler prices (borrow, depledge with debt, ltv with debt) warps at most 1 hour; the stale-feed
 *      scenario only repays and depledges once the debt is gone. The winddown Box has no shutdown warmup.
 */
contract BoxLeverageEulerMainnetTest is EulerForkTest {
    using BoxLib for Box;

    uint256 internal constant FORK_BLOCK = 23_294_087;
    uint256 internal constant LTV_CAP = 0.95e18;
    uint256 internal constant WSTETH_WETH_CAP = 0.8835e18; // 9300 x 1e14 x 0.95

    IERC20 internal constant WETH = IERC20(ETHEREUM_WETH);
    IERC20 internal constant WSTETH = IERC20(ETHEREUM_WSTETH);
    IERC20 internal constant USDC = IERC20(ETHEREUM_USDC);
    IERC20 internal constant SUSDE = IERC20(ETHEREUM_SUSDE);

    IOracle internal wstethOracle = IOracle(ETHEREUM_WSTETH_WETH_ORACLE);

    Box internal box;
    FundingEuler internal module;
    bytes internal fdWeth;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        evc = ETHEREUM_EVC;
        factory = new FundingEulerFactory();

        box = _newBox(WETH, WSTETH, wstethOracle, MAX_SHUTDOWN_WARMUP);
        (module, fdWeth) = _newModule(box, LTV_CAP, ETHEREUM_EWSTETH_2, ETHEREUM_EWETH_2);
        _deposit(box, 100e18);
    }

    // ========== LEVERAGE LOOP ==========

    function testLeverageLoopRespectsEulerAndModuleCaps() public {
        MockSwapper swapper = _newSwapper();
        deal(address(WSTETH), address(box), 100e18);
        uint256 navBefore = box.totalAssets();
        assertEq(_guardCap(module, fdWeth), WSTETH_WETH_CAP, "guard cap 0.93 x 0.95");

        vm.prank(allocator);
        box.pledge(module, fdWeth, WSTETH, 100e18);
        assertApproxEqAbs(module.collateralBalance(fdWeth, WSTETH), 100e18, 2, "collateral = pledged within 2 wei");

        uint256 capacity = _capacity(module, fdWeth);
        console2.log("Euler borrow capacity", capacity);
        uint256 tooMuchForEuler = (capacity * 101) / 100;
        uint256 tooMuchForModule = (capacity * 97) / 100;

        vm.prank(allocator);
        vm.expectRevert(E_ACCOUNT_LIQUIDITY);
        box.borrow(module, fdWeth, WETH, tooMuchForEuler);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, fdWeth, WETH, tooMuchForModule);
        assertEq(module.debtBalance(fdWeth, WETH), 0, "reverted borrows left no debt");

        uint256 step = (capacity * 90) / 100;
        uint256 wethBefore = WETH.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, fdWeth, WETH, step);
        assertEq(WETH.balanceOf(address(box)) - wethBefore, step, "Box received exactly the borrowed WETH");
        uint256 ltv = module.ltv(fdWeth);
        console2.log("ltv after first borrow", ltv);
        assertApproxEqRel(ltv, 0.837e18, 1e14, "ltv = 90% x 0.93 within 0.01%");

        for (uint256 i = 0; i < 2; i++) {
            vm.startPrank(allocator);
            uint256 wstethBefore = WSTETH.balanceOf(address(box));
            box.allocate(WSTETH, step, ISwapper(address(swapper)), "");
            uint256 bought = WSTETH.balanceOf(address(box)) - wstethBefore;
            box.pledge(module, fdWeth, WSTETH, bought);
            vm.stopPrank();

            step = (_capacity(module, fdWeth) * 90) / 100 - module.debtBalance(fdWeth, WETH);
            wethBefore = WETH.balanceOf(address(box));
            vm.prank(allocator);
            box.borrow(module, fdWeth, WETH, step);
            assertEq(WETH.balanceOf(address(box)) - wethBefore, step, "loop borrow delivered exactly");

            ltv = module.ltv(fdWeth);
            console2.log("iteration", i + 2);
            console2.log("  collateral ", module.collateralBalance(fdWeth, WSTETH));
            console2.log("  debt       ", module.debtBalance(fdWeth, WETH));
            console2.log("  ltv        ", ltv);
            assertLe(ltv, WSTETH_WETH_CAP, "ltv within the module cap after every borrow");
            assertLt(ltv, _borrowLtv(fdWeth), "ltv within Euler's borrow LTV");
        }

        uint256 navAfter = box.totalAssets();
        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "loop keeps totalAssets within 0.1%");
        assertEq(module.nav(IOracleCallback(address(box))), _expectedNav(box, module), "nav = Box-oracle formula");
    }

    // ========== CARRY ==========

    function testSusdeUsdcCarryOpensAndClosesExactly() public {
        Box usdcBox = _newBox(USDC, SUSDE, IOracle(ETHEREUM_SUSDE_USDC_ORACLE), MAX_SHUTDOWN_WARMUP);
        (FundingEuler carry, bytes memory fd) = _newModule(usdcBox, LTV_CAP, ETHEREUM_ESUSDE_4, ETHEREUM_EUSDC_2);
        deal(address(SUSDE), address(usdcBox), 100_000e18);

        vm.prank(allocator);
        usdcBox.pledge(carry, fd, SUSDE, 100_000e18);
        assertEq(carry.collateralBalance(fd, SUSDE), 100_000e18, "escrow vault: collateral = pledged exactly");

        uint256 usdcBefore = USDC.balanceOf(address(usdcBox));
        vm.prank(allocator);
        usdcBox.borrow(carry, fd, USDC, 90_000e6);
        assertEq(USDC.balanceOf(address(usdcBox)) - usdcBefore, 90_000e6, "Box received exactly 90,000 USDC");
        assertEq(carry.debtBalance(fd, USDC), 90_000e6, "debt = borrowed in the same block");

        uint256 ltv = carry.ltv(fd);
        uint256 nav = carry.nav(IOracleCallback(address(usdcBox)));
        console2.log("ltv", ltv);
        console2.log("nav", nav);
        assertApproxEqRel(ltv, 0.7527e18, 0.001e18, "ltv around 0.7527");
        assertEq(nav, _expectedNav(usdcBox, carry), "nav = Box-oracle formula");
        assertApproxEqRel(nav, 29_455.06e6, 0.0001e18, "nav around 29,455.06 USDC");

        usdcBefore = USDC.balanceOf(address(usdcBox));
        vm.prank(allocator);
        usdcBox.repay(carry, fd, USDC, type(uint256).max);
        assertEq(usdcBefore - USDC.balanceOf(address(usdcBox)), 90_000e6, "Box paid exactly the debt");
        assertEq(_debt(carry, fd), 0, "no Euler debt left");
        assertEq(_controllers(carry, fd).length, 0, "controller released");

        uint256 susdeBefore = SUSDE.balanceOf(address(usdcBox));
        vm.prank(allocator);
        usdcBox.depledge(carry, fd, SUSDE, type(uint256).max);
        assertEq(SUSDE.balanceOf(address(usdcBox)) - susdeBefore, 100_000e18, "all sUSDe back in the Box");
        assertEq(_shares(carry, fd), 0, "no shares left");

        vm.prank(curator);
        usdcBox.removeFundingFacility(carry, fd);
        assertFalse(carry.isFacility(fd), "facility removed");
        assertEq(_collaterals(carry, fd).length, 0, "collateral disabled on the EVC");
    }

    // ========== ACCRUAL AND STALE FEEDS ==========

    function testInterestAccruesWithinFeedBudget() public {
        _open(10e18, 5e18);
        uint256 collateralBefore = module.collateralBalance(fdWeth, WSTETH);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(block.number + 300);

        uint256 debt = module.debtBalance(fdWeth, WETH);
        console2.log("debt after 1 hour", debt);
        assertGt(debt, 5e18, "interest accrued");
        assertEq(module.debtBalance(WETH), debt, "token debt = facility debt");
        assertGe(module.collateralBalance(fdWeth, WSTETH), collateralBefore, "lending collateral does not shrink");
        assertEq(module.nav(IOracleCallback(address(box))), _expectedNav(box, module), "nav = Box-oracle formula");
        assertGt(box.totalAssets(), 0, "totalAssets readable");
        uint256 ltv = module.ltv(fdWeth);
        assertGt(ltv, 0, "ltv readable with fresh enough feeds");
        assertLe(ltv, WSTETH_WETH_CAP, "ltv within the cap");

        uint256 wethBefore = WETH.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, fdWeth, WETH, 0.001e18);
        assertEq(WETH.balanceOf(address(box)) - wethBefore, 0.001e18, "borrow still works after 1 hour");
        assertApproxEqAbs(module.debtBalance(fdWeth, WETH), debt + 0.001e18, 1, "debt grew by the borrow (1 wei rounding)");
    }

    function testFullCloseAndRemovalWithStaleFeeds() public {
        _open(10e18, 5e18);
        address account = module.subAccount(fdWeth);
        uint256 moduleWethBefore = WETH.balanceOf(address(module));

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.roll(block.number + 216_000);

        vm.prank(allocator);
        vm.expectPartialRevert(PRICE_ORACLE_TOO_STALE);
        box.borrow(module, fdWeth, WETH, 0.001e18);

        uint256 debt = module.debtBalance(fdWeth, WETH);
        console2.log("debt after 30 days", debt);
        assertGt(debt, 5e18, "interest accrued");
        deal(address(WETH), address(box), WETH.balanceOf(address(box)) + 1e18);

        uint256 wethBefore = WETH.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fdWeth, WETH, type(uint256).max);
        assertEq(wethBefore - WETH.balanceOf(address(box)), debt, "Box paid exactly the prior debt");
        assertEq(IEVault(ETHEREUM_EWETH_2).debtOf(account), 0, "no Euler debt left");
        assertEq(IEVCTest(evc).getControllers(account).length, 0, "controller released");
        assertEq(WETH.balanceOf(address(module)), moduleWethBefore, "module keeps no WETH");

        uint256 collateral = module.collateralBalance(fdWeth, WSTETH);
        uint256 wstethBefore = WSTETH.balanceOf(address(box));
        vm.prank(allocator);
        box.depledge(module, fdWeth, WSTETH, type(uint256).max);
        assertEq(WSTETH.balanceOf(address(box)) - wstethBefore, collateral, "Box received exactly the prior collateral");
        assertEq(IEVault(ETHEREUM_EWSTETH_2).balanceOf(account), 0, "no shares left");

        vm.startPrank(curator);
        box.removeFundingFacility(module, fdWeth);
        box.removeFundingCollateral(module, WSTETH);
        box.removeFundingDebt(module, WETH);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
        assertEq(IEVCTest(evc).getCollaterals(account).length, 0, "collateral disabled on the EVC");
        assertEq(IEVCTest(evc).getControllers(account).length, 0, "no controller on the EVC");
    }

    // ========== GUARD ==========

    function testDepledgeBreachingLtvReverts() public {
        deal(address(WSTETH), address(box), 10e18);
        vm.prank(allocator);
        box.pledge(module, fdWeth, WSTETH, 10e18);
        uint256 borrowAmount = (_capacity(module, fdWeth) * 90) / 100;
        vm.prank(allocator);
        box.borrow(module, fdWeth, WETH, borrowAmount);
        console2.log("ltv at 90% of capacity", module.ltv(fdWeth));

        vm.prank(allocator);
        vm.expectRevert(E_ACCOUNT_LIQUIDITY);
        box.depledge(module, fdWeth, WSTETH, 5e18);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, fdWeth, WSTETH, 0.6e18);

        uint256 wstethBefore = WSTETH.balanceOf(address(box));
        vm.prank(allocator);
        box.depledge(module, fdWeth, WSTETH, 0.1e18);
        assertEq(WSTETH.balanceOf(address(box)) - wstethBefore, 0.1e18, "Box received exactly 0.1 wstETH");
        assertLe(module.ltv(fdWeth), WSTETH_WETH_CAP, "ltv within the cap after the allowed depledge");

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingFacility(module, fdWeth);
    }

    // ========== TWO FACILITIES ON ONE COLLATERAL VAULT ==========

    function testTwoFacilitiesShareCollateralVaultOnSeparateSubAccounts() public {
        MockOracle usdcOracle = new MockOracle(_usdcPriceInWeth());
        bytes memory fdUsdc = abi.encode(ETHEREUM_EWSTETH_2, ETHEREUM_EUSDC_2);
        vm.startPrank(curator);
        box.addTokenInstant(USDC, usdcOracle);
        box.addFundingDebtInstant(module, USDC);
        box.addFundingFacilityInstant(module, fdUsdc);
        vm.stopPrank();
        deal(address(WSTETH), address(box), 20e18);

        vm.startPrank(allocator);
        box.pledge(module, fdWeth, WSTETH, 10e18);
        box.pledge(module, fdUsdc, WSTETH, 10e18);
        box.borrow(module, fdWeth, WETH, 4e18);
        box.borrow(module, fdUsdc, USDC, 10_000e6);
        vm.stopPrank();

        address accountA = module.subAccount(fdWeth);
        address accountB = module.subAccount(fdUsdc);
        assertTrue(accountA != accountB, "distinct sub-accounts");
        assertTrue(accountA != address(module) && accountB != address(module), "module address holds no position");
        assertEq(module.subAccountId(fdWeth), 1, "facility A on sub-account 1");
        assertEq(module.subAccountId(fdUsdc), 2, "facility B on sub-account 2");
        assertEq(IEVault(ETHEREUM_EWSTETH_2).balanceOf(address(module)), 0, "no shares on the module address");

        address[] memory controllersA = IEVCTest(evc).getControllers(accountA);
        address[] memory controllersB = IEVCTest(evc).getControllers(accountB);
        assertEq(controllersA.length, 1, "one controller on A");
        assertEq(controllersA[0], ETHEREUM_EWETH_2, "A controlled by eWETH-2");
        assertEq(controllersB.length, 1, "one controller on B");
        assertEq(controllersB[0], ETHEREUM_EUSDC_2, "B controlled by eUSDC-2");

        uint256 collateralA = module.collateralBalance(fdWeth, WSTETH);
        uint256 collateralB = module.collateralBalance(fdUsdc, WSTETH);
        assertApproxEqAbs(module.collateralBalance(WSTETH), 20e18, 4, "total collateral within 4 wei of 20 wstETH");
        assertEq(module.collateralBalance(WSTETH), collateralA + collateralB, "token collateral = sum of facilities");
        assertEq(module.debtBalance(WETH), 4e18, "WETH debt");
        assertEq(module.debtBalance(USDC), 10_000e6, "USDC debt");
        assertEq(module.debtBalance(fdWeth, USDC), 0, "facility A owes no USDC");
        assertEq(module.debtBalance(fdUsdc, WETH), 0, "facility B owes no WETH");
        assertEq(module.debtBalance(SUSDE), 0, "unknown token debt is 0");
        assertEq(module.collateralBalance(SUSDE), 0, "unknown token collateral is 0");

        uint256 navA = _expectedFacilityNav(box, module, fdWeth);
        uint256 navB = _expectedFacilityNav(box, module, fdUsdc);
        assertEq(module.nav(IOracleCallback(address(box))), navA + navB, "nav = sum of the floored facility values");
        uint256 ltvA = module.ltv(fdWeth);
        uint256 ltvB = module.ltv(fdUsdc);
        console2.log("ltv A", ltvA);
        console2.log("ltv B", ltvB);
        assertApproxEqRel(ltvA, 0.329804e18, 0.001e18, "ltv A around 0.3298");
        assertApproxEqRel(ltvB, 0.19046e18, 0.001e18, "ltv B around 0.1905");

        vm.prank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingCollateral(module, WSTETH);

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fdUsdc, USDC, type(uint256).max);
        assertEq(usdcBefore - USDC.balanceOf(address(box)), 10_000e6, "Box paid exactly B's debt");
        assertEq(module.debtBalance(fdUsdc, USDC), 0, "B debt closed");
        assertEq(IEVCTest(evc).getControllers(accountB).length, 0, "B controller released");
        assertEq(module.debtBalance(fdWeth, WETH), 4e18, "A debt unchanged");
        controllersA = IEVCTest(evc).getControllers(accountA);
        assertEq(controllersA.length, 1, "A keeps its controller");
        assertEq(controllersA[0], ETHEREUM_EWETH_2, "A still controlled by eWETH-2");
        assertEq(module.collateralBalance(fdWeth, WSTETH), collateralA, "A collateral unchanged");
    }

    // ========== WINDDOWN ==========

    function testWinddownAnyoneRepaysAndDepledgesWithGuard() public {
        Box windBox = _newBox(WETH, WSTETH, wstethOracle, 0);
        (FundingEuler windModule, bytes memory fd) = _newModule(windBox, LTV_CAP, ETHEREUM_EWSTETH_2, ETHEREUM_EWETH_2);
        _deposit(windBox, 10e18);
        deal(address(WSTETH), address(windBox), 10e18);
        vm.prank(allocator);
        windBox.pledge(windModule, fd, WSTETH, 10e18);
        uint256 borrowAmount = (_capacity(windModule, fd) * 80) / 100;
        vm.prank(allocator);
        windBox.borrow(windModule, fd, WETH, borrowAmount);
        address account = windModule.subAccount(fd);

        vm.prank(guardian);
        windBox.shutdown();
        assertTrue(windBox.isWinddown(), "winddown without warmup, no warp needed");

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        windBox.pledge(windModule, fd, WSTETH, 1);
        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        windBox.borrow(windModule, fd, WETH, 1);

        uint256 debtBefore = windModule.debtBalance(fd, WETH);
        vm.prank(anyone);
        windBox.repay(windModule, fd, WETH, 1e18);
        assertEq(windModule.debtBalance(fd, WETH), debtBefore - 1e18, "partial repay by anyone lowers the debt");

        uint256 collateral = windModule.collateralBalance(fd, WSTETH);
        uint256 ltv = windModule.ltv(fd);
        uint256 cap = _guardCap(windModule, fd);
        console2.log("winddown ltv after partial repay", ltv);
        uint256 beyondEuler = _depledgeFor(collateral, ltv, 0.95e18);
        uint256 beyondCap = _depledgeFor(collateral, ltv, 0.905e18);
        uint256 withinCap = _depledgeFor(collateral, ltv, 0.86e18);

        vm.prank(anyone);
        vm.expectRevert(E_ACCOUNT_LIQUIDITY);
        windBox.depledge(windModule, fd, WSTETH, beyondEuler);

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        windBox.depledge(windModule, fd, WSTETH, beyondCap);

        uint256 wstethBefore = WSTETH.balanceOf(address(windBox));
        vm.prank(anyone);
        windBox.depledge(windModule, fd, WSTETH, withinCap);
        assertEq(WSTETH.balanceOf(address(windBox)) - wstethBefore, withinCap, "depledge by anyone delivered to the Box");
        assertLe(windModule.ltv(fd), cap, "guard held");
        assertGt(windModule.ltv(fd), ltv, "depledge raised the ltv");

        bytes memory borrowCall = abi.encodeCall(IEVault.borrow, (1e18, anyone));
        vm.prank(anyone);
        vm.expectRevert(EVC_NOT_AUTHORIZED);
        IEVC(evc).call(ETHEREUM_EWETH_2, account, 0, borrowCall);

        vm.prank(anyone);
        windBox.repay(windModule, fd, WETH, type(uint256).max);
        assertEq(IEVault(ETHEREUM_EWETH_2).debtOf(account), 0, "debt closed by anyone");
        assertEq(IEVCTest(evc).getControllers(account).length, 0, "controller released");

        collateral = windModule.collateralBalance(fd, WSTETH);
        wstethBefore = WSTETH.balanceOf(address(windBox));
        vm.prank(anyone);
        windBox.depledge(windModule, fd, WSTETH, type(uint256).max);
        assertEq(IEVault(ETHEREUM_EWSTETH_2).balanceOf(account), 0, "no shares left");
        assertEq(WSTETH.balanceOf(address(windBox)) - wstethBefore, collateral, "all collateral back in the Box");
    }

    // ========== NAV CONSISTENCY ==========

    function testNavAndTotalAssetsConsistentAcrossPledgeAndBorrow() public {
        MockSwapper swapper = _newSwapper();
        vm.prank(allocator);
        box.allocate(WSTETH, 50e18, ISwapper(address(swapper)), "");
        uint256 wsteth = WSTETH.balanceOf(address(box));
        uint256 totalBefore = box.totalAssets();
        console2.log("totalAssets before pledge", totalBefore);

        vm.prank(allocator);
        box.pledge(module, fdWeth, WSTETH, wsteth);
        assertApproxEqAbs(box.totalAssets(), totalBefore, 10, "pledge keeps totalAssets within 10 wei");
        _assertNavConsistent();

        vm.prank(allocator);
        box.borrow(module, fdWeth, WETH, 30e18);
        assertApproxEqAbs(box.totalAssets(), totalBefore, 10, "borrow keeps totalAssets within 10 wei");
        _assertNavConsistent();
    }

    // ========== HELPERS ==========

    function _open(uint256 collateral, uint256 debt) internal {
        deal(address(WSTETH), address(box), collateral);
        vm.startPrank(allocator);
        box.pledge(module, fdWeth, WSTETH, collateral);
        box.borrow(module, fdWeth, WETH, debt);
        vm.stopPrank();
    }

    function _newSwapper() internal returns (MockSwapper swapper) {
        swapper = new MockSwapper();
        swapper.setOracle(WETH, new MockOracle(1e36));
        swapper.setOracle(WSTETH, wstethOracle);
        deal(address(WETH), address(swapper), 10_000e18);
        deal(address(WSTETH), address(swapper), 10_000e18);
    }

    /// @dev USDC (6 decimals) priced in WETH (18 decimals) at the 1e36 scale, from the Euler router's USD quotes
    function _usdcPriceInWeth() internal view returns (uint256) {
        IPriceOracle router = IPriceOracle(ETHEREUM_EULER_ROUTER);
        uint256 usdcUsd = router.getQuote(1e6, address(USDC), EULER_USD);
        uint256 wethUsd = router.getQuote(1e18, address(WETH), EULER_USD);
        return (1e36 * usdcUsd * 1e18) / (wethUsd * 1e6);
    }

    /// @dev totalAssets = Box WETH + floored value of its wstETH + module nav, and nav = the Box-oracle formula
    function _assertNavConsistent() internal view {
        uint256 nav = module.nav(IOracleCallback(address(box)));
        assertEq(nav, _expectedNav(box, module), "nav = Box-oracle formula (collateral down, debt up)");
        uint256 idle = WETH.balanceOf(address(box)) + (WSTETH.balanceOf(address(box)) * wstethOracle.price()) / 1e36;
        assertEq(box.totalAssets(), idle + nav, "totalAssets = idle holdings + module nav");
    }
}
