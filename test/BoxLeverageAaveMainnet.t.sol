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
    IOracle ptSusdeOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085); // Placeholder - needs actual oracle
    
    ISwapper swapper = ISwapper(0x5C9dA86ECF5B35C8BF700a31a51d8a63fA53d1f6); // Same swapper as Base
    
    IPool pool;
    
    function setUp() public {
        // Fork mainnet from specific block
        uint256 forkId = vm.createFork(vm.rpcUrl("eth"), 23294087);
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
        
        // Check e-mode status
        uint256 boxEMode = pool.getUserEMode(address(box));
        assertEq(boxEMode, eModeCategory, "E-mode not set correctly");
        
        // Get account data
        (uint256 totalCollateral, , uint256 availableBorrows, , uint256 ltv, ) = pool.getUserAccountData(address(box));
        
        console2.log("USDC Borrowing with E-mode 17:");
        console2.log("- Collateral value:", totalCollateral / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows / 1e8, "USD");
        console2.log("- LTV:", ltv / 100, "%");
        
        // Borrow at 80% LTV
        uint256 targetBorrowAmount = (totalCollateral * 80) / 100 / 100; // 80% LTV in USDC terms
        box.borrow(borrowAdapter, borrowData, targetBorrowAmount);
        
        // Verify final LTV using both methods
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        uint256 finalLTVCalculated = finalCollateral > 0 ? (finalDebt * 10000) / finalCollateral : 0;
        uint256 finalLTVFromFunction = borrowAdapter.ltv(borrowData, address(box));
        
        console2.log("- Final LTV (calculated):", finalLTVCalculated / 100, "%");
        console2.log("- Final LTV (from function):", finalLTVFromFunction * 100 / 1e18, "%");
        
        // Assert that both methods give the same result (with small tolerance for rounding)
        assertApproxEqAbs(finalLTVFromFunction, finalLTVCalculated * 1e14, 1e14, "LTV function should match calculation");
        
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
        
        // Check e-mode status
        uint256 boxEMode = pool.getUserEMode(address(box));
        assertEq(boxEMode, eModeCategory, "E-mode not set correctly");
        
        // Get account data
        (uint256 totalCollateral, , uint256 availableBorrows, , uint256 ltv, ) = pool.getUserAccountData(address(box));
        
        console2.log("USDe Borrowing with E-mode 18:");
        console2.log("- Collateral value:", totalCollateral / 1e8, "USD");
        console2.log("- Available to borrow:", availableBorrows / 1e8, "USD");
        console2.log("- LTV:", ltv / 100, "%");
        
        // Borrow at 80% LTV
        uint256 targetBorrowAmount = (totalCollateral * 80) / 100 * 1e10; // 80% LTV in USDe terms
        box.borrow(borrowAdapter, borrowData, targetBorrowAmount);
        
        // Verify final LTV using both methods
        (uint256 finalCollateral, uint256 finalDebt, , , , ) = pool.getUserAccountData(address(box));
        uint256 finalLTVCalculated = finalCollateral > 0 ? (finalDebt * 10000) / finalCollateral : 0;
        uint256 finalLTVFromFunction = borrowAdapter.ltv(borrowData, address(box));
        
        console2.log("- Final LTV (calculated):", finalLTVCalculated / 100, "%");
        console2.log("- Final LTV (from function):", finalLTVFromFunction * 100 / 1e18, "%");
        
        // Assert that both methods give the same result (with small tolerance for rounding)
        assertApproxEqAbs(finalLTVFromFunction, finalLTVCalculated * 1e14, 1e14, "LTV function should match calculation");
        
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