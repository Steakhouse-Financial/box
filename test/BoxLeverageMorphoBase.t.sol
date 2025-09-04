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
    Box boxEth;
    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);

    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 wsteth = IERC20(0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452);
    IOracle wstethOracle94 = IOracle(0x4A11590e5326138B514E08A9B52202D42077Ca65); // vs WETH  
    IOracle wstethOracle96 = IOracle(0xaE10cbdAa587646246c8253E4532A002EE4fa7A4); // vs WETH

    ISwapper swapper = ISwapper(0x5C9dA86ECF5B35C8BF700a31a51d8a63fA53d1f6);

    IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address irm = 0x46415998764C29aB2a25CbeA6254146D50D22687;

    BorrowMorpho fundingAdapter;
    MarketParams marketParams;
    bytes fundingData;
    bytes32 fundingId;

    BorrowMorpho fundingAdapterEth;
    MarketParams marketParamsEth1;
    bytes fundingDataEth1;
    bytes32 fundingIdEth1;

    MarketParams marketParamsEth2;
    bytes fundingDataEth2;
    bytes32 fundingIdEth2;

    /// @notice Will setup Peaty Base investing in bbqUSDC, box1 (stUSD) and box (PTs)
   function setUp() public {
        // Fork base on a  Sept 4th, 2025
        uint256 forkId = vm.createFork(vm.rpcUrl("base"), 35116463);  
        vm.selectFork(forkId);

        // Creating Box USDC which will invest in PT-USR-25SEP
        string memory name = "Box USDC";
        string memory symbol = "BOX_USDC";
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


        // Creating Box ETH which will invest in wstETH
        name = "Box ETH";
        symbol = "BOX_ETH";
        maxSlippage = 0.01 ether; // 1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        boxEth = new Box(
            address(weth),
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
        boxEth.changeGuardian(guardian);
        boxEth.addCollateral(wsteth, wstethOracle94);
        boxEth.setIsAllocator(address(allocator), true);
        boxEth.addFeeder(address(this));

        fundingAdapterEth = new BorrowMorpho();
        marketParamsEth1 = MarketParams(address(weth), address(wsteth), address(wstethOracle94), irm, 945000000000000000);
        // And the funding facility
        fundingDataEth1 = fundingAdapterEth.morphoMarketToData(morpho, marketParamsEth1);
        fundingIdEth1 = boxEth.fundingId(fundingAdapterEth, fundingDataEth1);
        boxEth.addFunding(fundingAdapterEth, fundingDataEth1);

        marketParamsEth2 = MarketParams(address(weth), address(wsteth), address(wstethOracle96), irm, 965000000000000000);
        // And the funding facility
        fundingDataEth2 = fundingAdapterEth.morphoMarketToData(morpho, marketParamsEth2);
        fundingIdEth2 = boxEth.fundingId(fundingAdapterEth, fundingDataEth2);
        boxEth.addFunding(fundingAdapterEth, fundingDataEth2);

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

        FlashLoanMorpho flashloanProvider = new FlashLoanMorpho(morpho);

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
            flashloanProvider.wind(box, fundingAdapter, fundingData, swapper, "", ptusr25sep, usdc, 1);

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
        assertEq(ptBalance, 1005863679192785855851, "ptusr25sep in the Box");
        assertEq(totalAssets, 999828627, "totalAssets in the Box after ptusr25sep allocation");

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
        assertEq(ptusr25sep.balanceOf(address(box)), 1005863679192785855851, "ptusr25sep are back in the Box");

        vm.stopPrank();
    }


    function testBoxWind() public {
        uint256 USDC_1000 = 1000 * 10**6;
        uint256 USDC_500 = 500 * 10**6;
        
        // TODO: We shouldn't have to do this
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
        assertEq(ptBalance, 1005863679192785855851, "ptusr25sep in the Box");

        box.supplyCollateral(fundingAdapter, fundingData, ptBalance);

        assertEq(ptusr25sep.balanceOf(address(box)), 0, "No more ptusr25sep in the Box");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), ptBalance, "Collateral is correct");

        FlashLoanMorpho flashloanProvider = new FlashLoanMorpho(morpho);

        vm.stopPrank();
        vm.prank(curator);
        box.setIsAllocator(address(flashloanProvider), true);
        vm.startPrank(allocator);

        flashloanProvider.wind(box, fundingAdapter, fundingData, swapper, "", ptusr25sep, usdc, USDC_500);

        assertEq(fundingAdapter.debt(fundingData, address(box)), USDC_500 + 1, "Debt is correct");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), 1508804269763505704594, "Collateral after wind is correct");

        flashloanProvider.unwind(box, fundingAdapter, fundingData, swapper, "", 
            ptusr25sep, fundingAdapter.collateral(fundingData, address(box)), 
            usdc, type(uint256).max);

        assertEq(fundingAdapter.debt(fundingData, address(box)), 0, "Debt is fully repaid");
        assertEq(fundingAdapter.collateral(fundingData, address(box)), 0, "No collateral left on Morpho");
        assertEq(ptusr25sep.balanceOf(address(box)), 0, "No ptusr25sep are in the Box");
        assertEq(usdc.balanceOf(address(box)), 999371412, "USDC is back in the Box");

        vm.stopPrank();
    }


    function testShift() public {
        vm.prank(curator);
        boxEth.setIsAllocator(address(boxEth), true);

        // Get some USDC in Box
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        weth.transfer(address(this), 1 ether);
        weth.approve(address(boxEth), 1 ether);
        boxEth.deposit(1 ether, address(this));

        vm.startPrank(allocator);

        // Swap WETH to wstETH
        boxEth.allocate(wsteth, 1 ether, swapper, "");
        
        uint256 wstEthBalance = wsteth.balanceOf(address(boxEth));
        assertEq(wstEthBalance, 825488650470599462, "wstETH in the Box");

        // Supply wsteth collateral to first market
        boxEth.supplyCollateral(fundingAdapterEth, fundingDataEth1, wstEthBalance);
        assertEq(fundingAdapterEth.collateral(fundingDataEth1, address(boxEth)), wstEthBalance);
        assertEq(fundingAdapterEth.collateral(fundingDataEth2, address(boxEth)), 0 ether);
        assertEq(fundingAdapterEth.ltv(fundingDataEth1, address(boxEth)), 0 ether);

        // Prepare flashloan facility
        FlashLoanMorpho flashloanProvider = new FlashLoanMorpho(morpho);
        vm.stopPrank();
        vm.prank(curator);
        boxEth.setIsAllocator(address(flashloanProvider), true);
        vm.startPrank(allocator);

        // Leverage on the first market
        flashloanProvider.wind(boxEth, fundingAdapterEth, fundingDataEth1, swapper, "", wsteth, weth, 0.5 ether);

        assertEq(fundingAdapterEth.collateral(fundingDataEth1, address(boxEth)), 1238232915944902834);
        assertEq(fundingAdapterEth.collateral(fundingDataEth2, address(boxEth)), 0);
        assertEq(fundingAdapterEth.debt(fundingDataEth1, address(boxEth)), 500000000000000001);
        assertEq(fundingAdapterEth.debt(fundingDataEth2, address(boxEth)), 0 ether);
        assertEq(fundingAdapterEth.ltv(fundingDataEth1, address(boxEth)), 332938470795156227);

        // Shift all the position to the second market
        flashloanProvider.shift(boxEth, fundingAdapterEth, fundingDataEth1, fundingAdapterEth, fundingDataEth2, 
            wsteth, type(uint256).max, weth, type(uint256).max);

        assertEq(fundingAdapterEth.collateral(fundingDataEth1, address(boxEth)), 0);
        assertEq(fundingAdapterEth.collateral(fundingDataEth2, address(boxEth)), 1238232915944902834);
        assertEq(fundingAdapterEth.debt(fundingDataEth1, address(boxEth)), 0 ether);
        assertEq(fundingAdapterEth.debt(fundingDataEth2, address(boxEth)), 500000000000000002);
        assertEq(fundingAdapterEth.ltv(fundingDataEth1, address(boxEth)), 0 ether);
        assertEq(fundingAdapterEth.ltv(fundingDataEth2, address(boxEth)), 332938470795156228);

        vm.stopPrank();

    }

}