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
import {BorrowMorpho} from "../src/BorrowMorpho.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IBox, LoanFacility} from "../src/interfaces/IBox.sol";

/// @notice Minimal Aave v3 Addresses Provider to obtain the Pool
interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}

/**
 * @title Testing suite for cross-protocol leverage using both Aave and Morpho on Mainnet
 */
contract BoxLeverageMainnetTest is Test {
    using BoxLib for Box;
    
    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);
    
    // Mainnet addresses
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // Aave v3 PoolAddressesProvider (Mainnet)
    address constant MORPHO_ADDRESS = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue (Mainnet)
    
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // Mainnet USDC
    IERC20 ptSusde25Sep = IERC20(0x9F56094C450763769BA0EA9Fe2876070c0fD5F77); // PT-sUSDe-25SEP2025
    IOracle ptSusdeOracle = IOracle(0x5139aa359F7F7FdE869305e8C7AD001B28E1C99a); // Oracle for PT-sUSDe-25SEP2025
    
    ISwapper swapper = ISwapper(0x5C9dA86ECF5B35C8BF700a31a51d8a63fA53d1f6); // Same swapper as Base
    
    IPool aavePool;
    IMorpho morpho;
    
    // Morpho market ID provided by user
    bytes32 constant MORPHO_MARKET_ID = 0x3e37bd6e02277f15f93cd7534ce039e60d19d9298f4d1bc6a3a4f7bf64de0a1c;
    
    function setUp() public {
        // Fork mainnet from specific block
        uint256 forkId = vm.createFork(vm.rpcUrl("mainnet"), 23294087);
        vm.selectFork(forkId);
        
        // Get protocol instances
        aavePool = IPool(IPoolAddressesProvider(AAVE_PROVIDER).getPool());
        morpho = IMorpho(MORPHO_ADDRESS);
    }
    
    function testCrossProtocolBorrowing() public {
        // Deploy Box for USDC
        Box box = new Box(
            address(usdc),
            owner,
            curator,
            "Cross Protocol Box",
            "XPROT_BOX",
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
        
        // Setup Aave adapter with e-mode 17 for stablecoins
        BorrowAave aaveAdapter = new BorrowAave();
        uint8 eModeCategory = 17;
        bytes memory aaveData = aaveAdapter.aaveParamsToDataWithEMode(
            aavePool, 
            address(usdc), 
            address(ptSusde25Sep), 
            2, 
            eModeCategory
        );
        box.addFunding(aaveAdapter, aaveData);
        
        // Setup Morpho adapter - need to get market params from market ID
        BorrowMorpho morphoAdapter = new BorrowMorpho();
        
        // Get market params from the market ID
        MarketParams memory marketParams = _getMarketParamsFromId(MORPHO_MARKET_ID);
        bytes memory morphoData = morphoAdapter.morphoMarketToData(morpho, marketParams);
        box.addFunding(morphoAdapter, morphoData);
        
        vm.stopPrank();
        
        // Supply PT-sUSDe tokens for both protocols
        uint256 ptAmount = 2000 ether; // 2000 PT tokens total
        deal(address(ptSusde25Sep), address(box), ptAmount);
        
        // Fund Box with initial USDC
        deal(address(usdc), address(this), 1000e6);
        usdc.approve(address(box), 1000e6);
        box.deposit(1000e6, address(this));
        
        uint256 navBefore = box.totalAssets();
        console2.log("NAV before cross-protocol operations:", navBefore / 1e6, "USDC");
        
        vm.startPrank(allocator);
        
        // Supply 1000 PT to Aave
        uint256 aaveCollateral = 1000 ether;
        box.supplyCollateral(aaveAdapter, aaveData, aaveCollateral);
        console2.log("Supplied", aaveCollateral / 1e18, "PT-sUSDe to Aave");
        
        // Supply 1000 PT to Morpho
        uint256 morphoCollateral = 1000 ether;
        box.supplyCollateral(morphoAdapter, morphoData, morphoCollateral);
        console2.log("Supplied", morphoCollateral / 1e18, "PT-sUSDe to Morpho");
        
        // Borrow from Aave at 70% LTV
        (uint256 aaveCollateralValue, , , , , ) = aavePool.getUserAccountData(address(box));
        uint256 aaveBorrowAmount = (aaveCollateralValue * 70) / 100 / 100; // 70% LTV in USDC terms
        box.borrow(aaveAdapter, aaveData, aaveBorrowAmount);
        console2.log("Borrowed", aaveBorrowAmount / 1e6, "USDC from Aave at 70% LTV");
        
        // Borrow from Morpho at 60% LTV
        uint256 morphoCollateralAmount = morphoAdapter.collateral(morphoData, address(box));
        // Estimate collateral value (assuming PT-sUSDe ≈ 1 USD)
        uint256 morphoBorrowAmount = (morphoCollateralAmount * 60) / 100; // 60% LTV
        // Convert to USDC decimals (6 decimals vs 18)
        morphoBorrowAmount = morphoBorrowAmount / 1e12;
        box.borrow(morphoAdapter, morphoData, morphoBorrowAmount);
        console2.log("Borrowed", morphoBorrowAmount / 1e6, "USDC from Morpho at ~60% LTV");
        
        // Verify final state
        uint256 aaveLTV = aaveAdapter.ltv(aaveData, address(box));
        uint256 morphoLTV = morphoAdapter.ltv(morphoData, address(box));
        uint256 navAfter = box.totalAssets();
        
        console2.log("NAV after operations:", navAfter / 1e6, "USDC");
        console2.log("Aave LTV:", aaveLTV * 100 / 1e18, "%");
        console2.log("Morpho LTV:", morphoLTV * 100 / 1e18, "%");
        console2.log("Total borrowed:", (aaveBorrowAmount + morphoBorrowAmount) / 1e6, "USDC");
        
        // Verify NAV stability - borrowing assets at fair value should keep NAV constant
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "NAV should remain approximately constant");
        
        // Verify both protocols show reasonable LTVs
        assertLt(aaveLTV, 0.8e18, "Aave LTV should be under 80%");
        assertLt(morphoLTV, 0.8e18, "Morpho LTV should be under 80%");
        
        // Verify we have the borrowed USDC
        uint256 totalExpected = 1000e6 + aaveBorrowAmount + morphoBorrowAmount;
        uint256 actualBalance = usdc.balanceOf(address(box));
        assertApproxEqAbs(actualBalance, totalExpected, 1e6, "Should have borrowed USDC plus initial deposit");
        
        vm.stopPrank();
    }
    
    /**
     * @dev Get market parameters for the specified Morpho market ID
     * Market parameters queried from Morpho Blue on mainnet
     */
    function _getMarketParamsFromId(bytes32 marketId) internal pure returns (MarketParams memory) {
        // Market parameters for 0x3e37bd6e02277f15f93cd7534ce039e60d19d9298f4d1bc6a3a4f7bf64de0a1c
        // Queried from Morpho: USDC/PT-sUSDe market with 91.5% LLTV
        return MarketParams({
            loanToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            collateralToken: 0x9F56094C450763769BA0EA9Fe2876070c0fD5F77, // PT-sUSDe-25SEP2025
            oracle: 0x5139aa359F7F7FdE869305e8C7AD001B28E1C99a, // PT-sUSDe Oracle
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, // Interest Rate Model
            lltv: 915000000000000000 // 91.5% LLTV (9.15e17)
        });
    }
}