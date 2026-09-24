// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {FundingAave, IPool} from "../src/FundingAave.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/**
 * @title Winddown regression for FundingAave on the Ethereum Aave v3 pool
 * @dev Box calls `debtBalance(token)` on every funding module for the token being deallocated in winddown,
 * so a FundingAave must answer 0 for tokens Aave does not list instead of reverting.
 */
contract BoxLeverageAaveWinddownMainnetTest is Test {
    using BoxLib for Box;

    address owner = address(0x1);
    address curator = address(0x2);
    address allocator = address(0x4);
    address stranger = address(0xbeef);

    IPool constant POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2); // Aave v3 Pool (Ethereum)
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), 23_294_087);
    }

    function testWinddownDeallocateUnlistedTokenWithFundingAaveAttached() public {
        Box box = new Box(address(USDC), owner, curator, "Box USDC", "BOX_USDC", 0.01 ether, 1 days, 7 days, 1 days);

        // Box token that Aave does not list: 18 decimals, 1 token = 1 USDC
        ERC20MockDecimals token = new ERC20MockDecimals(18);
        MockOracle tokenOracle = new MockOracle(1e24);
        (, , , , , , , , address aToken, , address variableDebtToken, , , , ) = POOL.getReserveData(address(token));
        assertEq(aToken, address(0), "token is not an Aave reserve (aToken)");
        assertEq(variableDebtToken, address(0), "token is not an Aave reserve (debt token)");

        FundingAave module = new FundingAave(address(box), POOL, 0);

        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addTokenInstant(token, tokenOracle);
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, "");
        box.addFundingCollateralInstant(module, USDC);
        box.addFundingDebtInstant(module, USDC);
        vm.stopPrank();

        deal(address(USDC), address(this), 1_000_000e6);
        USDC.approve(address(box), type(uint256).max);
        box.deposit(1_000_000e6, address(this));

        MockSwapper swapper = new MockSwapper();
        swapper.setOracle(USDC, new MockOracle(1e36));
        swapper.setOracle(token, tokenOracle);
        deal(address(USDC), address(swapper), 1_000_000e6);
        token.mint(address(swapper), 1_000_000e18);

        vm.startPrank(allocator);
        box.allocate(token, 50_000e6, swapper, "");
        box.pledge(module, "", USDC, 10_000e6);
        box.borrow(module, "", USDC, 100e6);
        vm.stopPrank();
        assertEq(token.balanceOf(address(box)), 50_000e18, "Box holds the unlisted token");
        // Aave's scaled-balance math rounds the variable debt up by at most 1 wei.
        assertApproxEqAbs(module.debtBalance("", USDC), 100e6, 1, "Aave debt opened");

        vm.prank(curator);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown(), "winddown");

        assertEq(module.debtBalance(token), 0, "debtBalance(unlisted) is 0");
        assertEq(module.collateralBalance(token), 0, "collateralBalance(unlisted) is 0");
        uint256 debt = module.debtBalance("", USDC);
        assertGe(debt, 100e6, "debt accrued interest");
        box.totalAssets();

        // Anyone can deallocate the unlisted token while the FundingAave is attached.
        uint256 usdcBefore = USDC.balanceOf(address(box));
        vm.prank(stranger);
        (, uint256 received) = box.deallocate(token, 10_000e18, swapper, "");
        assertEq(received, 10_000e6, "deallocate proceeds");
        assertEq(USDC.balanceOf(address(box)), usdcBefore + 10_000e6, "USDC returned to Box");
        assertEq(token.balanceOf(address(box)), 40_000e18, "token sold");
        assertTrue(box.isFunding(module), "module still attached");

        // The same address can still close the Aave debt.
        vm.prank(stranger);
        box.repay(module, "", USDC, type(uint256).max);
        assertEq(module.debtBalance("", USDC), 0, "Aave debt closed");
        assertEq(USDC.balanceOf(address(box)), usdcBefore + 10_000e6 - debt, "Box paid exactly the debt");
        assertEq(USDC.balanceOf(address(module)), 0, "nothing stuck in module");
    }
}
