// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Box} from "../src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {ErrorsLib} from "../src/lib/ErrorsLib.sol";

import {IBorrow} from "../src/interfaces/IBorrow.sol";
import {BorrowAave, IPool} from "../src/BorrowAave.sol";
import {IBox, LoanFacility} from "../src/interfaces/IBox.sol";

/// @notice Minimal Aave v3 Addresses Provider to obtain the Pool
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

/// @notice Mock oracle for testing - returns a fixed price
contract MockOracle {
    uint256 public immutable fixedPrice;
    
    constructor(uint256 _price) {
        fixedPrice = _price;
    }
    
    function price() external view returns (uint256) {
        return fixedPrice;
    }
}

/**
 * @title Testing suite for leverage features of Box using Aave on Mainnet
 */
contract BoxLeverageAaveMainnetTest is Test {
    using BoxLib for Box;
    
    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);
    
    // Mainnet addresses
    address constant PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // Aave v3 PoolAddressesProvider (Mainnet)
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // Mainnet USDC
    IERC20 ptSusde25Sep = IERC20(0x9F56094C450763769BA0EA9Fe2876070c0fD5F77); // PT-sUSDe-25SEP2025
    IERC20 usde = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3); // USDe
    IOracle ptSusdeOracle = IOracle(0x5139aa359F7F7FdE869305e8C7AD001B28E1C99a); // Oracle for PT-sUSDe-25SEP2025
    
    ISwapper swapper = ISwapper(0x5C9dA86ECF5B35C8BF700a31a51d8a63fA53d1f6); // Same swapper as Base
    
    IPool pool;
    
    function setUp() public {
        // Fork mainnet from specific block
        uint256 forkId = vm.createFork(vm.rpcUrl("mainnet"), 23294087);
        vm.selectFork(forkId);
        
        // Get Aave pool
        pool = IPool(IPoolAddressesProvider(PROVIDER).getPool());
    }
    
    function testBorrowUSDCAgainstPTsUSDe() public {
        // Deploy Box for USDC
        Box box = new Box(
            address(usdc),
            owner,
            curator,
            "Box USDC",
            "BOX_USDC",
            0.01 ether,
            7 days,
            10 days
        );
        
        // Configure Box
        vm.startPrank(curator);
        box.changeGuardian(guardian);
        box.addCollateral(ptSusde25Sep, ptSusdeOracle);
        box.setIsAllocator(allocator, true);
        box.addFeeder(address(this));
        
        BorrowAave borrowAdapter = new BorrowAave();
        // Use e-mode 17 for borrowing stablecoins (including USDC)
        uint8 eModeCategory = 17;
        bytes memory borrowData = borrowAdapter.aaveParamsToDataWithEMode(pool, address(usdc), address(ptSusde25Sep), 2, eModeCategory);
        box.addFunding(borrowAdapter, borrowData);
        vm.stopPrank();
        
        // Supply 1000 PT tokens
        uint256 ptAmount = 1000 ether;
        deal(address(ptSusde25Sep), address(box), ptAmount);
        
        // Fund Box with initial USDC
        deal(address(usdc), address(this), 1000e6);
        usdc.approve(address(box), 1000e6);
        box.deposit(1000e6, address(this));
        
        vm.startPrank(allocator);
        
        // Supply PT as collateral
        box.supplyCollateral(borrowAdapter, borrowData, ptAmount);
        
        // Get account data
        (uint256 totalCollateral, , uint256 availableBorrows, , uint256 ltv, ) = pool.getUserAccountData(address(box));
        
        console2.log("USDC Borrowing with E-mode 17:");
        console2.log("- Collateral value:", totalCollateral / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows / 1e8, "USD");
        console2.log("- LTV:", ltv / 100, "%");
        
        // Record NAV before borrowing
        uint256 navBeforeBorrow = box.totalAssets();
        
        // Borrow at 80% LTV
        uint256 targetBorrowAmount = (totalCollateral * 80) / 100 / 100; // 80% LTV in USDC terms
        box.borrow(borrowAdapter, borrowData, targetBorrowAmount);
        
        // Check e-mode status (should be set after borrow)
        uint256 boxEMode = pool.getUserEMode(address(box));
        assertEq(boxEMode, eModeCategory, "E-mode not set correctly");
        
        // Verify final LTV using both methods
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        uint256 finalLTVCalculated = finalCollateral > 0 ? (finalDebt * 10000) / finalCollateral : 0;
        uint256 finalLTVFromFunction = borrowAdapter.ltv(borrowData, address(box));
        
        console2.log("- Final LTV (calculated):", finalLTVCalculated / 100, "%");
        console2.log("- Final LTV (from function):", finalLTVFromFunction * 100 / 1e18, "%");
        
        // Assert that both methods give the same result (with small tolerance for rounding)
        assertApproxEqAbs(finalLTVFromFunction, finalLTVCalculated * 1e14, 1e14, "LTV function should match calculation");
        
        // NAV check
        uint256 navAfterBorrow = box.totalAssets();
        console2.log("\nNAV check:");
        console2.log("- Before borrow:", navBeforeBorrow / 1e6, "USDC");
        console2.log("- After borrow:", navAfterBorrow / 1e6, "USDC");
        assertApproxEqRel(navAfterBorrow, navBeforeBorrow, 0.001e18, "NAV should remain approximately constant");
        
        // Clean up
        deal(address(usdc), address(box), usdc.balanceOf(address(box)) + targetBorrowAmount + 100e6);
        box.repay(borrowAdapter, borrowData, type(uint256).max);
        box.withdrawCollateral(borrowAdapter, borrowData, ptAmount);
        vm.stopPrank();
    }
    
    function testBorrowUSDeAgainstPTsUSDe() public {
        // Deploy Box for USDe
        Box box = new Box(
            address(usde),
            owner,
            curator,
            "Box USDe",
            "BOX_USDe",
            0.01 ether,
            7 days,
            10 days
        );
        
        // Configure Box
        vm.startPrank(curator);
        box.changeGuardian(guardian);
        box.addCollateral(ptSusde25Sep, ptSusdeOracle);
        box.setIsAllocator(allocator, true);
        box.addFeeder(address(this));
        
        BorrowAave borrowAdapter = new BorrowAave();
        // Use e-mode 18 for borrowing USDe (better max LTV)
        uint8 eModeCategory = 18;
        bytes memory borrowData = borrowAdapter.aaveParamsToDataWithEMode(pool, address(usde), address(ptSusde25Sep), 2, eModeCategory);
        box.addFunding(borrowAdapter, borrowData);
        vm.stopPrank();
        
        // Supply 1000 PT tokens
        uint256 ptAmount = 1000 ether;
        deal(address(ptSusde25Sep), address(box), ptAmount);
        
        // Fund Box with initial USDe
        deal(address(usde), address(this), 1000e18);
        usde.approve(address(box), 1000e18);
        box.deposit(1000e18, address(this));
        
        vm.startPrank(allocator);
        
        // Supply PT as collateral
        box.supplyCollateral(borrowAdapter, borrowData, ptAmount);
        
        // Get account data
        (uint256 totalCollateral, , uint256 availableBorrows, , uint256 ltv, ) = pool.getUserAccountData(address(box));
        
        console2.log("USDe Borrowing with E-mode 18:");
        console2.log("- Collateral value:", totalCollateral / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows / 1e8, "USD");
        console2.log("- LTV:", ltv / 100, "%");
        
        // Record NAV before borrowing
        uint256 navBeforeBorrow = box.totalAssets();
        
        // Borrow at 80% LTV
        uint256 targetBorrowAmount = (totalCollateral * 80) / 100 * 1e10; // 80% LTV in USDe terms
        box.borrow(borrowAdapter, borrowData, targetBorrowAmount);
        
        // Check e-mode status (should be set after borrow)
        uint256 boxEMode = pool.getUserEMode(address(box));
        assertEq(boxEMode, eModeCategory, "E-mode not set correctly");
        
        // Verify final LTV using both methods
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        uint256 finalLTVCalculated = finalCollateral > 0 ? (finalDebt * 10000) / finalCollateral : 0;
        uint256 finalLTVFromFunction = borrowAdapter.ltv(borrowData, address(box));
        
        console2.log("- Final LTV (calculated):", finalLTVCalculated / 100, "%");
        console2.log("- Final LTV (from function):", finalLTVFromFunction * 100 / 1e18, "%");
        
        // Assert that both methods give the same result (with small tolerance for rounding)
        assertApproxEqAbs(finalLTVFromFunction, finalLTVCalculated * 1e14, 1e14, "LTV function should match calculation");
        
        // NAV check
        uint256 navAfterBorrow = box.totalAssets();
        console2.log("\nNAV check:");
        console2.log("- Before borrow:", navBeforeBorrow / 1e18, "USDe");
        console2.log("- After borrow:", navAfterBorrow / 1e18, "USDe");
        assertApproxEqRel(navAfterBorrow, navBeforeBorrow, 0.001e18, "NAV should remain approximately constant");
        
        // Clean up
        vm.stopPrank();
        deal(address(usde), address(box), usde.balanceOf(address(box)) + targetBorrowAmount + 100e18);
        vm.startPrank(allocator);
        box.repay(borrowAdapter, borrowData, type(uint256).max);
        box.withdrawCollateral(borrowAdapter, borrowData, ptAmount);
        vm.stopPrank();
    }
    
    function testLeverageAccess() public {
        // Simple box setup for access control testing
        Box box = new Box(
            address(usdc),
            owner,
            curator,
            "Test Box",
            "TBOX",
            0.01 ether,
            7 days,
            10 days
        );
        
        vm.prank(curator);
        box.setIsAllocator(allocator, true);
        
        BorrowAave borrowAdapter = new BorrowAave();
        bytes memory borrowData = borrowAdapter.aaveParamsToData(pool, address(usdc), address(ptSusde25Sep), 2);
        
        address[] memory testAddresses = new address[](4);
        testAddresses[0] = owner;
        testAddresses[1] = curator;
        testAddresses[2] = guardian;
        testAddresses[3] = user;
        
        for (uint256 i = 0; i < testAddresses.length; i++) {
            vm.startPrank(testAddresses[i]);
            
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.supplyCollateral(borrowAdapter, borrowData, 0);
            
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.withdrawCollateral(borrowAdapter, borrowData, 0);
            
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.borrow(borrowAdapter, borrowData, 0);
            
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.repay(borrowAdapter, borrowData, 0);
            
            vm.stopPrank();
        }
    }
    
    function testTwoAdaptersDifferentEModes() public {
        // Deploy Box for USDC
        Box box = new Box(
            address(usdc),
            owner,
            curator,
            "Box Multi Collateral",
            "BOX_MC",
            0.01 ether,
            7 days,
            10 days
        );
        
        // sUSDe - using e-mode 2 for borrowing stablecoins
        IERC20 sUsde = IERC20(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
        IOracle sUsdeOracle = IOracle(0x873CD44b860DEDFe139f93e12A4AcCa0926Ffb87); // Oracle for sUSDe
        
        // Configure Box
        vm.startPrank(curator);
        box.changeGuardian(guardian);
        box.addCollateral(ptSusde25Sep, ptSusdeOracle);
        box.addCollateral(sUsde, sUsdeOracle);
        box.setIsAllocator(allocator, true);
        box.addFeeder(address(this));
        
        // Create two separate BorrowAave adapters
        BorrowAave borrowAdapterPTsUSDe = new BorrowAave();
        BorrowAave borrowAdapterSUSDe = new BorrowAave();
        
        // Configure funding for PT-sUSDe with e-mode 17
        uint8 eMode17 = 17;
        bytes memory borrowDataPTsUSDe = borrowAdapterPTsUSDe.aaveParamsToDataWithEMode(pool, address(usdc), address(ptSusde25Sep), 2, eMode17);
        box.addFunding(borrowAdapterPTsUSDe, borrowDataPTsUSDe);
        
        // Configure funding for sUSDe with e-mode 2
        uint8 eMode2 = 2;
        bytes memory borrowDataSUSDe = borrowAdapterSUSDe.aaveParamsToDataWithEMode(pool, address(usdc), address(sUsde), 2, eMode2);
        box.addFunding(borrowAdapterSUSDe, borrowDataSUSDe);
        vm.stopPrank();
        
        // Supply collaterals
        uint256 ptSusdeAmount = 1000 ether;
        uint256 sUsdeAmount = 1500 ether;
        deal(address(ptSusde25Sep), address(box), ptSusdeAmount);
        deal(address(sUsde), address(box), sUsdeAmount);
        
        // Fund Box with initial USDC
        deal(address(usdc), address(this), 1000e6);
        usdc.approve(address(box), 1000e6);
        box.deposit(1000e6, address(this));
        
        // Record NAV before borrowing
        uint256 navBeforeBorrow = box.totalAssets();
        console2.log("NAV before supplying collateral and borrowing:", navBeforeBorrow / 1e6, "USDC");
        
        vm.startPrank(allocator);
        
        // Supply collaterals
        box.supplyCollateral(borrowAdapterPTsUSDe, borrowDataPTsUSDe, ptSusdeAmount);
        box.supplyCollateral(borrowAdapterSUSDe, borrowDataSUSDe, sUsdeAmount);
        
        // Get NAV after supplying collateral
        uint256 navAfterSupply = box.totalAssets();
        console2.log("NAV after supplying collaterals:", navAfterSupply / 1e6, "USDC");
        
        // First borrow: USDC against PT-sUSDe with e-mode 17
        // Get available borrow amount
        (uint256 collateral1, , uint256 availableBorrows1, , , ) = pool.getUserAccountData(address(box));
        console2.log("\nBefore first borrow:");
        console2.log("- E-mode:", pool.getUserEMode(address(box)));
        console2.log("- Collateral value:", collateral1 / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows1 / 1e8, "USD");
        
        uint256 borrowAmount1 = 500e6; // Borrow 500 USDC
        box.borrow(borrowAdapterPTsUSDe, borrowDataPTsUSDe, borrowAmount1);
        console2.log("Borrowed", borrowAmount1 / 1e6, "USDC against PT-sUSDe with e-mode 17");
        
        // Second borrow: USDC against sUSDe with e-mode 2
        // This will switch e-mode from 17 to 2
        (uint256 collateral2, , uint256 availableBorrows2, , , ) = pool.getUserAccountData(address(box));
        console2.log("\nBefore second borrow:");
        console2.log("- E-mode:", pool.getUserEMode(address(box)));
        console2.log("- Collateral value:", collateral2 / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows2 / 1e8, "USD");
        
        uint256 borrowAmount2 = 300e6; // Borrow 300 USDC
        box.borrow(borrowAdapterSUSDe, borrowDataSUSDe, borrowAmount2);
        console2.log("Borrowed", borrowAmount2 / 1e6, "USDC against sUSDe with e-mode 2");
        
        // Final position
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        uint256 finalEMode = pool.getUserEMode(address(box));
        console2.log("\nFinal position:");
        console2.log("- E-mode:", finalEMode);
        console2.log("- Total collateral value:", finalCollateral / 1e8, "USD");
        console2.log("- Total debt value:", finalDebt / 1e8, "USD");
        
        // Calculate final LTV using the first adapter (both should give same result)
        uint256 finalLTV = borrowAdapterPTsUSDe.ltv(borrowDataPTsUSDe, address(box));
        console2.log("- Final LTV:", finalLTV * 100 / 1e18, "%");
        
        // Get final NAV
        uint256 navAfterBorrow = box.totalAssets();
        console2.log("\nNAV Analysis:");
        console2.log("- NAV before borrow:", navBeforeBorrow / 1e6, "USDC");
        console2.log("- NAV after borrow:", navAfterBorrow / 1e6, "USDC");
        int256 navDiff = int256(navAfterBorrow) - int256(navBeforeBorrow);
        if (navDiff >= 0) {
            console2.log("- Difference: +", uint256(navDiff), "units");
        } else {
            console2.log("- Difference: -", uint256(-navDiff), "units");
        }
        
        // Debug: Check what each adapter is reporting for collateral
        console2.log("\nCollateral debugging:");
        uint256 ptSusdeCollateral = borrowAdapterPTsUSDe.collateral(borrowDataPTsUSDe, address(box));
        uint256 sUsdeCollateral = borrowAdapterSUSDe.collateral(borrowDataSUSDe, address(box));
        console2.log("- PT-sUSDe adapter reports:", ptSusdeCollateral / 1e18, "PT-sUSDe");
        console2.log("- sUSDe adapter reports:", sUsdeCollateral / 1e18, "sUSDe");
        
        // Debug: Check what debts are being reported
        uint256 ptSusdeDebt = borrowAdapterPTsUSDe.debt(borrowDataPTsUSDe, address(box));
        uint256 sUsdeDebt = borrowAdapterSUSDe.debt(borrowDataSUSDe, address(box));
        console2.log("- PT-sUSDe adapter debt:", ptSusdeDebt / 1e6, "USDC");
        console2.log("- sUSDe adapter debt:", sUsdeDebt / 1e6, "USDC");
        console2.log("- Expected total debt:", (borrowAmount1 + borrowAmount2) / 1e6, "USDC");
        
        // NAV should remain constant when borrowing assets at fair value
        assertApproxEqRel(navAfterBorrow, navBeforeBorrow, 0.001e18, "NAV should remain approximately constant");
        
        // Verify Box has the borrowed USDC
        uint256 boxUSDCBalance = usdc.balanceOf(address(box));
        console2.log("\nBox USDC balance:", boxUSDCBalance / 1e6, "USDC");
        console2.log("Expected from borrows:", (borrowAmount1 + borrowAmount2) / 1e6, "USDC");
        
        vm.stopPrank();
    }
    
    function testCombinedLTVWithTwoBorrows() public {
        // Deploy Box that can handle both USDC and USDe
        Box box = new Box(
            address(usdc),
            owner,
            curator,
            "Box Multi",
            "BOX_MULTI",
            0.01 ether,
            7 days,
            10 days
        );
        
        // Configure Box
        vm.startPrank(curator);
        box.changeGuardian(guardian);
        box.addCollateral(ptSusde25Sep, ptSusdeOracle);
        // Add USDe as a token since we'll be borrowing it
        // Create mock oracle for USDe: 1 USD = 1 USDe, price = 10^(36 + usdc_decimals - usde_decimals)
        MockOracle usdeOracle = new MockOracle(10**(36 + 6 - 18)); // 10^24 for USDC(6) to USDe(18)
        box.submit(abi.encodeWithSelector(box.addToken.selector, usde, usdeOracle));
        box.addToken(usde, IOracle(address(usdeOracle)));
        box.setIsAllocator(allocator, true);
        box.addFeeder(address(this));
        
        BorrowAave borrowAdapter = new BorrowAave();
        // Use e-mode 17 for borrowing stablecoins (allows both USDC and USDe)
        uint8 eModeCategory = 17;
        bytes memory borrowDataUSDC = borrowAdapter.aaveParamsToDataWithEMode(pool, address(usdc), address(ptSusde25Sep), 2, eModeCategory);
        bytes memory borrowDataUSDe = borrowAdapter.aaveParamsToDataWithEMode(pool, address(usde), address(ptSusde25Sep), 2, eModeCategory);
        box.addFunding(borrowAdapter, borrowDataUSDC);
        box.addFunding(borrowAdapter, borrowDataUSDe);
        vm.stopPrank();
        
        // Supply 2000 PT tokens total (1000 for each step)
        uint256 ptAmount = 1000 ether;
        deal(address(ptSusde25Sep), address(box), ptAmount * 2);
        
        // Fund Box with initial assets
        deal(address(usdc), address(this), 1000e6);
        usdc.approve(address(box), 1000e6);
        box.deposit(1000e6, address(this));
        
        vm.startPrank(allocator);
        
        // Check what tokens the Box knows about
        console2.log("Box USDC balance:", usdc.balanceOf(address(box)) / 1e6, "USDC");
        console2.log("Box USDe balance before borrow:", usde.balanceOf(address(box)) / 1e18, "USDe");
        
        // Record initial NAV
        uint256 navBefore = box.totalAssets();
        console2.log("Initial NAV:", navBefore / 1e6, "USDC");
        
        // Step 1: Supply first X collateral and borrow USDC at 60% LTV
        box.supplyCollateral(borrowAdapter, borrowDataUSDC, ptAmount);
        
        // Get initial collateral value
        (uint256 collateralValue1, , , , , ) = pool.getUserAccountData(address(box));
        console2.log("Collateral value after first supply:", collateralValue1 / 1e8, "USD");
        
        // Borrow USDC at 60% LTV
        uint256 usdcBorrowAmount = (collateralValue1 * 60) / 100 / 100; // 60% LTV in USDC terms
        box.borrow(borrowAdapter, borrowDataUSDC, usdcBorrowAmount);
        
        // Verify intermediate LTV using the ltv function
        uint256 ltvAfterUSDC = borrowAdapter.ltv(borrowDataUSDC, address(box));
        console2.log("LTV after USDC borrow:", ltvAfterUSDC * 100 / 1e18, "%");
        
        // Get collateral value after USDC borrow for later calculation
        (uint256 collateralAfterUSDC, , , , , ) = pool.getUserAccountData(address(box));
        
        // Step 2: Supply second X collateral and borrow USDe at 80% of new collateral
        box.supplyCollateral(borrowAdapter, borrowDataUSDe, ptAmount);
        
        // Get updated collateral value
        (uint256 collateralValue2, , , , , ) = pool.getUserAccountData(address(box));
        console2.log("Collateral value after second supply:", collateralValue2 / 1e8, "USD");
        
        // Calculate how much new collateral was added
        uint256 newCollateralValue = collateralValue2 - collateralAfterUSDC;
        
        // Borrow USDe at 80% of the NEW collateral only
        uint256 usdeBorrowAmount = (newCollateralValue * 80) / 100 * 1e10; // 80% LTV in USDe terms
        box.borrow(borrowAdapter, borrowDataUSDe, usdeBorrowAmount);
        
        // Get final LTV using the ltv function from BorrowAave
        uint256 finalLTV = borrowAdapter.ltv(borrowDataUSDC, address(box));
        
        // Also get final position data for logging
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        
        console2.log("\nFinal position summary:");
        console2.log("- Total collateral value:", finalCollateral / 1e8, "USD");
        console2.log("- Total debt value:", finalDebt / 1e8, "USD");
        console2.log("- Combined LTV (from ltv function):", finalLTV * 100 / 1e18, "%");
        
        // Assert that the combined LTV is approximately 70% (average of 60% and 80%)
        // The ltv function returns WAD format (1e18 = 100%), so 70% = 0.7e18
        assertApproxEqAbs(finalLTV, 0.7e18, 0.005e18, "Combined LTV should be approximately 70%");
        
        // NAV check with detailed analysis
        uint256 navAfter = box.totalAssets();
        console2.log("\nNAV check:");
        console2.log("- Before borrowing:", navBefore / 1e6, "USDC");
        console2.log("- After borrowing:", navAfter / 1e6, "USDC");
        
        // Check USDe balance and price to understand NAV increase
        uint256 usdeBalance = usde.balanceOf(address(box));
        console2.log("- USDe balance in box:", usdeBalance / 1e18, "USDe");
        
        // Get USDe price from our mock oracle (should be 1:1 with USD)
        uint256 usdePrice = usdeOracle.price();
        console2.log("- USDe oracle price:", usdePrice, "(raw oracle value)");
        
        // Debug debt calculations
        console2.log("\nDebt analysis:");
        uint256 usdcDebt = borrowAdapter.debt(borrowDataUSDC, address(box));
        uint256 usdeDebt = borrowAdapter.debt(borrowDataUSDe, address(box));
        console2.log("- USDC debt:", usdcDebt / 1e6, "USDC");
        console2.log("- USDe debt:", usdeDebt / 1e18, "USDe");
        console2.log("- Expected USDe debt (borrow amount):", usdeBorrowAmount / 1e18, "USDe");
        
        // Debug asset calculations 
        console2.log("\nAsset analysis:");
        uint256 boxUSDC = usdc.balanceOf(address(box));
        console2.log("- Box USDC balance:", boxUSDC / 1e6, "USDC");
        console2.log("- Box USDe balance:", usdeBalance / 1e18, "USDe");
        
        // Calculate expected values in NAV terms 
        uint256 ORACLE_PRECISION = 1e36;
        uint256 usdeAssetValue = usdeBalance * usdePrice / ORACLE_PRECISION;
        uint256 usdeDebtValue = usdeDebt * usdePrice / ORACLE_PRECISION;
        console2.log("- USDe asset value (calculated):", usdeAssetValue / 1e6, "USD");
        console2.log("- USDe debt value (calculated):", usdeDebtValue / 1e6, "USD");
        int256 usdeNetImpact = int256(usdeAssetValue / 1e6) - int256(usdeDebtValue / 1e6);
        if (usdeNetImpact >= 0) {
            console2.log("- USDe net impact (should be ~0): +", uint256(usdeNetImpact), "USD");
        } else {
            console2.log("- USDe net impact (should be ~0): -", uint256(-usdeNetImpact), "USD");
        }
        
        // Check USDC calculations (Box asset is USDC, no oracle needed)
        console2.log("- USDC asset value (Box balance):", boxUSDC / 1e6, "USD");
        console2.log("- USDC debt value (debt amount):", usdcDebt / 1e6, "USD");
        int256 usdcNetImpact = int256(boxUSDC / 1e6) - int256(usdcDebt / 1e6);
        if (usdcNetImpact >= 0) {
            console2.log("- USDC net impact (should be ~0): +", uint256(usdcNetImpact), "USD");
        } else {
            console2.log("- USDC net impact (should be ~0): -", uint256(-usdcNetImpact), "USD");
        }
        
        // Check if collateral is being double-counted by examining each funding facility
        console2.log("\nCollateral analysis:");
        uint256 usdcFacilityCollateral = borrowAdapter.collateral(borrowDataUSDC, address(box));
        uint256 usdeFacilityCollateral = borrowAdapter.collateral(borrowDataUSDe, address(box));
        console2.log("- USDC facility collateral:", usdcFacilityCollateral / 1e18, "PT-sUSDe");
        console2.log("- USDe facility collateral:", usdeFacilityCollateral / 1e18, "PT-sUSDe");
        console2.log("- Expected total collateral supplied:", (ptAmount * 2) / 1e18, "PT-sUSDe");
        
        // The core issue: borrowed assets = liabilities, so NAV should remain constant
        console2.log("- Total borrowed assets (USDC+USDe):", (boxUSDC - 1000e6) / 1e6 + usdeBalance / 1e18, "USD");
        console2.log("- Total debt (USDC+USDe):", usdcDebt / 1e6 + usdeDebtValue / 1e6, "USD");
        
        // With 1:1 USDe:USD pricing, NAV should remain constant
        int256 navChange = int256(navAfter) - int256(navBefore);
        if (navChange >= 0) {
            console2.log("- Actual NAV change: +", uint256(navChange), "units");
        } else {
            console2.log("- Actual NAV change: -", uint256(-navChange), "units");
        }
        
        // NAV should remain approximately constant when borrowing assets at fair value
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "NAV should remain approximately constant");

        uint256 currentEMode = pool.getUserEMode(address(box));
        console2.log("- Current e-mode:", currentEMode);
        
        // Clean up
        vm.stopPrank();
        deal(address(usdc), address(box), usdc.balanceOf(address(box)) + usdcBorrowAmount + 100e6);
        deal(address(usde), address(box), usde.balanceOf(address(box)) + usdeBorrowAmount + 100e18);
        vm.startPrank(allocator);
        box.repay(borrowAdapter, borrowDataUSDC, type(uint256).max);
        box.repay(borrowAdapter, borrowDataUSDe, type(uint256).max);
        box.withdrawCollateral(borrowAdapter, borrowDataUSDC, ptAmount * 2);
        vm.stopPrank();
    }
}