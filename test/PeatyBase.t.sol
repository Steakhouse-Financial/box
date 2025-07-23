// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {Box} from "../src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Errors} from "../src/lib/Errors.sol";
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {MorphoVaultV1Adapter} from "@vault-v2/src/adapters/MorphoVaultV1Adapter.sol";

import {IBoxAdapter} from "../src/interfaces/IBoxAdapter.sol";
import {IBoxAdapterFactory} from "../src/interfaces/IBoxAdapterFactory.sol";
import {BoxAdapterFactory} from "../src/BoxAdapterFactory.sol";
import {BoxAdapter} from "../src/BoxAdapter.sol";
import {VaultV2Lib} from "../src/lib/VaultV2Lib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {MorphoVaultV1AdapterLib} from "../src/lib/MorphoVaultV1Lib.sol";

contract MockSwapper is ISwapper {
    uint256 public slippagePercent = 0; // 0% slippage by default
    bool public shouldRevert = false;

    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {
    }
}

/**
 * @title Peaty on Base integration test
 */
contract PeatyBaseTest is Test {
    using BoxLib for Box;
    using VaultV2Lib for VaultV2;
    using MorphoVaultV1AdapterLib for MorphoVaultV1Adapter;
    
    VaultV2 vault;
    Box box1;
    Box box2;
    IBoxAdapter adapter1;
    IBoxAdapter adapter2;
    MorphoVaultV1Adapter bbqusdcAdapter;

    address owner = address(0x1);
    address curator = address(0x2);
    address guardian = address(0x3);
    address allocator = address(0x4);
    address user = address(0x5);

    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    IERC4626 bbqusdc = IERC4626(0xBeeFa74640a5f7c28966cbA82466EED5609444E0); // bbqUSDC on Base
    
    IERC4626 stusd = IERC4626(0x0022228a2cc5E7eF0274A7Baa600d44da5aB5776);
    IOracle stusdOracle = IOracle(0x2eede25066af6f5F2dfc695719dB239509f69915);
    
    IERC20 ptusr25sep = IERC20(0xa6F0A4D18B6f6DdD408936e81b7b3A8BEFA18e77);
    IOracle ptusr25sepOracle = IOracle(0x6AdeD60f115bD6244ff4be46f84149bA758D9085);
    
    ISwapper swapper = ISwapper(0xFFF5082CE0E7C04BCc645984A94d4e4C0687Aa60);

    IBoxAdapterFactory boxAdapterFactory;

    /// @notice Will setup Peaty Base investing in bbqUSDC, box1 (stUSD) and box2 (PTs)
   function setUp() public {
        // Fork base on June 12th, 2025
        uint256 forkId = vm.createFork(vm.rpcUrl("base"), 31463931);
        vm.selectFork(forkId);

        bytes memory data;

        MockSwapper backupSwapper = new MockSwapper();
        boxAdapterFactory = new BoxAdapterFactory();

        vault = new VaultV2(address(owner), address(usdc));

        vm.prank(owner);
        vault.setCurator(address(curator));

        vm.prank(curator);
        vault.addAllocator(address(allocator)); 

        // Setting the vault to use bbqUSDC as the asset
        bbqusdcAdapter = new MorphoVaultV1Adapter(
            address(vault), 
            address(bbqusdc)
        );

        vm.startPrank(curator);
        vault.addCollateral(address(bbqusdcAdapter), bbqusdcAdapter.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 100% relative cap
        vm.stopPrank();

        vm.startPrank(allocator);
        vault.setLiquidityAdapterAndData(address(bbqusdcAdapter), "");
        vm.stopPrank();

        // Creating Box 1 which will invest in stUSD
        string memory name = "Box 1";
        string memory symbol = "BOX1";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        box1 = new Box(
            usdc, 
            address(owner), 
            address(curator), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );

        // Creating the ERC4626 adapter between the vault and box1
        adapter1 = boxAdapterFactory.createBoxAdapter(
            address(vault), 
            box1
        );

        // Allow box 1 to invest in stUSD
        vm.startPrank(curator);
        box1.changeGuardian(guardian);
        box1.addCollateral(stusd, stusdOracle);
        box1.setIsAllocator(address(allocator), true);
        box1.addFeeder(address(adapter1));
        vault.addCollateral(address(adapter1), adapter1.data(), 1_000_000 * 10**6, 1 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vm.stopPrank();


        // Creating Box 2 which will invest in PT-USR-25SEP
        name = "Box 2";
        symbol = "BOX2";
        maxSlippage = 0.01 ether; // 1%
        slippageEpochDuration = 7 days;
        shutdownSlippageDuration = 10 days;
        box2 = new Box(
            usdc, 
            address(owner), 
            address(curator), 
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );
        // Creating the ERC4626 adapter between the vault and box2
        adapter2 = boxAdapterFactory.createBoxAdapter(
            address(vault), 
            box2
        );

        // Allow box 2 to invest in PT-USR-25SEP
        vm.startPrank(curator);
        box2.changeGuardian(guardian);
        box2.addCollateral(ptusr25sep, ptusr25sepOracle);
        box2.setIsAllocator(address(allocator), true);
        box2.addFeeder(address(adapter2));
        vault.addCollateral(address(adapter2), adapter2.data(), 1_000_000 * 10**6, 0.5 ether); // 1,000,000 USDC absolute cap and 50% relative cap
        vault.setPenaltyFee(address(adapter2), 0.02 ether); // 2% penalty
        vm.stopPrank();
    }

    /////////////////////////////
    /// SCENARIOS
    /////////////////////////////

    /// @notice Test a simple flow
    function testDepositAllocationRedeem() public {
        uint256 USDC_1000 = 1000 * 10**6;
        uint256 USDC_500 = 500 * 10**6;
        uint256 USDC_250 = 250 * 10**6;

        // Cleaning the balance of USDC in case of
        usdc.transfer(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb, usdc.balanceOf(address(this))); 

        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(this), USDC_1000); // Transfer 1000 USDC to this contract
        assertEq(usdc.balanceOf(address(this)), USDC_1000);
        assertEq(vault.balanceOf(address(this)), 0);

        //////////////////////////////////////////////////////
        // Depositing and investing in bqqUSDC
        //////////////////////////////////////////////////////

        // Depositing 1000 USDC into the vault
        usdc.approve(address(vault), USDC_1000); // Approve the vault to spend USDC
        vault.deposit(USDC_1000, address(this)); // Deposit 1000 USDC into the vault
        assertEq(usdc.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(address(this)), 1000 ether);

        // Allocating 1000 USDC to the box1 as it is the liquidity adapter
        assertEq(bbqusdc.balanceOf(address(bbqusdcAdapter)), 
            bbqusdc.previewDeposit(USDC_1000), 
            "Allocation to bbqUSDC should result in gettiong the shares");

        //////////////////////////////////////////////////////
        // Allocating 500 USDC to stUSD in Box1
        //////////////////////////////////////////////////////
        vm.startPrank(allocator);

        vault.deallocate(address(bbqusdcAdapter), "", USDC_500);
        vault.allocate(address(adapter1), "", USDC_500);

        assertEq(usdc.balanceOf(address(box1)), USDC_500,
            "500 USDC deposited in the Box1 contract but not yet invested");
        
        box1.allocate(stusd, USDC_250, swapper);
        assertEq(usdc.balanceOf(address(box1)), USDC_250,
            "Only 250 USDC left as half was allocated to stUSD");

        box1.allocate(stusd, USDC_250, swapper);
        assertEq(usdc.balanceOf(address(box1)), 0,
            "No USDC left as all was allocated to stUSD");
        assertEq(stusd.previewRedeem(stusd.balanceOf(address(box1))), 500 ether - 2,
            "Almost 500 USDA equivalent of stUSD (2 round down)");

        vm.stopPrank();


        //////////////////////////////////////////////////////
        // Allocating 500 USDC to Box2
        //////////////////////////////////////////////////////

        vm.startPrank(allocator);

        uint256 remainingUSDC = bbqusdc.previewRedeem(bbqusdc.balanceOf(address(bbqusdcAdapter)));

        vault.deallocate(address(bbqusdcAdapter), "", remainingUSDC);
        vault.allocate(address(adapter2), "", remainingUSDC );

        assertEq(usdc.balanceOf(address(box2)), remainingUSDC,
            "All USDC in bbqUSDC is now is Box2");

        vm.stopPrank();
        

        //////////////////////////////////////////////////////
        // Unwinding
        //////////////////////////////////////////////////////

        // No liquidity is available so we except a revert here
        vm.expectRevert();
        vault.withdraw(10 * 10**6, address(this), address(this));

        // We exit stUSD but leave it in box1 for now
        vm.startPrank(allocator);
        box1.deallocate(stusd, stusd.balanceOf(address(box1)), swapper);
        vm.stopPrank();

        vm.expectRevert();
        vault.withdraw(10 * 10**6, address(this), address(this));

        // We deallocate from box 1 to the vault liquidity sleeve
        uint256 box1Balance = usdc.balanceOf(address(box1));
        vm.prank(allocator);
        vault.deallocate(address(adapter1), "", box1Balance);
        vm.prank(allocator);
        vault.allocate(address(bbqusdcAdapter), "", box1Balance);
        vault.withdraw(USDC_500 - 2, address(this), address(this));
        assertEq(usdc.balanceOf(address(this)), USDC_500 - 2);

        // Testing the force deallocate
        // We are transfering the vault shares to an EOA
        uint256 shares = vault.balanceOf(address(this));
        vault.transfer(user, shares);

        // Impersonating the non permissioned user
        vm.startPrank(user);

        vm.expectRevert();
        vault.redeem(shares, address(this), address(this));

        vault.forceDeallocate(address(adapter2), "", usdc.balanceOf(address(box2)), address(user));
        assertLt(vault.balanceOf(address(user)), shares, "User lost some shares due to force deallocation");
        remainingUSDC = vault.previewRedeem(vault.balanceOf(address(user)));
        vault.redeem(vault.balanceOf(address(user)), address(user), address(user));
        assertEq(usdc.balanceOf(address(user)), remainingUSDC, "User should have received the USDC after redeem");

        console.log("Vault total assets: ", vault.totalAssets());
        console.log("Box 1 total assets: ", box1.totalAssets());
        console.log("Box 2 total assets: ", box2.totalAssets());
        console.log("bbqUSD adapter total assets: ", bbqusdc.convertToAssets(bbqusdc.balanceOf(address(bbqusdcAdapter))));
        console.log("Liquidity total assets: ", usdc.balanceOf(address(vault)));
        console.log("Vault total supply: ", vault.totalSupply());

        assertEq(vault.totalSupply(), 0, "Vault should have no shares left after redeeming all");

        vm.stopPrank();
    }



    /// @notice Test guardian controlled shutdown
    function testGuardianControlledShutdown() public {
        uint256 USDC_1000 = 1000 * 10**6;
        uint256 USDC_500 = 500 * 10**6;
        uint256 USDC_250 = 250 * 10**6;

        // Cleaning the balance of USDC in case of
        usdc.transfer(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb, usdc.balanceOf(address(this))); 

        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(user), USDC_1000); // Transfer 1000 USDC to this contract
        assertEq(usdc.balanceOf(address(user)), USDC_1000);
        assertEq(vault.balanceOf(address(user)), 0);

        //////////////////////////////////////////////////////
        // Setting up the stage
        //////////////////////////////////////////////////////

        // Depositing 1000 USDC into the vault
        vm.startPrank(user);
        usdc.approve(address(vault), USDC_1000); // Approve the vault to spend USDC
        vault.deposit(USDC_1000, address(user)); // Deposit 1000 USDC into the vault
        vm.stopPrank();

        assertEq(bbqusdc.balanceOf(address(bbqusdcAdapter)), 985763304395789692531);

        // Compensate for rounding errors and keep things clean
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(vault), 1); // Transfer 1 to convert the conversion loss

        vm.startPrank(allocator);
        vault.deallocate(address(bbqusdcAdapter), "", bbqusdc.previewRedeem(985763304395789692531)); 
        assertEq(usdc.balanceOf(address(vault)), USDC_1000);
        vault.allocate(address(adapter1), "", USDC_1000);  
        box1.allocate(stusd, USDC_1000, swapper);
        assertEq(stusd.previewRedeem(stusd.balanceOf(address(box1))), 1000 ether - 1,
            "Almost 1000 USDA equivalent of stUSD (1 round down)");

        vm.stopPrank();


        //////////////////////////////////////////////////////
        // Now the guardian need to clean up the mess
        //////////////////////////////////////////////////////
        vm.startPrank(guardian);
        vm.stopPrank();
    }


    /// @notice Test impact of a loss in a Box
    function testBoxLoss() public {
        uint256 USDC_1000 = 1000 * 10**6;
        uint256 USDC_500 = 500 * 10**6;


        //////////////////////////////////////////////////////
        // Setup 500 USDC liquid and 500 USDC in Box1
        //////////////////////////////////////////////////////

        // Disable bbqUSDC as liquidity
        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(0), "");

        // We invest 50 USDC
        vm.prank(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb); // Morpho Blue
        usdc.transfer(address(this), USDC_1000); // Transfer 1000 USDC to this contract
        usdc.approve(address(vault), USDC_1000); // Approve the vault to spend USDC
        vault.deposit(USDC_1000, address(this)); // Deposit 1000 USDC into the vault

        vm.prank(allocator);
        vault.allocate(address(adapter1), "", USDC_500);

        assertEq(usdc.balanceOf(address(box1)), USDC_500,
            "500 USDC deposited in the Box1 contract but not yet invested");
        assertEq(usdc.balanceOf(address(vault)), USDC_500,
            "500 USDC liquid in the vault");
        assertEq(vault.totalAssets(), USDC_1000,
            "Vault value is 1000 USDC");

        //////////////////////////////////////////////////////
        // Simulating a loss in Box1
        //////////////////////////////////////////////////////

        vm.prank(address(box1));
        usdc.transfer(address(this), USDC_500);
        assertEq(usdc.balanceOf(address(box1)), 0,
            "No more USDC in the Box1 contract");        
        assertEq(box1.totalAssets(), 0,
            "Total assets at Box1 level is 0");        
        assertEq(vault.totalAssets(), USDC_1000,
            "Vault value is still 1000 USDC");

        // Loss realization doesn't work as it wasn't reciognized first
        vault.realizeLoss(address(adapter1), "");
        assertEq(vault.totalAssets(), USDC_1000,
            "Vault value is still 1000 USDC");

        // Not everyone can recognize the loss
        vm.expectRevert(IBoxAdapter.NotAuthorized.selector);
        adapter1.recognizeLoss();

        // Guardian can
        vm.startPrank(guardian);
        // TODO: Check event
        adapter1.recognizeLoss();
        vm.stopPrank();

        // Also make sure that curator can
        vm.startPrank(curator);
        // TODO: Check event
        adapter1.recognizeLoss();
        vm.stopPrank();
        
        assertEq(vault.totalAssets(), USDC_1000,
            "Vault value is still 1000 USDC even after recognize");

        vault.realizeLoss(address(adapter1), "");
        assertEq(vault.totalAssets(), USDC_500,
            "Vault value is 500 USDC after loss realization");

        // We check that calling realizeLoss again doesn't impact anything
        vault.realizeLoss(address(adapter1), "");        
        assertEq(vault.totalAssets(), USDC_500,
            "Vault value is 500 USDC after loss realization");

    }
}