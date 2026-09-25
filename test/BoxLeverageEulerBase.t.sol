// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {FundingEuler} from "../src/FundingEuler.sol";
import {FundingEulerFactory} from "../src/factories/FundingEulerFactory.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {EulerForkTest, IEVCTest} from "./helpers/EulerForkTest.sol";

/**
 * @title Box + FundingEuler against the real Euler v2 deployment on Base
 * @dev Markets: ecbBTC-1 collateral against eUSDC-1 (LTVBorrow 78%) and ewstETH-1 against eWETH-1 (91%). Euler price
 *      feed budgets at the fork block: cbBTC about 76 minutes, ETH/USD about 69 minutes, so no test warps more than
 *      30 minutes.
 */
contract BoxLeverageEulerBaseTest is EulerForkTest {
    uint256 internal constant FORK_BLOCK = 35_116_463;

    IERC20 internal constant USDC = IERC20(BASE_USDC);
    IERC20 internal constant CBBTC = IERC20(BASE_CBBTC);
    IERC20 internal constant WETH = IERC20(BASE_WETH);
    IERC20 internal constant WSTETH = IERC20(BASE_WSTETH);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), FORK_BLOCK);
        evc = BASE_EVC;
        factory = new FundingEulerFactory();
    }

    function testCbbtcUsdcCoreFlow() public {
        Box box = _newBox(USDC, CBBTC, IOracle(BASE_CBBTC_USDC_ORACLE), MAX_SHUTDOWN_WARMUP);
        (FundingEuler module, bytes memory fd) = _newModule(box, 0.9e18, BASE_ECBBTC_1, BASE_EUSDC_1);
        _deposit(box, 1_000e6);
        deal(address(CBBTC), address(box), 2e8);
        assertEq(_guardCap(module, fd), 0.702e18, "guard cap 0.78 x 0.9");

        vm.prank(allocator);
        box.pledge(module, fd, CBBTC, 2e8);
        assertApproxEqAbs(module.collateralBalance(fd, CBBTC), 2e8, 2, "collateral = pledged within 2 units");

        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, fd, USDC, 100_000e6);
        assertEq(USDC.balanceOf(address(box)) - usdcBefore, 100_000e6, "Box received exactly 100,000 USDC");

        uint256 ltv = module.ltv(fd);
        uint256 nav = module.nav(IOracleCallback(address(box)));
        console2.log("ltv", ltv);
        console2.log("nav", nav);
        assertApproxEqRel(ltv, 0.4525e18, 0.001e18, "ltv around 0.4525");
        assertEq(nav, _expectedNav(box, module), "nav = Box-oracle formula");
        assertApproxEqRel(nav, 120_966.86e6, 0.0001e18, "nav around 120,966.86 USDC");

        uint256 capacity = _capacity(module, fd);
        uint256 beyondCap = (capacity * 92) / 100 - module.debtBalance(fd, USDC);
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, fd, USDC, beyondCap);

        _closeAndRemove(box, module, fd, CBBTC, USDC);
    }

    function testWstethWethCoreFlowWithinFeedBudget() public {
        Box box = _newBox(WETH, WSTETH, IOracle(BASE_WSTETH_WETH_ORACLE), MAX_SHUTDOWN_WARMUP);
        (FundingEuler module, bytes memory fd) = _newModule(box, 0.95e18, BASE_EWSTETH_1, BASE_EWETH_1);
        _deposit(box, 1e18);
        deal(address(WSTETH), address(box), 10e18);
        uint256 cap = _guardCap(module, fd);
        assertEq(cap, 0.8645e18, "guard cap 0.91 x 0.95");

        vm.prank(allocator);
        box.pledge(module, fd, WSTETH, 10e18);
        assertApproxEqAbs(module.collateralBalance(fd, WSTETH), 10e18, 2, "collateral = pledged within 2 wei");

        uint256 borrowAmount = (_capacity(module, fd) * 80) / 100;
        uint256 wethBefore = WETH.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, fd, WETH, borrowAmount);
        assertEq(WETH.balanceOf(address(box)) - wethBefore, borrowAmount, "Box received exactly the borrowed WETH");

        uint256 ltv = module.ltv(fd);
        console2.log("ltv", ltv);
        assertApproxEqRel(ltv, 0.728e18, 0.001e18, "ltv = 80% x 0.91 within 0.1%");
        assertLe(ltv, cap, "ltv within the cap");
        assertEq(module.nav(IOracleCallback(address(box))), _expectedNav(box, module), "nav = Box-oracle formula");

        uint256 beyondCap = (_capacity(module, fd) * 97) / 100 - module.debtBalance(fd, WETH);
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, fd, WETH, beyondCap);

        uint256 debtBefore = module.debtBalance(fd, WETH);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.roll(block.number + 900);
        assertGt(module.debtBalance(fd, WETH), debtBefore, "interest accrued over 30 minutes");
        assertEq(module.nav(IOracleCallback(address(box))), _expectedNav(box, module), "nav = Box-oracle formula after accrual");

        _closeAndRemove(box, module, fd, WSTETH, WETH);
    }

    /// @dev Repays and depledges everything through the Box, then removes the facility, tokens and module
    function _closeAndRemove(Box box, FundingEuler module, bytes memory fd, IERC20 collateralToken, IERC20 debtToken) internal {
        address account = module.subAccount(fd);
        uint256 debt = module.debtBalance(fd, debtToken);
        uint256 moduleDebtTokenBefore = debtToken.balanceOf(address(module));
        uint256 debtTokenBefore = debtToken.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fd, debtToken, type(uint256).max);
        assertEq(debtTokenBefore - debtToken.balanceOf(address(box)), debt, "Box paid exactly the prior debt");
        assertEq(_debt(module, fd), 0, "no Euler debt left");
        assertEq(_controllers(module, fd).length, 0, "controller released");
        assertEq(debtToken.balanceOf(address(module)), moduleDebtTokenBefore, "module keeps no debt token");

        uint256 collateral = module.collateralBalance(fd, collateralToken);
        uint256 collateralBefore = collateralToken.balanceOf(address(box));
        vm.prank(allocator);
        box.depledge(module, fd, collateralToken, type(uint256).max);
        assertEq(collateralToken.balanceOf(address(box)) - collateralBefore, collateral, "Box received exactly the prior collateral");
        assertEq(_shares(module, fd), 0, "no shares left");

        vm.startPrank(curator);
        box.removeFundingFacility(module, fd);
        box.removeFundingCollateral(module, collateralToken);
        box.removeFundingDebt(module, debtToken);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
        assertEq(module.subAccount(fd), address(0), "sub-account freed");
        address[] memory collaterals = IEVCTest(evc).getCollaterals(account);
        assertEq(collaterals.length, 0, "collateral disabled on the EVC");
    }
}
