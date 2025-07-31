// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Box} from "../src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Errors} from "../src/lib/Errors.sol";
import "../src/lib/ConstantsLib.sol";

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockOracle is IOracle {
    uint256 public price = 1e36; // 1:1 price

    function setPrice(uint256 _price) external {
        price = _price;
    }
}

contract MockSwapper is ISwapper {
    uint256 public slippagePercent = 0; // 0% slippage by default
    bool public shouldRevert = false;

    function setSlippage(uint256 _slippagePercent) external {
        slippagePercent = _slippagePercent;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {
        require(!shouldRevert, "Swapper: Forced revert");
        
        input.transferFrom(msg.sender, address(this), amountIn);
        
        // Apply slippage
        uint256 amountOut = amountIn * (100 - slippagePercent) / 100;
        output.transfer(msg.sender, amountOut);
    }
}

contract MaliciousSwapper is ISwapper {
    uint256 public step = 5; // level of recursion
    Box public box;
    
    function setBox(Box _box) external {
        box = _box;
    }

    function sell(IERC20 input, IERC20 output, uint256 amountIn) external {        
        input.transferFrom(msg.sender, address(this), amountIn);
        
        step--;
        
        if(step > 0) {
            // Recursively call sell to simulate reentrancy
            box.allocate(output, amountIn, this);
        }


        if(step == 0) {
            output.transfer(msg.sender, amountIn);
        }

        step++;

    }
}

contract BoxTest is Test {
    Box public box;
    MockERC20 public currency;
    MockERC20 public asset1;
    MockERC20 public asset2;
    MockERC20 public asset3;
    MockOracle public oracle1;
    MockOracle public oracle2;
    MockOracle public oracle3;
    MockSwapper public swapper;
    MockSwapper public backupSwapper;
    MockSwapper public badSwapper;
    MaliciousSwapper public maliciousSwapper;

    address public owner = address(0x1);
    address public allocator = address(0x2);
    address public curator = address(0x3);
    address public guardian = address(0x4);
    address public feeder = address(0x5);
    address public user1 = address(0x6);
    address public user2 = address(0x7);
    address public nonAuthorized = address(0x8);

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Allocation(IERC20 indexed token, uint256 amount, ISwapper indexed swapper);
    event Deallocation(IERC20 indexed token, uint256 amount, ISwapper indexed swapper);
    event Reallocation(IERC20 indexed fromToken, IERC20 indexed toToken, uint256 amount, ISwapper indexed swapper);
    event Shutdown(address indexed guardian);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        currency = new MockERC20("USDC", "USDC");
        asset1 = new MockERC20("Asset1", "ASSET1");
        asset2 = new MockERC20("Asset2", "ASSET2");
        asset3 = new MockERC20("Asset3", "ASSET3");
        oracle1 = new MockOracle();
        oracle2 = new MockOracle();
        oracle3 = new MockOracle();
        swapper = new MockSwapper();
        backupSwapper = new MockSwapper();
        badSwapper = new MockSwapper();
        maliciousSwapper = new MaliciousSwapper();

        // Configure production parameters
        string memory name = "Box Shares";
        string memory symbol = "BOX";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;
        
        box = new Box(
            currency, 
            owner, 
            owner, // Initially owner is also curator
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration
        );

        // Setup roles and investment tokens using new timelock pattern
        // Note: owner is initially the curator, so owner can submit
        vm.startPrank(owner);
        // Set curator
        box.setCurator(curator);
        vm.stopPrank();


        vm.startPrank(curator);
       
        // Add guardian
        bytes memory guardianData = abi.encodeWithSelector(box.setGuardian.selector, guardian);
        box.submit(guardianData);
        box.setGuardian(guardian); 

        
        // Add feeder role
        bytes memory feederData = abi.encodeWithSelector(box.setIsFeeder.selector, feeder, true);
        box.submit(feederData);
        (bool success,) = address(box).call(feederData);
        require(success, "Failed to set feeder");

        // Add allocator role
        bytes memory allocatorData = abi.encodeWithSelector(box.setIsAllocator.selector, allocator, true);
        box.submit(allocatorData);
        (success,) = address(box).call(allocatorData);
        require(success, "Failed to set allocator");

        // Add allocator role
        bytes memory maliciousSwapperData = abi.encodeWithSelector(box.setIsAllocator.selector, maliciousSwapper, true);
        box.submit(maliciousSwapperData);
        (success,) = address(box).call(maliciousSwapperData);
        require(success, "Failed to set allocator");

        // Add investment tokens
        bytes memory asset1Data = abi.encodeWithSelector(box.addInvestmentToken.selector, asset1, oracle1);
        box.submit(asset1Data);
        (success,) = address(box).call(asset1Data);
        require(success, "Failed to add asset1");

        bytes memory asset2Data = abi.encodeWithSelector(box.addInvestmentToken.selector, asset2, oracle2);
        box.submit(asset2Data);
        (success,) = address(box).call(asset2Data);
        require(success, "Failed to add asset2");

        // Add user1 as feeder so they can withdraw
        bytes memory userData = abi.encodeWithSelector(box.setIsFeeder.selector, user1, true);
        box.submit(userData);
        (bool userSuccess,) = address(box).call(userData);
        require(userSuccess, "Failed to set user1 as feeder");


        // Add timelocks
        box.increaseTimelock(box.setMaxSlippage.selector, 1 days);
        box.increaseTimelock(box.setGuardian.selector, 1 days);


        vm.stopPrank();

        // Mint tokens for testing
        currency.mint(feeder, 10000e18);
        currency.mint(user1, 10000e18);
        currency.mint(user2, 10000e18);
        asset1.mint(address(swapper), 10000e18);
        asset2.mint(address(swapper), 10000e18);
        asset3.mint(address(swapper), 10000e18);
        asset1.mint(address(backupSwapper), 10000e18);
        asset2.mint(address(backupSwapper), 10000e18);
        asset3.mint(address(backupSwapper), 10000e18);
        asset1.mint(address(badSwapper), 10000e18);
        asset2.mint(address(badSwapper), 10000e18);
        asset3.mint(address(badSwapper), 10000e18);
        asset1.mint(address(maliciousSwapper), 10000e18);
        
        // Mint currency for swappers to provide liquidity
        currency.mint(address(swapper), 10000e18);
        currency.mint(address(backupSwapper), 10000e18);
        currency.mint(address(badSwapper), 10000e18);
    }

    /////////////////////////////
    /// BASIC ERC4626 TESTS
    /////////////////////////////

    function testERC4626Compliance() public {
        // Test asset()
        assertEq(box.asset(), address(currency));

        // Test initial state
        assertEq(box.totalAssets(), 0);
        assertEq(box.totalSupply(), 0);
        assertEq(box.convertToShares(100e18), 100e18); // 1:1 when empty
        assertEq(box.convertToAssets(100e18), 100e18); // 1:1 when empty
        
        // Test max functions when not shutdown
        assertEq(box.maxDeposit(feeder), type(uint256).max);
        assertEq(box.maxMint(feeder), type(uint256).max);
        assertEq(box.maxWithdraw(feeder), 0); // No shares yet
        assertEq(box.maxRedeem(feeder), 0); // No shares yet
    }

    function testDeposit() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(feeder, feeder, 100e18, 100e18);
        
        uint256 shares = box.deposit(100e18, feeder);
        vm.stopPrank();

        assertEq(shares, 100e18);
        assertEq(box.balanceOf(feeder), 100e18);
        assertEq(box.totalSupply(), 100e18);
        assertEq(box.totalAssets(), 100e18);
        assertEq(currency.balanceOf(address(box)), 100e18);
    }

    function testDepositNonFeeder() public {
        vm.startPrank(nonAuthorized);
        currency.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.OnlyFeeders.selector);
        box.deposit(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testDepositWhenShutdown() public {
        vm.prank(guardian);
        box.triggerShutdown();

        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.CannotDepositIfShutdown.selector);
        box.deposit(100e18, feeder);
        vm.stopPrank();
    }

    function testMint() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(feeder, feeder, 100e18, 100e18);
        
        uint256 assets = box.mint(100e18, feeder);
        vm.stopPrank();

        assertEq(assets, 100e18);
        assertEq(box.balanceOf(feeder), 100e18);
        assertEq(box.totalSupply(), 100e18);
        assertEq(box.totalAssets(), 100e18);
    }

    function testMintNonFeeder() public {
        vm.startPrank(nonAuthorized);
        currency.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.OnlyFeeders.selector);
        box.mint(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testMintWhenShutdown() public {
        vm.prank(guardian);
        box.triggerShutdown();

        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.CannotMintIfShutdown.selector);
        box.mint(100e18, feeder);
        vm.stopPrank();
    }

    function testWithdraw() public {
        // First deposit
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        // Then withdraw
        vm.expectEmit(true, true, true, true);
        emit Withdraw(feeder, feeder, feeder, 50e18, 50e18);
        
        uint256 shares = box.withdraw(50e18, feeder, feeder);
        vm.stopPrank();

        assertEq(shares, 50e18);
        assertEq(box.balanceOf(feeder), 50e18);
        assertEq(box.totalSupply(), 50e18);
        assertEq(box.totalAssets(), 50e18);
        assertEq(currency.balanceOf(feeder), 9950e18);
    }

    function testWithdrawInsufficientShares() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.InsufficientShares.selector);
        box.withdraw(200e18, feeder, feeder);
        vm.stopPrank();
    }

    function testWithdrawWithAllowance() public {
        // Setup: feeder deposits, user1 gets allowance
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 50e18);
        vm.stopPrank();

        // Add user1 as feeder so they can withdraw
        vm.startPrank(curator);
        bytes memory userData = abi.encodeWithSelector(box.setIsFeeder.selector, user1, true);
        box.submit(userData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool userSuccess,) = address(box).call(userData);
        require(userSuccess, "Failed to set user1 as feeder");
        vm.stopPrank();

        // user1 withdraws on behalf of feeder
        vm.prank(user1);
        uint256 shares = box.withdraw(30e18, user1, feeder);

        assertEq(shares, 30e18);
        assertEq(box.balanceOf(feeder), 70e18);
        assertEq(box.allowance(feeder, user1), 20e18); // 50 - 30
        assertEq(currency.balanceOf(user1), 10030e18);
    }

    function testWithdrawInsufficientAllowance() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 30e18);
        vm.stopPrank();

        // Add user1 as feeder so they can withdraw
        vm.startPrank(curator);
        bytes memory userData = abi.encodeWithSelector(box.setIsFeeder.selector, user1, true);
        box.submit(userData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool userSuccess,) = address(box).call(userData);
        require(userSuccess, "Failed to set user1 as feeder");
        vm.stopPrank();

        vm.expectRevert(Errors.InsufficientAllowance.selector);
        vm.prank(user1);
        box.withdraw(50e18, user1, feeder);
    }

    function testRedeem() public {
        // First deposit
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        // Then redeem
        vm.expectEmit(true, true, true, true);
        emit Withdraw(feeder, feeder, feeder, 50e18, 50e18);
        
        uint256 assets = box.redeem(50e18, feeder, feeder);
        vm.stopPrank();

        assertEq(assets, 50e18);
        assertEq(box.balanceOf(feeder), 50e18);
        assertEq(box.totalSupply(), 50e18);
        assertEq(currency.balanceOf(feeder), 9950e18);
    }

    function testRedeemInsufficientShares() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.InsufficientShares.selector);
        box.redeem(200e18, feeder, feeder);
        vm.stopPrank();
    }

    /////////////////////////////
    /// ERC20 SHARE TESTS
    /////////////////////////////

    function testERC20Transfer() public {
        // Setup
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(feeder, user1, 50e18);
        
        bool success = box.transfer(user1, 50e18);
        vm.stopPrank();

        assertTrue(success);
        assertEq(box.balanceOf(feeder), 50e18);
        assertEq(box.balanceOf(user1), 50e18);
    }

    function testERC20TransferInsufficientBalance() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert();
        box.transfer(user1, 200e18);
        vm.stopPrank();
    }

    function testERC20Approve() public {
        vm.startPrank(feeder);
        
        vm.expectEmit(true, true, false, true);
        emit Approval(feeder, user1, 100e18);
        
        bool success = box.approve(user1, 100e18);
        vm.stopPrank();

        assertTrue(success);
        assertEq(box.allowance(feeder, user1), 100e18);
    }

    function testERC20TransferFrom() public {
        // Setup
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 50e18);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit Transfer(feeder, user2, 30e18);
        
        vm.prank(user1);
        bool success = box.transferFrom(feeder, user2, 30e18);

        assertTrue(success);
        assertEq(box.balanceOf(feeder), 70e18);
        assertEq(box.balanceOf(user2), 30e18);
        assertEq(box.allowance(feeder, user1), 20e18);
    }

    function testERC20TransferFromInsufficientAllowance() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 30e18);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        box.transferFrom(feeder, user2, 50e18);
    }

    function testERC20TransferFromInsufficientBalance() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 200e18);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        box.transferFrom(feeder, user2, 150e18);
    }

    function testERC20TransferFromMaxAllowance() public {
        // Setup with max allowance
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, type(uint256).max);
        vm.stopPrank();

        vm.prank(user1);
        box.transferFrom(feeder, user2, 50e18);

        assertEq(box.balanceOf(feeder), 50e18);
        assertEq(box.balanceOf(user2), 50e18);
        assertEq(box.allowance(feeder, user1), type(uint256).max); // Should not decrease
    }

    /////////////////////////////
    /// ALLOCATION TESTS
    /////////////////////////////

    function testAllocateToInvestmentToken() public {
        // Setup
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectEmit(true, false, true, false);
        emit Allocation(asset1, 50e18, swapper);

        // Allocate to asset1
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        assertEq(currency.balanceOf(address(box)), 50e18);
        assertEq(asset1.balanceOf(address(box)), 50e18);
        assertEq(box.totalAssets(), 100e18); // 50 USDC + 50 asset1 (1:1 price)
    }

    function testAllocateNonAllocator() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.OnlyAllocators.selector);
        vm.prank(nonAuthorized);
        box.allocate(asset1, 50e18, swapper);
    }

    function testAllocateWhenShutdown() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(guardian);
        box.triggerShutdown();

        vm.expectRevert(Errors.CannotAllocateIfShutdown.selector);
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);
    }

    function testAllocateNonWhitelistedToken() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.allocate(asset3, 50e18, swapper);
    }

    function testAllocateNoOracle() public {
        // This test needs to be updated since the error happens at execution time now
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.addInvestmentToken.selector, asset3, IOracle(address(0)));
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.OracleRequired.selector);
        (bool success,) = address(box).call(tokenData);
        vm.stopPrank();
    }

    function testAllocateSlippageProtection() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Set oracle price to make allocation expensive
        oracle1.setPrice(0.5e36); // 1 currency = 2 tokens expected
        // But swapper gives 1:1, so we get less than expected

        vm.expectRevert(Errors.AllocationTooExpensive.selector);
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);
    }

    function testAllocateWithSlippage() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Set swapper to have 0.5% slippage
        swapper.setSlippage(1); // 1% slippage
        
        // This should work as 1% is within the 1% max slippage
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        assertEq(currency.balanceOf(address(box)), 50e18);
        assertEq(asset1.balanceOf(address(box)), 49.5e18); // 1% slippage
    }

    function testDeallocateFromInvestmentToken() public {
        // Setup and allocate
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.expectEmit(true, false, true, false);
        emit Deallocation(asset1, 25e18, swapper);

        // Deallocate
        vm.prank(allocator);
        box.deallocate(asset1, 25e18, swapper);

        assertEq(currency.balanceOf(address(box)), 75e18);
        assertEq(asset1.balanceOf(address(box)), 25e18);
        assertEq(box.totalAssets(), 100e18); // 75 USDC + 25 asset1
    }

    function testDeallocateNonAllocator() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.expectRevert(Errors.OnlyAllocatorsOrShutdown.selector);
        vm.prank(nonAuthorized);
        box.deallocate(asset1, 25e18, swapper);
    }

    function testDeallocateNonWhitelistedToken() public {
        vm.expectRevert(Errors.NoOracleForToken.selector);
        vm.prank(allocator);
        box.deallocate(asset3, 25e18, swapper);
    }

    function testDeallocateSlippageProtection() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Set oracle price to make deallocation expensive
        oracle1.setPrice(2e36); // 1 token = 2 currency expected
        // But swapper gives 1:1, so we get less than expected

        vm.expectRevert(Errors.TokenSaleNotGeneratingEnoughCurrency.selector);
        vm.prank(allocator);
        box.deallocate(asset1, 25e18, swapper);
    }

    function testReallocate() public {
        // Setup and allocate to asset1
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Reallocate from asset1 to asset2
        vm.prank(allocator);
        box.reallocate(asset1, asset2, 25e18, swapper);

        assertEq(asset1.balanceOf(address(box)), 25e18);
        assertEq(asset2.balanceOf(address(box)), 25e18);
    }

    function testReallocateNonAllocator() public {
        vm.expectRevert(Errors.OnlyAllocators.selector);
        vm.prank(nonAuthorized);
        box.reallocate(asset1, asset2, 25e18, swapper);
    }

    function testReallocateWhenShutdown() public {
        vm.prank(guardian);
        box.triggerShutdown();

        vm.expectRevert(Errors.CannotReallocateIfShutdown.selector);
        vm.prank(allocator);
        box.reallocate(asset1, asset2, 25e18, swapper);
    }

    function testReallocateNonWhitelistedTokens() public {
        vm.expectRevert(Errors.TokensNotWhitelisted.selector);
        vm.prank(allocator);
        box.reallocate(asset3, asset1, 25e18, swapper);

        vm.expectRevert(Errors.TokensNotWhitelisted.selector);
        vm.prank(allocator);
        box.reallocate(asset1, asset3, 25e18, swapper);
    }

    function testReallocateSlippageProtection() public {
        // Setup and allocate to asset1
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Set oracle prices to make reallocation expensive
        oracle1.setPrice(1e36); // 1 asset1 = 1 currency
        oracle2.setPrice(0.5e36); // 1 asset2 = 0.5 currency (so we expect 2 asset2 for 1 asset1)
        
        // But swapper gives 1:1, so we get less than expected (50% slippage)
        vm.expectRevert(Errors.ReallocationSlippageTooHigh.selector);
        vm.prank(allocator);
        box.reallocate(asset1, asset2, 25e18, swapper);
    }

    function testReallocateWithAcceptableSlippage() public {
        // Setup and allocate to asset1
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Set oracle prices with small difference
        oracle1.setPrice(1e36); // 1 asset1 = 1 currency
        oracle2.setPrice(0.995e36); // 1 asset2 = 0.995 currency (expect ~1.005 asset2 for 1 asset1)
        
        // Swapper gives 1:1, which is within 1% slippage tolerance
        vm.prank(allocator);
        box.reallocate(asset1, asset2, 25e18, swapper);

        assertEq(asset1.balanceOf(address(box)), 25e18);
        assertEq(asset2.balanceOf(address(box)), 25e18);
    }

    /////////////////////////////
    /// MULTIPLE INVESTMENT TOKEN TESTS
    /////////////////////////////

    function testMultipleInvestmentTokens() public {
        // Setup
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // Allocate to both assets
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.prank(allocator);
        box.allocate(asset2, 50e18, swapper);

        assertEq(currency.balanceOf(address(box)), 100e18);
        assertEq(asset1.balanceOf(address(box)), 50e18);
        assertEq(asset2.balanceOf(address(box)), 50e18);
        assertEq(box.totalAssets(), 200e18); // 100 USDC + 50 asset1 + 50 asset2
        assertEq(box.getInvestmentTokensLength(), 2);
        assertEq(address(box.investmentTokens(0)), address(asset1));
        assertEq(address(box.investmentTokens(1)), address(asset2));
    }

    function testTotalAssetsWithDifferentPrices() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // First allocate with normal prices
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.prank(allocator);
        box.allocate(asset2, 50e18, swapper);

        // Then change oracle prices after allocation
        oracle1.setPrice(2e36); // 1 asset1 = 2 currency
        oracle2.setPrice(0.5e36); // 1 asset2 = 0.5 currency

        // Total assets = 100 currency + 50 asset1 * 2 + 50 asset2 * 0.5 = 100 + 100 + 25 = 225
        assertEq(box.totalAssets(), 225e18);
    }

    function testConvertToSharesWithInvestments() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 100e18, swapper);

        // Total assets = 100 currency + 100 asset1 = 200
        // Total supply = 200 shares
        // convertToShares(100) = 100 * 200 / 200 = 100
        assertEq(box.convertToShares(100e18), 100e18);

        // Change asset1 price to 2x
        oracle1.setPrice(2e36);
        // Total assets = 100 currency + 100 asset1 * 2 = 300
        // convertToShares(100) = 100 * 200 / 300 = 66.666...
        assertEq(box.convertToShares(100e18), 66666666666666666666);
    }

    /////////////////////////////
    /// SLIPPAGE ACCUMULATION TESTS
    /////////////////////////////

    function testSlippageAccumulation() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Set swapper to have 0.5% slippage
        swapper.setSlippage(1); // 1% slippage

        // Multiple allocations should accumulate slippage
        vm.startPrank(allocator);
        box.allocate(asset1, 100e18, swapper); // 0.1% of total assets slippage
        box.allocate(asset1, 100e18, swapper); // Another 0.1%
        box.allocate(asset1, 100e18, swapper); // Another 0.1%
        vm.stopPrank();

        // Should still work as we're under 1% total
        assertEq(asset1.balanceOf(address(box)), 297e18); // 300 - 3% slippage
    }

    function testSlippageAccumulationLimit() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Set swapper to have 1% slippage
        swapper.setSlippage(1); // 1% slippage

        vm.startPrank(allocator);
        // Multiple larger allocations that accumulate slippage faster
        // Each 100e18 allocation with 1% slippage should contribute more significantly
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage  
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        box.allocate(asset1, 100e18, swapper); // ~0.1% slippage
        
        // This should fail as it would exceed 1% total slippage
        vm.expectRevert(Errors.TooMuchAccumulatedSlippage.selector);
        box.allocate(asset1, 100e18, swapper); // Would push over 1% total
        vm.stopPrank();
    }

    function testSlippageEpochReset() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        swapper.setSlippage(1);

        vm.startPrank(allocator);
        // Use up most of slippage budget
        box.allocate(asset1, 90e18, swapper); // 0.09% slippage
        
        // Warp forward 8 days to reset epoch
        vm.warp(block.timestamp + 8 days);
        
        // Should work again as epoch reset
        box.allocate(asset1, 90e18, swapper);
        vm.stopPrank();
    }

    /////////////////////////////
    /// SHUTDOWN TESTS
    /////////////////////////////

    function testShutdown() public {
        vm.expectEmit(true, false, false, false);
        emit Shutdown(guardian);
        
        vm.prank(guardian);
        box.triggerShutdown();

        assertTrue(box.shutdown());
        assertEq(box.shutdownTime(), block.timestamp);
        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
    }

    function testShutdownNonGuardian() public {
        vm.expectRevert(Errors.OnlyGuardianCanShutdown.selector);
        vm.prank(nonAuthorized);
        box.triggerShutdown();
    }

    function testShutdownAlreadyShutdown() public {
        vm.prank(guardian);
        box.triggerShutdown();

        vm.expectRevert(Errors.AlreadyShutdown.selector);
        vm.prank(guardian);
        box.triggerShutdown();
    }

    function testDeallocateAfterShutdown() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.prank(guardian);
        box.triggerShutdown();

        // Anyone should be able to deallocate after shutdown
        vm.startPrank(nonAuthorized);

        // But need to wait SHUTDOWN_WARMUP before deallocation
        vm.expectRevert(Errors.OnlyAllocatorsOrShutdown.selector);
        box.deallocate(asset1, 25e18, swapper);

        // After warmup it should work
        vm.warp(block.timestamp + SHUTDOWN_WARMUP + 1);
        box.deallocate(asset1, 25e18, swapper);


        assertEq(asset1.balanceOf(address(box)), 25e18);
    }

    function testShutdownSlippageTolerance() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.prank(guardian);
        box.triggerShutdown();

        // Test that shutdown mode allows deallocation
        vm.prank(allocator);
        box.deallocate(asset1, 25e18, swapper);

        assertEq(asset1.balanceOf(address(box)), 25e18);
    }

    function testWithdrawAfterShutdownWithAutoDeallocation() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // Allocate some funds but leave enough currency for withdrawal
        vm.prank(allocator);
        box.allocate(asset1, 100e18, swapper);

        vm.prank(guardian);
        box.triggerShutdown();

        // Try to withdraw - should work with available currency
        vm.prank(feeder);
        box.withdraw(50e18, feeder, feeder);

        // Verify withdrawal worked
        assertEq(currency.balanceOf(address(box)), 50e18);
        assertEq(asset1.balanceOf(address(box)), 100e18);
    }

    /////////////////////////////
    /// UNBOX TESTS
    /////////////////////////////

    function testUnboxWithMultipleTokens() public {
        // Setup and allocate to multiple tokens
        vm.startPrank(feeder);
        currency.approve(address(box), 150e18);
        box.deposit(150e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        vm.prank(allocator);
        box.allocate(asset2, 50e18, swapper);

        // Unbox
        vm.prank(feeder);
        box.unbox(150e18);

        assertEq(box.balanceOf(feeder), 0);
        assertEq(box.totalSupply(), 0);
        assertEq(currency.balanceOf(feeder), 9900e18); // 9850 + 50 from unbox
        assertEq(asset1.balanceOf(feeder), 50e18);
        assertEq(asset2.balanceOf(feeder), 50e18);
    }

    function testUnboxPartialShares() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 150e18);
        box.deposit(150e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 75e18, swapper);

        // Unbox half the shares
        vm.prank(feeder);
        box.unbox(75e18);

        assertEq(box.balanceOf(feeder), 75e18);
        assertEq(box.totalSupply(), 75e18);
        assertEq(currency.balanceOf(feeder), 9887.5e18); // 9850 + 37.5 from unbox
        assertEq(asset1.balanceOf(feeder), 37.5e18);
    }

    function testUnboxInsufficientShares() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.InsufficientShares.selector);
        box.unbox(200e18);
        vm.stopPrank();
    }

    function testUnboxZeroShares() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.CannotUnboxZeroShares.selector);
        box.unbox(0);
        vm.stopPrank();
    }

    /////////////////////////////
    /// TIMELOCK GOVERNANCE TESTS
    /////////////////////////////

    function testTimelockPattern() public {
        vm.startPrank(curator);
        
        // Test setting max slippage with new timelock pattern
        uint256 newSlippage = 0.02 ether; // 2%
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, newSlippage);
        box.submit(slippageData);
        
        // Try to execute too early - should fail
        vm.expectRevert(Errors.TimelockNotExpired.selector);
        (bool success,) = address(box).call(slippageData);
        
        // Warp to after timelock
        vm.warp(block.timestamp + 1 days + 1);
        
        // Execute the change
        (success,) = address(box).call(slippageData);
        require(success, "Failed to set slippage");
        assertEq(box.maxSlippage(), newSlippage);
        
        vm.stopPrank();
    }

    function testTimelockSubmitNonCurator() public {
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.02 ether);
        vm.expectRevert(Errors.OnlyCurator.selector);
        vm.prank(nonAuthorized);
        box.submit(slippageData);
    }

    function testTimelockRevoke() public {
        // Curator should be able to revoke a submitted action
        vm.startPrank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.02 ether);
        box.submit(slippageData);
        assertEq(box.executableAt(slippageData), block.timestamp + 1 days);

        box.revoke(slippageData);
        assertEq(box.executableAt(slippageData), 0);
        
        // Should fail to execute after revoke
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.DataNotTimelocked.selector);
        (bool success,) = address(box).call(slippageData);
        vm.stopPrank();


        // Curator should also be able to revoke a submitted action
        vm.startPrank(curator);
        uint256 currentTime = block.timestamp;
        bytes4 selector = box.setMaxSlippage.selector;
        uint256 timelockDuration = box.timelock(selector);
        uint256 timelockDurationExplicit = 1 days;
        assertEq(box.timelock(selector), 1 days);
        assertEq(timelockDuration, timelockDurationExplicit);
        
        console.log("=== WTF ARITHMETIC BUG ===");
        console.log("currentTime:", currentTime);
        console.log("timelockDuration (1 days):", timelockDuration);
        console.log("timelockDurationExplicit (1 days):", timelockDurationExplicit);
        console.log("currentTime + timelockDuration = ", currentTime + timelockDuration);
        console.log("currentTime + timelockDurationExplicit =", currentTime + timelockDurationExplicit);
        console.log("Expected result: 86402 + 86400 = 172802");
        console.log("=====================================");
        
        box.submit(slippageData);
        assertEq(box.executableAt(slippageData), currentTime + timelockDuration);
        vm.stopPrank();

        vm.startPrank(guardian);
        box.revoke(slippageData);
        assertEq(box.executableAt(slippageData), 0);
        vm.stopPrank();
        
        // Should fail to execute after revoke
        vm.startPrank(curator);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.DataNotTimelocked.selector);
        (success,) = address(box).call(slippageData);
        vm.stopPrank();
    }

    function testTimelockRevokeNonCurator() public {
        vm.prank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.02 ether);
        box.submit(slippageData);

        vm.expectRevert(Errors.OnlyCuratorOrGuardian.selector);
        vm.prank(nonAuthorized);
        box.revoke(slippageData);
    }

    function testCuratorSubmitAccept() public {
        address newCurator = address(0x99);
        
        vm.prank(owner); // setCurator requires owner
        box.setCurator(newCurator);

        assertEq(box.curator(), newCurator);
    }

    function testGuardianSubmitAccept() public {
        address newGuardian = address(0x99);        
        
        vm.startPrank(curator);
        bytes memory guardianData = abi.encodeWithSelector(box.setGuardian.selector, newGuardian);
        box.submit(guardianData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(guardianData);
        require(success, "Failed to set guardian");
        vm.stopPrank();

        assertEq(box.guardian(), newGuardian);
    }

    function testCuratorSubmitInvalidAddress() public {
        // Test that setCurator properly validates against address(0)
        vm.expectRevert(Box.InvalidAddress.selector);
        vm.prank(owner); // setCurator requires owner
        box.setCurator(address(0));
    }

    function testAllocatorSubmitAccept() public {
        address newAllocator = address(0x99);
        
        vm.startPrank(curator); 
        bytes memory allocatorData = abi.encodeWithSelector(box.setIsAllocator.selector, newAllocator, true);
        box.submit(allocatorData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(allocatorData);
        require(success, "Failed to set allocator");
        vm.stopPrank();

        assertTrue(box.isAllocator(newAllocator));
    }

    function testAllocatorRemove() public {
        vm.startPrank(curator);
        bytes memory allocatorData = abi.encodeWithSelector(box.setIsAllocator.selector, allocator, false);
        box.submit(allocatorData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(allocatorData);
        require(success, "Failed to remove allocator");
        vm.stopPrank();

        assertFalse(box.isAllocator(allocator));
    }

    function testFeederSubmitAccept() public {
        address newFeeder = address(0x99);
        
        vm.startPrank(curator);
        bytes memory feederData = abi.encodeWithSelector(box.setIsFeeder.selector, newFeeder, true);
        box.submit(feederData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(feederData);
        require(success, "Failed to set feeder");
        vm.stopPrank();

        assertTrue(box.isFeeder(newFeeder));
    }

    function testSlippageSubmitAccept() public {
        uint256 newSlippage = 0.02 ether; // 2%

        vm.startPrank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, newSlippage);
        box.submit(slippageData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(slippageData);
        require(success, "Failed to set slippage");
        vm.stopPrank();

        assertEq(box.maxSlippage(), newSlippage);
    }

    function testSlippageSubmitTooHigh() public {
        vm.startPrank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.15 ether);
        box.submit(slippageData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.SlippageTooHigh.selector);
        (bool success,) = address(box).call(slippageData);
        vm.stopPrank();
    }

    function testInvestmentTokenSubmitAccept() public {
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.addInvestmentToken.selector, asset3, oracle3);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(tokenData);
        require(success, "Failed to add investment token");
        vm.stopPrank();

        assertTrue(box.isInvestmentToken(asset3));
        assertEq(address(box.oracles(asset3)), address(oracle3));
        assertEq(box.getInvestmentTokensLength(), 3);
    }

    function testInvestmentTokenRemove() public {
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.removeInvestmentToken.selector, asset1);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(tokenData);
        require(success, "Failed to remove investment token");
        vm.stopPrank();

        assertFalse(box.isInvestmentToken(asset1));
        assertEq(address(box.oracles(asset1)), address(0));
        assertEq(box.getInvestmentTokensLength(), 1);
    }

    function testInvestmentTokenRemoveWithBalance() public {
        // Allocate to asset1 first
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Try to remove token with balance - should fail at execution stage
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.removeInvestmentToken.selector, asset1);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.TokenBalanceMustBeZero.selector);
        (bool success,) = address(box).call(tokenData);
        vm.stopPrank();
    }

    function testOwnerChange() public {
        address newOwner = address(0x99);
        
        vm.prank(owner);
        box.transferOwnership(newOwner);

        assertEq(box.owner(), newOwner);
    }

    function testOwnerChangeNonOwner() public {
        vm.expectRevert(Errors.OnlyOwner.selector);
        vm.prank(nonAuthorized);
        box.transferOwnership(address(0x99));
    }

    function testOwnerChangeInvalidAddress() public {
        vm.expectRevert(Box.InvalidAddress.selector);
        vm.prank(owner);
        box.transferOwnership(address(0));
    }

    /////////////////////////////
    /// EDGE CASE TESTS
    /////////////////////////////

    function testDepositWithPriceChanges() public {
        // Initial deposit
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Allocate
        vm.prank(allocator);
        box.allocate(asset1, 50e18, swapper);

        // Change asset price to 2x
        oracle1.setPrice(2e36);

        // Second deposit should get fewer shares due to increased total assets
        vm.startPrank(feeder);
        uint256 shares = box.deposit(100e18, feeder);
        vm.stopPrank();

        // Total assets before second deposit = 50 currency + 50 asset1 * 2 = 150
        // Shares for 100 currency = 100 * 100 / 150 = 66.666...
        assertEq(shares, 66666666666666666666);
    }

    function testWithdrawWithInsufficientLiquidity() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Allocate all currency
        vm.prank(allocator);
        box.allocate(asset1, 100e18, swapper);

        // Try to withdraw - should fail due to insufficient liquidity
        vm.expectRevert(Errors.InsufficientLiquidity.selector);
        vm.prank(feeder);
        box.withdraw(50e18, feeder, feeder);
    }

    function testConvertFunctionsEdgeCases() public {
        // Test with zero total supply
        assertEq(box.convertToShares(100e18), 100e18);
        assertEq(box.convertToAssets(100e18), 100e18);

        // Test with zero amounts
        assertEq(box.convertToShares(0), 0);
        assertEq(box.convertToAssets(0), 0);
    }

    function testPreviewFunctionsConsistency() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 200e18);
        
        // Test preview deposit
        uint256 previewShares = box.previewDeposit(100e18);
        uint256 actualShares = box.deposit(100e18, feeder);
        assertEq(previewShares, actualShares);

        // Test preview mint
        uint256 previewAssets = box.previewMint(50e18);
        uint256 actualAssets = box.mint(50e18, feeder);
        assertEq(previewAssets, actualAssets);

        // Test preview withdraw
        uint256 previewWithdrawShares = box.previewWithdraw(50e18);
        uint256 actualWithdrawShares = box.withdraw(50e18, feeder, feeder);
        assertEq(previewWithdrawShares, actualWithdrawShares);

        // Test preview redeem
        uint256 previewRedeemAssets = box.previewRedeem(50e18);
        uint256 actualRedeemAssets = box.redeem(50e18, feeder, feeder);
        assertEq(previewRedeemAssets, actualRedeemAssets);
        
        vm.stopPrank();
    }

    function testMaxFunctionsAfterShutdown() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(guardian);
        box.triggerShutdown();

        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem
    }

    function testRecoverFromShutdown() public {
        vm.startPrank(feeder);
        currency.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        assertEq(box.shutdown(), false);

        vm.prank(guardian);
        box.triggerShutdown();
        assertEq(box.shutdown(), true);

        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem

        vm.prank(guardian);
        box.recover();
        assertEq(box.shutdown(), false);
    
        assertEq(box.maxDeposit(feeder), type(uint256).max);
        assertEq(box.maxMint(feeder), type(uint256).max);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem

        // Test allocators functions
        vm.startPrank(allocator);
        box.allocate(asset1, 100e18, swapper);
        box.reallocate(asset1, asset2, 100e18, swapper);
        box.deallocate(asset2, 100e18, swapper);
        vm.stopPrank();
    }

    function testComplexScenario() public {
        // Complex scenario with multiple users, tokens, and operations
        
        // Setup multiple users
        currency.mint(user1, 1000e18);
        currency.mint(user2, 1000e18);
        
        vm.startPrank(curator);
        bytes memory user1Data = abi.encodeWithSelector(box.setIsFeeder.selector, user1, true);
        box.submit(user1Data);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(user1Data);
        require(success, "Failed to set user1 as feeder");
        
        bytes memory user2Data = abi.encodeWithSelector(box.setIsFeeder.selector, user2, true);
        box.submit(user2Data);
        vm.warp(block.timestamp + 1 days + 1);
        (success,) = address(box).call(user2Data);
        require(success, "Failed to set user2 as feeder");
        vm.stopPrank();

        // User1 deposits
        vm.startPrank(user1);
        currency.approve(address(box), 500e18);
        box.deposit(500e18, user1);
        vm.stopPrank();

        // Allocate to asset1
        vm.prank(allocator);
        box.allocate(asset1, 200e18, swapper);

        // Change asset1 price
        oracle1.setPrice(1.5e36);

        // User2 deposits (should get fewer shares due to price increase)
        vm.startPrank(user2);
        currency.approve(address(box), 300e18);
        uint256 user2Shares = box.deposit(300e18, user2);
        vm.stopPrank();

        // Total assets = 600 currency + 200 asset1 * 1.5 = 900
        // User2 shares = 300 * 500 / 600 = 250 (approximately)
        // But the actual calculation is more complex due to rounding
        assertGt(user2Shares, 150e18);
        assertLt(user2Shares, 300e18);

        // Allocate to asset2
        vm.prank(allocator);
        box.allocate(asset2, 150e18, swapper);

        // User1 transfers some shares to user2
        vm.prank(user1);
        box.transfer(user2, 100e18);

        // Reallocate between assets - set compatible oracle prices first
        oracle2.setPrice(1.5e36); // Match asset1 price to avoid slippage issues
        vm.prank(allocator);
        box.reallocate(asset1, asset2, 50e18, swapper);

        // User2 redeems some shares
        vm.prank(user2);
        box.redeem(50e18, user2, user2);

        // Verify final state is consistent
        assertEq(box.totalSupply(), box.balanceOf(user1) + box.balanceOf(user2));
        assertGt(box.totalAssets(), 0);
        assertGt(currency.balanceOf(address(box)) + asset1.balanceOf(address(box)) + asset2.balanceOf(address(box)), 0);
    }




    function testAllocateReentrancyAttack() public {
        // Setup
        vm.startPrank(feeder);
        currency.approve(address(box), 10e18);
        box.deposit(10e18, feeder);
        vm.stopPrank();

        maliciousSwapper.setBox(box);

        // Allocate to asset1
        vm.prank(allocator);
        box.allocate(asset1, 1e18, maliciousSwapper);

        assertEq(currency.balanceOf(address(box)), 9e18);
        assertEq(asset1.balanceOf(address(box)), 1e18);
        assertEq(box.totalAssets(), 10e18); // 10 USDC + 0 asset1 (1:1 price)
    }
} 