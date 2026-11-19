// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Box} from "../src/Box.sol";
import {FundingAave, IPool} from "../src/FundingAave.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {FlashLoanAave, IPoolAddressesProviderAave} from "../src/periphery/FlashLoanAave.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockAaveFlashLoanPool} from "./mocks/MockAaveFlashLoanPool.sol";
import {MockAaveV3Pool} from "./mocks/MockAaveV3Pool.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @notice FlashLoanAave on a mock Aave flash loan pool, driving a real Box with two FundingAave modules on MockAaveV3Pool.
/// @dev USDC is the Box asset and the flash-loaned token; COLL is the collateral, worth 2 USDC. The Aave premium is 0.05%.
contract FlashLoanAaveTest is Test {
    using BoxLib for IBox;

    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant COLL_PRICE = 2e24; // 2 USDC (6 decimals) per COLL (18 decimals)
    uint256 internal constant PLEDGED = 500e18; // 1,000 USDC of COLL, pledged to fromModule in setUp

    /// @dev 0.05% of LOAN is 500,000.0005 units: Aave rounds it up to 500,001 where a floor gives 500,000
    uint256 internal constant LOAN = 1_000e6 + 1;
    uint256 internal constant LOAN_PREMIUM = 500_001;

    /// @dev 0.05% of DEBT is 150,000.0005 units: Aave rounds it up to 150,001 where a floor gives 150,000
    uint256 internal constant DEBT = 300e6 + 1;
    uint256 internal constant DEBT_PREMIUM = 150_001;
    uint256 internal constant DEBT_IN_COLL = (DEBT * ORACLE_SCALE) / COLL_PRICE;

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal allocator = makeAddr("allocator");
    address internal otherAllocator = makeAddr("otherAllocator");
    address internal feeder = makeAddr("feeder");
    address internal nobody = makeAddr("nobody");

    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal coll;
    MockSwapper internal swapper;
    IBox internal box;
    MockAaveV3Pool internal lendingPool;
    FundingAave internal fromModule;
    FundingAave internal toModule;
    MockAaveFlashLoanPool internal flashPool;
    FlashLoanAave internal helper;

    function setUp() public {
        usdc = new ERC20MockDecimals(6);
        coll = new ERC20MockDecimals(18);
        MockOracle collOracle = new MockOracle(COLL_PRICE);

        box = IBox(address(new Box(address(usdc), boxOwner, curator, "Box Flash", "BOXF", 0.01 ether, 7 days, 10 days, 1 days)));

        lendingPool = new MockAaveV3Pool();
        lendingPool.listReserve(address(usdc), 1e8);
        lendingPool.listReserve(address(coll), 2e8);
        usdc.mint(address(lendingPool), 1_000_000e6);
        fromModule = new FundingAave(address(box), IPool(address(lendingPool)), 0, 0.9e18);
        toModule = new FundingAave(address(box), IPool(address(lendingPool)), 0, 0.9e18);

        flashPool = new MockAaveFlashLoanPool();
        usdc.mint(address(flashPool), 1_000_000e6);
        helper = new FlashLoanAave(IPoolAddressesProviderAave(address(flashPool)));

        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.setIsAllocator(otherAllocator, true);
        box.setIsAllocator(address(helper), true);
        box.addFeederInstant(feeder);
        box.addTokenInstant(coll, collOracle);
        FundingAave[2] memory modules = [fromModule, toModule];
        for (uint256 i; i < 2; i++) {
            box.addFundingInstant(modules[i]);
            box.addFundingFacilityInstant(modules[i], "");
            box.addFundingCollateralInstant(modules[i], coll);
            box.addFundingDebtInstant(modules[i], usdc);
        }
        vm.stopPrank();

        swapper = new MockSwapper();
        swapper.setOracle(usdc, new MockOracle(ORACLE_SCALE));
        swapper.setOracle(coll, collOracle);
        usdc.mint(address(swapper), 1_000_000e6);
        coll.mint(address(swapper), 1_000_000e18);

        usdc.mint(feeder, 1_000e6);
        vm.startPrank(feeder);
        usdc.approve(address(box), 1_000e6);
        box.deposit(1_000e6, feeder);
        vm.stopPrank();

        coll.mint(address(box), PLEDGED);
        vm.prank(allocator);
        box.pledge(fromModule, "", coll, PLEDGED);
    }

    // ========== HELPERS ==========

    /// @dev Gives `payer` the premium and approves the helper for `approved` of it
    function _fundPremium(address payer, uint256 premium, uint256 approved) internal {
        usdc.mint(payer, premium);
        vm.prank(payer);
        usdc.approve(address(helper), approved);
    }

    function _borrowDebt() internal {
        vm.prank(allocator);
        box.borrow(fromModule, "", usdc, DEBT);
    }

    function _leverage(address caller) internal {
        vm.prank(caller);
        helper.leverage(box, fromModule, "", swapper, "", coll, usdc, LOAN);
    }

    function _deleverage(address caller) internal {
        vm.prank(caller);
        helper.deleverage(box, fromModule, "", swapper, "", coll, DEBT_IN_COLL, usdc, DEBT);
    }

    /// @dev Moves the whole position, so the helper resolves both amounts
    function _refinance(address caller) internal {
        vm.prank(caller);
        helper.refinance(box, fromModule, "", toModule, "", coll, type(uint256).max, usdc, type(uint256).max);
    }

    function _assertNothingLeftBehind() internal view {
        assertEq(usdc.balanceOf(address(helper)), 0, "helper holds no USDC");
        assertEq(coll.balanceOf(address(helper)), 0, "helper holds no COLL");
        assertEq(usdc.allowance(address(box), address(helper)), 0, "Box allowance of USDC to the helper");
        assertEq(coll.allowance(address(box), address(helper)), 0, "Box allowance of COLL to the helper");
        assertEq(usdc.allowance(address(box), address(flashPool)), 0, "Box allowance of USDC to the pool");
        assertEq(coll.allowance(address(box), address(flashPool)), 0, "Box allowance of COLL to the pool");
        assertEq(usdc.allowance(address(helper), address(box)), 0, "helper allowance to the Box");
        assertEq(usdc.allowance(address(helper), address(flashPool)), 0, "helper allowance to the pool");
    }

    function _expectMissingAllowance(uint256 premium) internal {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(helper), 0, premium));
    }

    // ========== OPERATIONS ==========

    function testLeverage() public {
        _fundPremium(allocator, LOAN_PREMIUM, LOAN_PREMIUM);
        uint256 boxUsdcBefore = usdc.balanceOf(address(box));
        uint256 poolBefore = usdc.balanceOf(address(flashPool));

        _leverage(allocator);

        assertEq(fromModule.debtBalance(usdc), LOAN, "debt is the loan, without the premium");
        assertEq(fromModule.collateralBalance(coll), PLEDGED + (LOAN * ORACLE_SCALE) / COLL_PRICE, "the loan bought COLL, all pledged");
        assertEq(usdc.balanceOf(address(box)), boxUsdcBefore, "the Box pays no premium");
        assertEq(usdc.balanceOf(allocator), 0, "the allocator paid the premium");
        assertEq(usdc.balanceOf(address(flashPool)), poolBefore + LOAN_PREMIUM, "the pool got the loan and the premium");
        _assertNothingLeftBehind();
    }

    function testDeleverage() public {
        _borrowDebt();
        _fundPremium(allocator, DEBT_PREMIUM, DEBT_PREMIUM);
        uint256 boxUsdcBefore = usdc.balanceOf(address(box));
        uint256 poolBefore = usdc.balanceOf(address(flashPool));

        _deleverage(allocator);

        assertEq(fromModule.debtBalance(usdc), 0, "debt repaid");
        assertEq(fromModule.collateralBalance(coll), PLEDGED - DEBT_IN_COLL, "the COLL sold to repay was withdrawn");
        assertEq(coll.balanceOf(address(box)), 0, "the withdrawn COLL was sold");
        assertEq(usdc.balanceOf(address(box)), boxUsdcBefore, "the Box pays no premium");
        assertEq(usdc.balanceOf(allocator), 0, "the allocator paid the premium");
        assertEq(usdc.balanceOf(address(flashPool)), poolBefore + DEBT_PREMIUM, "the pool got the loan and the premium");
        _assertNothingLeftBehind();
    }

    function testRefinance() public {
        _borrowDebt();
        _fundPremium(allocator, DEBT_PREMIUM, DEBT_PREMIUM);
        uint256 boxUsdcBefore = usdc.balanceOf(address(box));
        uint256 poolBefore = usdc.balanceOf(address(flashPool));

        _refinance(allocator);

        assertEq(fromModule.debtBalance(usdc), 0, "old debt repaid");
        assertEq(fromModule.collateralBalance(coll), 0, "old collateral withdrawn");
        assertEq(toModule.debtBalance(usdc), DEBT, "new debt is the old debt, without the premium");
        assertEq(toModule.collateralBalance(coll), PLEDGED, "all the collateral moved");
        assertEq(usdc.balanceOf(address(box)), boxUsdcBefore, "the Box pays no premium");
        assertEq(usdc.balanceOf(allocator), 0, "the allocator paid the premium");
        assertEq(usdc.balanceOf(address(flashPool)), poolBefore + DEBT_PREMIUM, "the pool got the loan and the premium");
        _assertNothingLeftBehind();
    }

    // ========== PREMIUM ==========

    function testPremiumIsPaidByTheCaller() public {
        _fundPremium(allocator, LOAN_PREMIUM, LOAN_PREMIUM);
        _fundPremium(otherAllocator, LOAN_PREMIUM, LOAN_PREMIUM);

        _leverage(otherAllocator);

        assertEq(usdc.balanceOf(otherAllocator), 0, "the caller paid the premium");
        assertEq(usdc.balanceOf(allocator), LOAN_PREMIUM, "another allocator who approved the helper paid nothing");
        assertEq(usdc.allowance(allocator, address(helper)), LOAN_PREMIUM, "its allowance is untouched");
    }

    function testPremiumRoundsUp() public {
        assertEq(LOAN_PREMIUM, (LOAN * flashPool.FLASHLOAN_PREMIUM_TOTAL()) / 10_000 + 1, "LOAN is an amount where floor and ceil differ");

        // An approval of the floored premium falls one unit short
        _fundPremium(allocator, LOAN_PREMIUM, LOAN_PREMIUM - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(helper), LOAN_PREMIUM - 1, LOAN_PREMIUM)
        );
        _leverage(allocator);

        vm.prank(allocator);
        usdc.approve(address(helper), LOAN_PREMIUM);
        _leverage(allocator);
        assertEq(usdc.balanceOf(allocator), 0, "the allocator paid the rounded-up premium");
    }

    function testLeverageRevertsWithoutPremiumApproval() public {
        _fundPremium(allocator, LOAN_PREMIUM, 0);
        _expectMissingAllowance(LOAN_PREMIUM);
        _leverage(allocator);
    }

    function testDeleverageRevertsWithoutPremiumApproval() public {
        _borrowDebt();
        _fundPremium(allocator, DEBT_PREMIUM, 0);
        _expectMissingAllowance(DEBT_PREMIUM);
        _deleverage(allocator);
    }

    function testRefinanceRevertsWithoutPremiumApproval() public {
        _borrowDebt();
        _fundPremium(allocator, DEBT_PREMIUM, 0);
        _expectMissingAllowance(DEBT_PREMIUM);
        _refinance(allocator);
    }

    // ========== ACCESS ==========

    function testNonAllocatorIsRejected() public {
        _borrowDebt();
        _fundPremium(nobody, LOAN_PREMIUM, type(uint256).max);

        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        _leverage(nobody);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        _deleverage(nobody);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        _refinance(nobody);
    }

    function testCallbacksRejectOutsiders() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = LOAN;
        uint256[] memory zeros = new uint256[](1);
        bytes memory params = abi.encode(FlashLoanAave.leverage.selector, address(box));

        vm.startPrank(nobody);
        vm.expectRevert(ErrorsLib.OnlyPool.selector);
        helper.executeOperation(assets, amounts, zeros, address(helper), params);

        // Anyone can start an Aave flash loan that names the helper as receiver
        vm.expectRevert(ErrorsLib.OnlyThisContract.selector);
        flashPool.flashLoan(address(helper), assets, amounts, zeros, nobody, params, 0);

        vm.expectRevert(ErrorsLib.OnlyBox.selector);
        helper.onBoxFlash(usdc, LOAN, params);
        vm.stopPrank();

        // Outside an operation started by an allocator, even the Box is turned away
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.OnlyBox.selector);
        helper.onBoxFlash(usdc, LOAN, params);
    }
}
