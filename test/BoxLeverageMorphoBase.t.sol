// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Box} from "../src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IBox, LoanFacility} from "../src/interfaces/IBox.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";

import {IBoxAdapter} from "../src/interfaces/IBoxAdapter.sol";
import {IBoxAdapterFactory} from "../src/interfaces/IBoxAdapterFactory.sol";
import {BoxAdapterFactory} from "../src/BoxAdapterFactory.sol";
import {BoxAdapterCachedFactory} from "../src/BoxAdapterCachedFactory.sol";
import {BoxAdapter} from "../src/BoxAdapter.sol";
import {BoxAdapterCached} from "../src/BoxAdapterCached.sol";
import {EventsLib} from "../src/lib/EventsLib.sol";
import {ErrorsLib} from "../src/lib/ErrorsLib.sol";
import {VaultV2Lib} from "../src/lib/VaultV2Lib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {MorphoVaultV1AdapterLib} from "../src/lib/MorphoVaultV1Lib.sol";

import {IBorrow} from "../src/interfaces/IBorrow.sol";
import {BorrowMorpho} from "../src/BorrowMorpho.sol";
import {BorrowAave, IPool} from "../src/BorrowAave.sol";
import {MarketParams, IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {FlashLoanMorpho} from "../src/FlashLoanMorpho.sol";


/**
 * @title Testing suite for leverage features of Box using Morpho on Base
 */
contract BoxLeverageMorphoBaseTest is Test {
    using BoxLib for Box;
    Box box;
    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);
    
    ISwapper swapper = ISwapper(0x5C9dA86ECF5B35C8BF700a31a51d8a63fA53d1f6);

    IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address irm = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    BorrowMorpho fundingAdapter;
    MarketParams marketParams;
    bytes fundingData;
    bytes32 fundingId;

    /// @notice Will setup Peaty Base investing in bbqUSDC, box1 (stUSD) and box (PTs)
   function setUp() public {
        // Fork base on a recent block (December 2024)
        // Note: Using a recent block to ensure Aave V3 is deployed
        uint256 forkId = vm.createFork(vm.rpcUrl("base"), 34194011);  // Use latest block
        vm.selectFork(forkId);

        // Creating Box 2 which will invest in PT-USR-25SEP
        string memory name = "Box";
        string memory symbol = "BOX";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        box = new Box(
            address(usdc),
            owner,
            curator,
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );

        // Allow box 2 to invest in PT-USR-25SEP
        vm.startPrank(curator);
        box.changeGuardian(guardian);
        box.addCollateral(ptusr25sep, ptusr25sepOracle);
        box.setIsAllocator(address(allocator), true);
        box.addFeeder(address(this));

        fundingAdapter = new BorrowMorpho();
        marketParams = MarketParams(address(usdc), address(ptusr25sep), address(ptusr25sepOracle), irm, 915000000000000000);
        // And the funding facility
        fundingData = fundingAdapter.morphoMarketToData(morpho, marketParams);
        fundingId = box.fundingId(fundingAdapter, fundingData);
        box.addFunding(fundingAdapter, fundingData);

        vm.stopPrank();
    }   


    /////////////////////////////
    /// Setup checks
    /////////////////////////////

    function testSetup() public {
        assertEq(box.fundingsLength(), 1, "There is one source of funding");
        LoanFacility memory facility = box.fundings(0);
        assertEq(address(facility.loanToken), address(usdc), "Loan token is USDC");
        assertEq(address(facility.collateralToken), address(ptusr25sep), "Collateral token is ptusr25sep");
        assertEq(facility.data, fundingData, "fundingData is correct");
        assertEq(address(facility.borrow), address(fundingAdapter), "fundingAdapter is correct");

        LoanFacility memory facilityMap = box.fundingMap(fundingId);
        assertEq(address(facilityMap.loanToken), address(usdc), "Loan token is USDC");
        assertEq(address(facilityMap.collateralToken), address(ptusr25sep), "Collateral token is ptusr25sep");
        assertEq(facilityMap.data, fundingData, "fundingData is correct");
        assertEq(address(facilityMap.borrow), address(fundingAdapter), "fundingAdapter is correct");

        (IMorpho morpho2, MarketParams memory marketParams2) = fundingAdapter.dataToMorphoMarket(facilityMap.data);
        assertEq(address(morpho2), address(morpho), "Same Morpho address");
        assertEq(marketParams2.loanToken, marketParams.loanToken, "Same loan token");
        assertEq(marketParams2.collateralToken, marketParams.collateralToken, "Same collateral token");
        assertEq(marketParams2.oracle, marketParams.oracle, "Same oracle");
        assertEq(marketParams2.irm, marketParams.irm, "Same irm");
        assertEq(marketParams2.lltv, marketParams.lltv, "Same lltv");
    }

    /////////////////////////////
    /// Access control
    /////////////////////////////

    function testLeverageAccess() public {
        address[] memory testAddresses = new address[](4);
        testAddresses[0] = owner;
        testAddresses[1] = curator;
        testAddresses[2] = guardian;
        testAddresses[3] = user;

        FlashLoanMorpho flashloanProvider = new FlashLoanMorpho();

        for (uint256 i = 0; i < testAddresses.length; i++) {
            vm.startPrank(testAddresses[i]);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.supplyCollateral(fundingAdapter, fundingData, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.withdrawCollateral(fundingAdapter, fundingData, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.borrow(fundingAdapter, fundingData, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.repay(fundingAdapter, fundingData, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.wind(address(123), fundingAdapter, fundingData, 
                swapper, "", 
                ptusr25sep, usdc, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            box.unwind(address(123), fundingAdapter, fundingData, 
                swapper, "", 
                ptusr25sep, 0, usdc, 0);

            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            flashloanProvider.wind(box, morpho, fundingAdapter, fundingData, swapper, "", ptusr25sep, usdc, 1);

            vm.stopPrank();
        }
    }


    /////////////////////////////
    /// SCENARIOS
    /////////////////////////////

    function testBoxLeverage() public {
        uint256 USDC_1000 = 1000 * 10**6;

        // Get some USDC
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(this), USDC_1000); // Transfer 1000 USDC to this contract

        usdc.approve(address(box), USDC_1000);
        box.deposit(USDC_1000, address(this)); // Deposit 1000 USDC

        vm.startPrank(allocator);

        box.allocate(ptusr25sep, USDC_1000, swapper, "");
        uint256 ptBalance = ptusr25sep.balanceOf(address(box));

        uint256 totalAssets = box.totalAssets();

        assertEq(usdc.balanceOf(address(box)), 0, "No more USDC in the Box");
        assertEq(ptBalance, 1010280676747326095928, "ptusr25sep in the Box");
        assertEq(totalAssets, 1000000740, "totalAssets in the Box after ptusr25sep allocation");

        box.supplyCollateral(fundingAdapter, fundingData, ptBalance);

        assertEq(ptusr25sep.balanceOf(address(box)), 0, "No more ptusr25sep in the Box");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), ptBalance, "Collateral is correct");
        assertEq(box.totalAssets(), totalAssets, "totalAssets in the Box after ptusr25sep collateral supply");

        box.borrow(fundingAdapter, fundingData, 500 * 10**6);

        assertEq(usdc.balanceOf(address(box)), 500  * 10**6, "500 USDC in the Box");

        // Get some USDC to convert rounding
        vm.stopPrank();
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(box), 1);
        vm.startPrank(allocator);

        box.repay(fundingAdapter, fundingData, type(uint256).max);

        box.withdrawCollateral(fundingAdapter, fundingData, ptBalance);
        assertEq(ptusr25sep.balanceOf(address(box)), 1010280676747326095928, "ptusr25sep are back in the Box");

        vm.stopPrank();
    }


    function testBoxWind() public {
        uint256 USDC_1000 = 1000 * 10**6;
        uint256 USDC_500 = 500 * 10**6;
        
        vm.prank(curator);
        box.setIsAllocator(address(box), true);

        // Get some USDC in Box
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(this), USDC_1000); // Transfer 1000 USDC to this contract
        usdc.approve(address(box), USDC_1000);
        box.deposit(USDC_1000, address(this)); // Deposit 1000 USDC

        vm.startPrank(allocator);

        box.allocate(ptusr25sep, USDC_1000, swapper, "");
        uint256 ptBalance = ptusr25sep.balanceOf(address(box));

        assertEq(usdc.balanceOf(address(box)), 0, "No more USDC in the Box");
        assertEq(ptBalance, 1010280676747326095928, "ptusr25sep in the Box");

        box.supplyCollateral(fundingAdapter, fundingData, ptBalance);

        assertEq(ptusr25sep.balanceOf(address(box)), 0, "No more ptusr25sep in the Box");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), ptBalance, "Collateral is correct");

        FlashLoanMorpho flashloanProvider = new FlashLoanMorpho();

        // expect revert
        //flashloanProvider.wind(box, morpho, borrow, borrowData, swapper, "", ptusr25sep, usdc, USDC_500);

        vm.stopPrank();
        vm.prank(curator);
        box.setIsAllocator(address(flashloanProvider), true);
        vm.startPrank(allocator);

        flashloanProvider.wind(box, morpho, fundingAdapter, fundingData, swapper, "", ptusr25sep, usdc, USDC_500);

        assertEq(fundingAdapter.debt(fundingData, address(box)), USDC_500 + 1, "Debt is correct");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), 1515398374089157807752, "Collateral after wind is correct");

        flashloanProvider.unwind(box, morpho, fundingAdapter, fundingData, swapper, "", 
            ptusr25sep, fundingAdapter.collateral(fundingData, address(box)), 
            usdc, type(uint256).max);

        vm.stopPrank();
    }

}