// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {FundingAaveV4} from "../src/FundingAaveV4.sol";
import {FundingAaveV4Factory} from "../src/factories/FundingAaveV4Factory.sol";
import {IAaveV4Spoke} from "../src/interfaces/aave-v4/IAaveV4Spoke.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {IAaveV4Oracle, SpokeRatioOracle} from "./BoxLeverageAaveV4Avalanche.t.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/**
 * @title Box + FundingAaveV4 against the real Aave v4 deployment on Ethereum
 * @dev Same module as on Avalanche, other chain and Spokes:
 *      - Lido eSpoke (single Hub): wstETH collateral, WETH debt loop;
 *      - Bluechip Spoke (Prime Hub reserves 0-6, Core Hub reserves 7-11): wstETH collateral, USDC debt. USDC is listed
 *        twice (reserve 4 on Prime, reserve 7 on Core); the constructor reserve list decides which one a module uses.
 */
contract BoxLeverageAaveV4MainnetTest is Test {
    using BoxLib for Box;

    uint256 internal constant FORK_BLOCK = 26_040_000;

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);

    IAaveV4Spoke internal constant LIDO_SPOKE = IAaveV4Spoke(0xe1900480ac69f0B296841Cd01cC37546d92F35Cd);
    IAaveV4Spoke internal constant BLUECHIP_SPOKE = IAaveV4Spoke(0x973a023A77420ba610f06b3858aD991Df6d85A08);
    address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
    address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;

    IERC20 internal constant WSTETH = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 internal constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Lido eSpoke reserves
    uint256 internal constant LIDO_WSTETH_ID = 0;
    uint256 internal constant LIDO_WETH_ID = 1;
    // Bluechip Spoke reserves
    uint256 internal constant BLUECHIP_WETH_ID = 0;
    uint256 internal constant BLUECHIP_WSTETH_ID = 3;
    uint256 internal constant PRIME_USDC_ID = 4;
    uint256 internal constant CORE_USDC_ID = 7;

    uint256 internal constant LLTV_CAP = 0.95e18;

    bytes4 internal constant HEALTH_FACTOR_BELOW_THRESHOLD = bytes4(keccak256("HealthFactorBelowThreshold()"));

    bytes internal constant EMPTY = "";

    FundingAaveV4Factory internal factory;
    IAaveV4Oracle internal lidoSpokeOracle;
    SpokeRatioOracle internal wstethOracle;
    MockOracle internal wethUnitOracle;

    Box internal box;
    FundingAaveV4 internal module;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);

        factory = new FundingAaveV4Factory();
        lidoSpokeOracle = IAaveV4Oracle(LIDO_SPOKE.ORACLE());
        wstethOracle = new SpokeRatioOracle(lidoSpokeOracle, LIDO_WSTETH_ID, 18, LIDO_WETH_ID, 18);
        wethUnitOracle = new MockOracle(1e36);

        box = new Box(address(WETH), owner, curator, "Box WETH", "BOXWETH", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);
        module = factory.createFundingAaveV4(address(box), address(LIDO_SPOKE), _ids2(LIDO_WSTETH_ID, LIDO_WETH_ID), LLTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(WSTETH, wstethOracle);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, EMPTY);
        box.addFundingCollateralInstant(module, WSTETH);
        box.addFundingDebtInstant(module, WETH);
        vm.stopPrank();

        deal(address(WETH), address(this), 100e18);
        WETH.approve(address(box), 100e18);
        box.deposit(100e18, address(this));
        deal(address(WSTETH), address(box), 100e18);
    }

    // ========== LIDO ESPOKE: wstETH / WETH ==========

    function testLidoPledgeBorrowIsNavNeutral() public {
        uint256[] memory idleBefore = _idleBalances(module);
        uint256 navBefore = box.totalAssets();
        uint256 wethBefore = WETH.balanceOf(address(box));

        _openLido(100e18);
        uint256 navAfter = box.totalAssets();

        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);
        assertEq(WETH.balanceOf(address(box)) - wethBefore, 100e18, "Box received exactly 100 WETH");
        assertEq(WSTETH.balanceOf(address(box)), 0, "all wstETH pledged");
        assertApproxEqAbs(navAfter, navBefore, 2, "pledge + borrow is nav neutral within 2 wei");
        _assertIdleUnchanged(module, idleBefore);
        assertEq(WSTETH.balanceOf(address(module)), 0, "no idle wstETH in the module");
        assertEq(WETH.balanceOf(address(module)), 0, "no idle WETH in the module");

        (bool usingAsCollateral, ) = LIDO_SPOKE.getUserReserveStatus(LIDO_WSTETH_ID, address(module));
        assertTrue(usingAsCollateral, "wstETH enabled as collateral");
        uint256 debt = LIDO_SPOKE.getUserTotalDebt(LIDO_WETH_ID, address(module));
        uint256 supplied = LIDO_SPOKE.getUserSuppliedAssets(LIDO_WSTETH_ID, address(module));
        assertApproxEqAbs(debt, 100e18, 1, "debt = borrowed amount (rounded up)");
        assertApproxEqAbs(supplied, 100e18, 1, "supplied = pledged amount (rounded down)");
        _assertLidoViewsMatchSpoke();

        uint256 expectedLtv = (debt * lidoSpokeOracle.getReservePrice(LIDO_WETH_ID) * 1e18) /
            (supplied * lidoSpokeOracle.getReservePrice(LIDO_WSTETH_ID));
        uint256 ltv = module.ltv(EMPTY);
        console2.log("ltv", ltv);
        assertApproxEqRel(ltv, expectedLtv, 1e9, "ltv matches the Spoke oracle within 1e-9");
        assertGt(ltv, 0.79e18, "ltv around 0.8035");
        assertLt(ltv, 0.81e18, "ltv around 0.8035");
    }

    function testLidoLeverageLoopStaysInsideCap() public {
        MockSwapper swapper = _newLidoSwapper();
        uint256[] memory idleBefore = _idleBalances(module);
        uint256 navBefore = box.totalAssets();

        vm.prank(allocator);
        box.pledge(module, EMPTY, WSTETH, 100e18);
        uint256 totalPledged = 100e18;
        uint256 totalBorrowed;

        uint256[3] memory steps = [uint256(100e18), 80e18, 64e18];
        for (uint256 i = 0; i < steps.length; i++) {
            vm.startPrank(allocator);
            box.borrow(module, EMPTY, WETH, steps[i]);
            uint256 wstethBefore = WSTETH.balanceOf(address(box));
            box.allocate(WSTETH, steps[i], ISwapper(address(swapper)), "");
            uint256 bought = WSTETH.balanceOf(address(box)) - wstethBefore;
            box.pledge(module, EMPTY, WSTETH, bought);
            vm.stopPrank();

            totalPledged += bought;
            totalBorrowed += steps[i];
            uint256 collateral = module.collateralBalance(EMPTY, WSTETH);
            uint256 debt = module.debtBalance(EMPTY, WETH);
            console2.log("iteration", i + 1);
            console2.log("  collateral  ", collateral);
            console2.log("  debt        ", debt);
            console2.log("  ltv         ", module.ltv(EMPTY));
            console2.log("  totalAssets ", box.totalAssets());
            assertApproxEqAbs(collateral, totalPledged, i + 2, "collateral = total pledged (1 wei per supply)");
            assertApproxEqAbs(debt, totalBorrowed, i + 1, "debt = total borrowed (1 wei per borrow)");
            _assertIdleUnchanged(module, idleBefore);
        }

        assertLe(module.ltv(EMPTY), (0.955e18 * LLTV_CAP) / 1e18, "final ltv within collateral factor x lltvCap");
        assertGe(LIDO_SPOKE.getUserAccountData(address(module)).healthFactor, module.minHealthFactor(), "guard holds");
        assertApproxEqRel(box.totalAssets(), navBefore, 0.0001e18, "loop keeps nav within 0.01%");
        assertEq(WSTETH.balanceOf(address(box)), 0, "everything bought was pledged");
    }

    function testLidoBorrowBeyondCapReverts() public {
        _openLido(100e18);
        uint256 debtBefore = module.debtBalance(EMPTY, WETH);
        uint256 wethBefore = WETH.balanceOf(address(box));
        uint256 navBefore = box.totalAssets();

        // Cap: 0.955 x 0.95 x ~124.46 WETH of collateral ~ 112.9 WETH of debt
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, EMPTY, WETH, 15e18);

        // Spoke limit: 0.955 x ~124.46 ~ 118.9 WETH of debt
        vm.prank(allocator);
        vm.expectRevert(HEALTH_FACTOR_BELOW_THRESHOLD);
        box.borrow(module, EMPTY, WETH, 20e18);

        assertEq(module.debtBalance(EMPTY, WETH), debtBefore, "debt unchanged");
        assertEq(WETH.balanceOf(address(box)), wethBefore, "Box WETH unchanged");
        assertEq(box.totalAssets(), navBefore, "totalAssets unchanged");

        vm.prank(allocator);
        box.borrow(module, EMPTY, WETH, 10e18);
        assertEq(WETH.balanceOf(address(box)) - wethBefore, 10e18, "in-cap borrow delivered");
        assertGe(LIDO_SPOKE.getUserAccountData(address(module)).healthFactor, module.minHealthFactor(), "guard holds");
    }

    function testLidoAccrualThenFullUnwindAndRemoval() public {
        uint256[] memory idleBefore = _idleBalances(module);
        _openLido(100e18);
        uint256 debtBefore = module.debtBalance(EMPTY, WETH);
        uint256 navBefore = box.totalAssets();
        uint256 priceBefore = wstethOracle.price();

        vm.warp(block.timestamp + 30 days);

        uint256 debtAfter = module.debtBalance(EMPTY, WETH);
        uint256 navAfter = box.totalAssets();
        console2.log("debt before", debtBefore);
        console2.log("debt after ", debtAfter);
        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);

        assertEq(wstethOracle.price(), priceBefore, "wstETH/WETH Spoke price unchanged on the fork");
        assertGt(debtAfter, debtBefore, "interest accrued without a transaction");
        assertGt(debtAfter - debtBefore, 0.1e18, "about 0.2 WETH of interest over 30 days");
        assertLt(debtAfter - debtBefore, 0.3e18, "about 0.2 WETH of interest over 30 days");
        assertApproxEqAbs(navBefore - navAfter, debtAfter - debtBefore, 2, "nav drops by the accrued interest within 2 wei");
        _assertLidoViewsMatchSpoke();

        vm.startPrank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingFacility(module, EMPTY);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingCollateral(module, WSTETH);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingDebt(module, WETH);
        vm.stopPrank();

        uint256 wethBefore = WETH.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, EMPTY, WETH, type(uint256).max);
        assertEq(wethBefore - WETH.balanceOf(address(box)), debtAfter, "Box paid exactly the debt");
        assertEq(LIDO_SPOKE.getUserTotalDebt(LIDO_WETH_ID, address(module)), 0, "no debt left");
        IAaveV4Spoke.UserPosition memory position = LIDO_SPOKE.getUserPosition(LIDO_WETH_ID, address(module));
        assertEq(position.drawnShares, 0, "no drawn shares");
        assertEq(position.premiumShares, 0, "no premium shares");

        vm.prank(allocator);
        box.depledge(module, EMPTY, WSTETH, type(uint256).max);
        assertEq(LIDO_SPOKE.getUserSuppliedShares(LIDO_WSTETH_ID, address(module)), 0, "no supplied shares left");
        assertEq(module.collateralBalance(EMPTY, WSTETH), 0, "no collateral left");
        assertApproxEqAbs(WSTETH.balanceOf(address(box)), 100e18, 1, "all wstETH back in the Box");
        _assertIdleUnchanged(module, idleBefore);
        assertEq(WSTETH.balanceOf(address(module)), 0, "no idle wstETH in the module");
        assertEq(WETH.balanceOf(address(module)), 0, "no idle WETH in the module");

        vm.startPrank(curator);
        box.removeFundingFacility(module, EMPTY);
        box.removeFundingCollateral(module, WSTETH);
        box.removeFundingDebt(module, WETH);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
        assertEq(
            box.totalAssets(),
            WETH.balanceOf(address(box)) + (WSTETH.balanceOf(address(box)) * wstethOracle.price()) / 1e36,
            "totalAssets is only idle Box holdings"
        );
    }

    function testLidoTokensDisallowedByReserveConfigRejected() public {
        FundingAaveV4 fresh = factory.createFundingAaveV4(address(box), address(LIDO_SPOKE), _ids2(LIDO_WSTETH_ID, LIDO_WETH_ID), LLTV_CAP);
        vm.startPrank(curator);
        box.addFundingInstant(fresh);
        box.addFundingFacilityInstant(fresh, EMPTY);

        // WETH has a zero collateral factor on the Lido eSpoke
        box.submit(abi.encodeWithSelector(IBox.addFundingCollateral.selector, address(fresh), address(WETH)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFundingCollateral(fresh, WETH);

        // wstETH is not borrowable there
        box.submit(abi.encodeWithSelector(IBox.addFundingDebt.selector, address(fresh), address(WSTETH)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFundingDebt(fresh, WSTETH);
        vm.stopPrank();

        assertEq(fresh.collateralTokensLength(), 0, "no collateral token registered");
        assertEq(fresh.debtTokensLength(), 0, "no debt token registered");
    }

    // ========== BLUECHIP SPOKE: DUPLICATE USDC RESERVES ==========

    function testBluechipUsdcIsListedTwiceOnDifferentHubs() public view {
        IAaveV4Spoke.Reserve memory prime = BLUECHIP_SPOKE.getReserve(PRIME_USDC_ID);
        IAaveV4Spoke.Reserve memory core = BLUECHIP_SPOKE.getReserve(CORE_USDC_ID);
        assertEq(prime.underlying, address(USDC), "reserve 4 is USDC");
        assertEq(core.underlying, address(USDC), "reserve 7 is USDC");
        assertEq(prime.hub, PRIME_HUB, "reserve 4 on the Prime Hub");
        assertEq(core.hub, CORE_HUB, "reserve 7 on the Core Hub");
        assertEq(BLUECHIP_SPOKE.getReserve(BLUECHIP_WSTETH_ID).underlying, address(WSTETH), "reserve 3 is wstETH");
        assertEq(BLUECHIP_SPOKE.getReserve(BLUECHIP_WETH_ID).underlying, address(WETH), "reserve 0 is WETH");
    }

    function testBluechipConstructorRejectsBothUsdcReserves() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = BLUECHIP_WSTETH_ID;
        ids[1] = PRIME_USDC_ID;
        ids[2] = CORE_USDC_ID;

        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        factory.createFundingAaveV4(address(box), address(BLUECHIP_SPOKE), ids, LLTV_CAP);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(address(box), address(BLUECHIP_SPOKE), ids, LLTV_CAP);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(address(box), address(BLUECHIP_SPOKE), _ids2(CORE_USDC_ID, PRIME_USDC_ID), LLTV_CAP);
    }

    function testBluechipDuplicateUsdcReservesAreDisambiguated() public {
        (Box usdcBox, FundingAaveV4 moduleX, FundingAaveV4 moduleY) = _deployBluechipBox();

        (bool listedX, uint256 idX) = moduleX.reserveIdOf(USDC);
        (bool listedY, uint256 idY) = moduleY.reserveIdOf(USDC);
        assertTrue(listedX && listedY, "USDC listed in both modules");
        assertEq(idX, CORE_USDC_ID, "module X uses the Core USDC reserve");
        assertEq(idY, PRIME_USDC_ID, "module Y uses the Prime USDC reserve");

        uint256[] memory idleX = _idleBalances(moduleX);
        uint256[] memory idleY = _idleBalances(moduleY);
        uint256 navBefore = usdcBox.totalAssets();
        uint256 usdcBefore = USDC.balanceOf(address(usdcBox));

        vm.startPrank(allocator);
        usdcBox.pledge(moduleX, EMPTY, WSTETH, 10e18);
        usdcBox.borrow(moduleX, EMPTY, USDC, 10_000e6);
        usdcBox.pledge(moduleY, EMPTY, WSTETH, 10e18);
        usdcBox.borrow(moduleY, EMPTY, USDC, 10_000e6);
        vm.stopPrank();

        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", usdcBox.totalAssets());
        assertEq(USDC.balanceOf(address(usdcBox)) - usdcBefore, 20_000e6, "Box received exactly 2 x 10,000 USDC");
        assertApproxEqAbs(usdcBox.totalAssets(), navBefore, 4, "both positions nav neutral within 2 units each");
        _assertIdleUnchanged(moduleX, idleX);
        _assertIdleUnchanged(moduleY, idleY);

        // Debt sits only on the reserve each module was configured with
        uint256 debtX = BLUECHIP_SPOKE.getUserTotalDebt(CORE_USDC_ID, address(moduleX));
        uint256 debtY = BLUECHIP_SPOKE.getUserTotalDebt(PRIME_USDC_ID, address(moduleY));
        assertGe(debtX, 10_000e6, "module X debt on the Core USDC reserve");
        assertEq(BLUECHIP_SPOKE.getUserTotalDebt(PRIME_USDC_ID, address(moduleX)), 0, "module X has no Prime USDC debt");
        assertGe(debtY, 10_000e6, "module Y debt on the Prime USDC reserve");
        assertEq(BLUECHIP_SPOKE.getUserTotalDebt(CORE_USDC_ID, address(moduleY)), 0, "module Y has no Core USDC debt");
        assertEq(moduleX.debtBalance(USDC), debtX, "module X token debt = its reserve's debt");
        assertEq(moduleX.debtBalance(EMPTY, USDC), debtX, "module X facility debt = its reserve's debt");
        assertEq(moduleY.debtBalance(USDC), debtY, "module Y token debt = its reserve's debt");
        assertEq(moduleY.debtBalance(EMPTY, USDC), debtY, "module Y facility debt = its reserve's debt");
        assertEq(BLUECHIP_SPOKE.getUserAccountData(address(moduleX)).borrowCount, 1, "module X borrows one reserve");
        assertEq(BLUECHIP_SPOKE.getUserAccountData(address(moduleY)).borrowCount, 1, "module Y borrows one reserve");
        (, bool xBorrowsPrime) = BLUECHIP_SPOKE.getUserReserveStatus(PRIME_USDC_ID, address(moduleX));
        (, bool yBorrowsCore) = BLUECHIP_SPOKE.getUserReserveStatus(CORE_USDC_ID, address(moduleY));
        assertFalse(xBorrowsPrime, "module X not borrowing on Prime");
        assertFalse(yBorrowsCore, "module Y not borrowing on Core");

        assertApproxEqAbs(moduleX.collateralBalance(EMPTY, WSTETH), 10e18, 1, "module X collateral");
        assertApproxEqAbs(moduleY.collateralBalance(EMPTY, WSTETH), 10e18, 1, "module Y collateral");
        uint256 ltvY = moduleY.ltv(EMPTY);
        console2.log("ltv X", moduleX.ltv(EMPTY));
        console2.log("ltv Y", ltvY);
        assertGt(ltvY, 0.28e18, "ltv around 0.295");
        assertLt(ltvY, 0.31e18, "ltv around 0.295");

        // Closing X does not touch Y
        uint256 yDebtBefore = moduleY.debtBalance(EMPTY, USDC);
        uint256 yCollateralBefore = moduleY.collateralBalance(EMPTY, WSTETH);
        uint256 yNavBefore = moduleY.nav(IOracleCallback(address(usdcBox)));
        uint256 yLtvBefore = moduleY.ltv(EMPTY);

        usdcBefore = USDC.balanceOf(address(usdcBox));
        vm.prank(allocator);
        usdcBox.repay(moduleX, EMPTY, USDC, type(uint256).max);
        assertEq(usdcBefore - USDC.balanceOf(address(usdcBox)), debtX, "Box paid exactly module X's debt");
        assertEq(BLUECHIP_SPOKE.getUserTotalDebt(CORE_USDC_ID, address(moduleX)), 0, "module X debt closed");
        assertEq(moduleX.debtBalance(USDC), 0, "module X token debt 0");

        assertEq(moduleY.debtBalance(EMPTY, USDC), yDebtBefore, "module Y debt unchanged");
        assertEq(BLUECHIP_SPOKE.getUserTotalDebt(PRIME_USDC_ID, address(moduleY)), yDebtBefore, "Prime USDC debt unchanged");
        assertEq(moduleY.collateralBalance(EMPTY, WSTETH), yCollateralBefore, "module Y collateral unchanged");
        assertEq(moduleY.nav(IOracleCallback(address(usdcBox))), yNavBefore, "module Y nav unchanged");
        assertEq(moduleY.ltv(EMPTY), yLtvBefore, "module Y ltv unchanged");

        // Both unwind fully
        vm.startPrank(allocator);
        usdcBox.depledge(moduleX, EMPTY, WSTETH, type(uint256).max);
        usdcBox.repay(moduleY, EMPTY, USDC, type(uint256).max);
        usdcBox.depledge(moduleY, EMPTY, WSTETH, type(uint256).max);
        vm.stopPrank();
        assertEq(BLUECHIP_SPOKE.getUserSuppliedShares(BLUECHIP_WSTETH_ID, address(moduleX)), 0, "module X collateral withdrawn");
        assertEq(BLUECHIP_SPOKE.getUserSuppliedShares(BLUECHIP_WSTETH_ID, address(moduleY)), 0, "module Y collateral withdrawn");
        assertEq(BLUECHIP_SPOKE.getUserTotalDebt(PRIME_USDC_ID, address(moduleY)), 0, "module Y debt closed");
        assertApproxEqAbs(WSTETH.balanceOf(address(usdcBox)), 20e18, 2, "all wstETH back in the Box");
        _assertIdleUnchanged(moduleX, idleX);
        _assertIdleUnchanged(moduleY, idleY);
    }

    function testBluechipTokensDisallowedByReserveConfigRejected() public {
        (Box usdcBox, FundingAaveV4 moduleX, FundingAaveV4 moduleY) = _deployBluechipBox();

        // USDC has a zero collateral factor on both of its Bluechip reserves
        vm.startPrank(curator);
        usdcBox.submit(abi.encodeWithSelector(IBox.addFundingCollateral.selector, address(moduleX), address(USDC)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        usdcBox.addFundingCollateral(moduleX, USDC);
        usdcBox.submit(abi.encodeWithSelector(IBox.addFundingCollateral.selector, address(moduleY), address(USDC)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        usdcBox.addFundingCollateral(moduleY, USDC);

        // wstETH is collateral only
        usdcBox.submit(abi.encodeWithSelector(IBox.addFundingDebt.selector, address(moduleX), address(WSTETH)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        usdcBox.addFundingDebt(moduleX, WSTETH);
        vm.stopPrank();

        assertFalse(moduleX.isCollateralToken(USDC), "USDC not collateral in module X");
        assertFalse(moduleY.isCollateralToken(USDC), "USDC not collateral in module Y");
        assertFalse(moduleX.isDebtToken(WSTETH), "wstETH not debt in module X");

        // WETH (reserve 0) is collateral only on Bluechip
        uint256[] memory ids = new uint256[](3);
        ids[0] = BLUECHIP_WETH_ID;
        ids[1] = BLUECHIP_WSTETH_ID;
        ids[2] = PRIME_USDC_ID;
        FundingAaveV4 moduleZ = factory.createFundingAaveV4(address(usdcBox), address(BLUECHIP_SPOKE), ids, LLTV_CAP);
        assertFalse(BLUECHIP_SPOKE.getReserveConfig(BLUECHIP_WETH_ID).borrowable, "WETH not borrowable on Bluechip");
        SpokeRatioOracle wethOracle = new SpokeRatioOracle(IAaveV4Oracle(BLUECHIP_SPOKE.ORACLE()), BLUECHIP_WETH_ID, 18, PRIME_USDC_ID, 6);

        vm.startPrank(curator);
        usdcBox.addTokenInstant(WETH, wethOracle);
        usdcBox.addFundingInstant(moduleZ);
        usdcBox.addFundingFacilityInstant(moduleZ, EMPTY);
        usdcBox.submit(abi.encodeWithSelector(IBox.addFundingDebt.selector, address(moduleZ), address(WETH)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        usdcBox.addFundingDebt(moduleZ, WETH);

        // Still valid in the collateral role, and USDC is borrowable
        usdcBox.addFundingCollateralInstant(moduleZ, WETH);
        usdcBox.addFundingDebtInstant(moduleZ, USDC);
        vm.stopPrank();

        assertFalse(moduleZ.isDebtToken(WETH), "WETH not debt in module Z");
        assertTrue(moduleZ.isCollateralToken(WETH), "WETH collateral in module Z");
        assertTrue(moduleZ.isDebtToken(USDC), "USDC debt in module Z");
    }

    // ========== HELPERS ==========

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _openLido(uint256 borrowAmount) internal {
        vm.startPrank(allocator);
        box.pledge(module, EMPTY, WSTETH, 100e18);
        box.borrow(module, EMPTY, WETH, borrowAmount);
        vm.stopPrank();
    }

    function _newLidoSwapper() internal returns (MockSwapper swapper) {
        swapper = new MockSwapper();
        swapper.setOracle(WETH, wethUnitOracle);
        swapper.setOracle(WSTETH, wstethOracle);
        deal(address(WETH), address(swapper), 10_000e18);
        deal(address(WSTETH), address(swapper), 10_000e18);
    }

    /// @dev USDC Box holding 20 wstETH, with module X (wstETH, Core USDC) and module Y (wstETH, Prime USDC) attached,
    ///      wstETH collateral and USDC debt registered in both
    function _deployBluechipBox() internal returns (Box usdcBox, FundingAaveV4 moduleX, FundingAaveV4 moduleY) {
        usdcBox = new Box(address(USDC), owner, curator, "Box USDC", "BOXUSDC", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);
        moduleX = factory.createFundingAaveV4(address(usdcBox), address(BLUECHIP_SPOKE), _ids2(BLUECHIP_WSTETH_ID, CORE_USDC_ID), LLTV_CAP);
        moduleY = factory.createFundingAaveV4(
            address(usdcBox),
            address(BLUECHIP_SPOKE),
            _ids2(BLUECHIP_WSTETH_ID, PRIME_USDC_ID),
            LLTV_CAP
        );
        SpokeRatioOracle bluechipWstethOracle = new SpokeRatioOracle(
            IAaveV4Oracle(BLUECHIP_SPOKE.ORACLE()),
            BLUECHIP_WSTETH_ID,
            18,
            PRIME_USDC_ID,
            6
        );

        vm.startPrank(curator);
        usdcBox.setGuardianInstant(guardian);
        usdcBox.addTokenInstant(WSTETH, bluechipWstethOracle);
        usdcBox.setIsAllocator(allocator, true);
        usdcBox.addFeederInstant(address(this));
        usdcBox.addFundingInstant(moduleX);
        usdcBox.addFundingFacilityInstant(moduleX, EMPTY);
        usdcBox.addFundingCollateralInstant(moduleX, WSTETH);
        usdcBox.addFundingDebtInstant(moduleX, USDC);
        usdcBox.addFundingInstant(moduleY);
        usdcBox.addFundingFacilityInstant(moduleY, EMPTY);
        usdcBox.addFundingCollateralInstant(moduleY, WSTETH);
        usdcBox.addFundingDebtInstant(moduleY, USDC);
        vm.stopPrank();

        deal(address(USDC), address(this), 1_000e6);
        USDC.approve(address(usdcBox), 1_000e6);
        usdcBox.deposit(1_000e6, address(this));
        deal(address(WSTETH), address(usdcBox), 20e18);
    }

    /// @dev Module balance of the underlying of every configured reserve, in reserve list order
    function _idleBalances(FundingAaveV4 m) internal view returns (uint256[] memory balances) {
        uint256[] memory ids = m.reserveIdsArray();
        IAaveV4Spoke s = m.spoke();
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            balances[i] = IERC20(s.getReserve(ids[i]).underlying).balanceOf(address(m));
        }
    }

    function _assertIdleUnchanged(FundingAaveV4 m, uint256[] memory expected) internal view {
        uint256[] memory balances = _idleBalances(m);
        for (uint256 i = 0; i < balances.length; i++) {
            assertEq(balances[i], expected[i], "module holds no idle configured token beyond its starting balance");
        }
    }

    function _assertLidoViewsMatchSpoke() internal view {
        uint256 debt = LIDO_SPOKE.getUserTotalDebt(LIDO_WETH_ID, address(module));
        uint256 supplied = LIDO_SPOKE.getUserSuppliedAssets(LIDO_WSTETH_ID, address(module));
        assertEq(module.debtBalance(EMPTY, WETH), debt, "facility debt = Spoke total debt");
        assertEq(module.debtBalance(WETH), debt, "token debt = Spoke total debt");
        assertEq(module.collateralBalance(EMPTY, WSTETH), supplied, "facility collateral = Spoke supplied assets");
        assertEq(module.collateralBalance(WSTETH), supplied, "token collateral = Spoke supplied assets");
    }
}
