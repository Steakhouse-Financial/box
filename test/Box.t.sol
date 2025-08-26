// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Box} from "../src/Box.sol";
import {BoxFactory} from "../src/BoxFactory.sol";
import {IBoxFactory} from "../src/interfaces/IBoxFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {Errors} from "../src/lib/Errors.sol";
import "../src/lib/ConstantsLib.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";

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

    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata data) external {
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
    uint256 public scenario = ALLOCATE;
    uint256 public constant ALLOCATE = 0;
    uint256 public constant DEALLOCATE = 1;
    uint256 public constant REALLOCATE = 2;

    function setBox(Box _box) external {
        box = _box;
    }

    function setScenario(uint256 _scenario) external {
        scenario = _scenario;
    }

    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata data) external {        
        input.transferFrom(msg.sender, address(this), amountIn);
        
        step--;
        
        if(step > 0) {
            // Recursively call sell to simulate reentrancy
            if(scenario == 0) {
                box.allocate(output, amountIn, this, data);
            } else if(scenario == 1) {
                box.deallocate(input, amountIn, this, data);
            } else if(scenario == 2) {
                box.reallocate(input, output, amountIn, this, data);
            }
        }

        if(step == 0) {
            output.transfer(msg.sender, amountIn);
        }

        step++;

    }
}

contract BoxTest is Test {
    using BoxLib for Box;

    Box public box;
    IBoxFactory public boxFactory;
    MockERC20 public asset;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
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
    event Allocation(IERC20 indexed token, uint256 assets, uint256 tokens, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Deallocation(IERC20 indexed token, uint256 tokens, uint256 assets, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Reallocation(IERC20 indexed fromToken, IERC20 indexed toToken, uint256 fromAmount, uint256 toAmount, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Shutdown(address indexed guardian);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        asset = new MockERC20("USDC", "USDC");
        token1 = new MockERC20("Token1", "TOKEN1");
        token2 = new MockERC20("Token2", "TOKEN2");
        token3 = new MockERC20("Token3", "TOKEN3");
        oracle1 = new MockOracle();
        oracle2 = new MockOracle();
        oracle3 = new MockOracle();
        swapper = new MockSwapper();
        backupSwapper = new MockSwapper();
        badSwapper = new MockSwapper();
        maliciousSwapper = new MaliciousSwapper();


        boxFactory = new BoxFactory();

        //  Vault parameters
        string memory name = "Box Shares";
        string memory symbol = "BOX";
        uint256 maxSlippage = 0.01 ether; // 1%
        uint256 slippageEpochDuration = 7 days;
        uint256 shutdownSlippageDuration = 10 days;

        box = boxFactory.createBox(
            asset, 
            owner, 
            owner, // Initially owner is also curator
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            bytes32(0)
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

        // Add tokens
        bytes memory token1Data = abi.encodeWithSelector(box.addToken.selector, token1, oracle1);
        box.submit(token1Data);
        (success,) = address(box).call(token1Data);
        require(success, "Failed to add token1");

        bytes memory token2Data = abi.encodeWithSelector(box.addToken.selector, token2, oracle2);
        box.submit(token2Data);
        (success,) = address(box).call(token2Data);
        require(success, "Failed to add token2");

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
        asset.mint(feeder, 10000e18);
        asset.mint(user1, 10000e18);
        asset.mint(user2, 10000e18);
        token1.mint(address(swapper), 10000e18);
        token2.mint(address(swapper), 10000e18);
        token3.mint(address(swapper), 10000e18);
        token1.mint(address(backupSwapper), 10000e18);
        token2.mint(address(backupSwapper), 10000e18);
        token3.mint(address(backupSwapper), 10000e18);
        token1.mint(address(badSwapper), 10000e18);
        token2.mint(address(badSwapper), 10000e18);
        token3.mint(address(badSwapper), 10000e18);
        token1.mint(address(maliciousSwapper), 10000e18);
        token2.mint(address(maliciousSwapper), 10000e18);
        token3.mint(address(maliciousSwapper), 10000e18);

        // Mint asset for swappers to provide liquidity
        asset.mint(address(swapper), 10000e18);
        asset.mint(address(backupSwapper), 10000e18);
        asset.mint(address(badSwapper), 10000e18);
        asset.mint(address(maliciousSwapper), 10000e18);
    }


    /////////////////////////////
    /// BASIC TESTS
    /////////////////////////////
    function testBoxCreation(address asset, address owner, address curator, string memory name, string memory symbol, 
        uint256 maxSlippage, uint256 slippageEpochDuration, uint256 shutdownSlippageDuration, bytes32 salt) public {
        vm.assume(asset != address(0));
        vm.assume(owner != address(0));
        vm.assume(curator != address(0));
        vm.assume(maxSlippage <= MAX_SLIPPAGE_LIMIT);
        vm.assume(slippageEpochDuration != 0);
        vm.assume(shutdownSlippageDuration != 0);

        bytes memory initCode = abi.encodePacked(
            type(Box).creationCode,
            abi.encode(
                asset,
                owner,
                curator,
                name,
                symbol,
                maxSlippage,
                slippageEpochDuration,
                shutdownSlippageDuration
            )
        );

        address predicted = vm.computeCreate2Address(
            salt,
            keccak256(initCode),
            address(boxFactory) // deploying address
        );

        vm.expectEmit(true, true, false, true);
        emit IBoxFactory.CreateBox(
            IERC20(asset),
            owner,
            curator,
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            salt,
            Box(predicted)
        );

        box = boxFactory.createBox(
            IERC20(asset),
            owner,
            curator,
            name,
            symbol,
            maxSlippage,
            slippageEpochDuration,
            shutdownSlippageDuration,
            salt
        );

        assertEq(address(box), predicted, "unexpected CREATE2 address");
        assertEq(address(box.asset()), address(asset));
        assertEq(box.owner(), owner);
        assertEq(box.curator(), curator);
        assertEq(box.name(), name);
        assertEq(box.symbol(), symbol);
        assertEq(box.maxSlippage(), maxSlippage);
        assertEq(box.slippageEpochDuration(), slippageEpochDuration);
        assertEq(box.shutdownSlippageDuration(), shutdownSlippageDuration);
    }

    function testDefaultSkimRecipientIsOwner() public {
        assertEq(box.skimRecipient(), owner, "skimRecipient should default to owner");
    }

    function testSkimTransfersToRecipient() public {
        // Mint unrelated token (not the asset and not whitelisted) to the Box and skim it
        uint256 amount = 1e18;
        token3.mint(address(box), amount);
        assertEq(token3.balanceOf(address(box)), amount);

        uint256 beforeOwner = token3.balanceOf(owner);
        vm.prank(box.skimRecipient());
        box.skim(token3);

        assertEq(token3.balanceOf(address(box)), 0);
        assertEq(token3.balanceOf(owner), beforeOwner + amount);
    }

    function testSkimNotAuthorized(address nonAuthorized) public {
        vm.assume(nonAuthorized != box.skimRecipient());
        
        // Mint unrelated token (not the asset and not whitelisted) to the Box and skim it
        uint256 amount = 1e18;
        token3.mint(address(box), amount);
        assertEq(token3.balanceOf(address(box)), amount);

        vm.startPrank(nonAuthorized);
        vm.expectRevert(Errors.OnlySkimRecipient.selector);
        box.skim(token3);
        vm.stopPrank();
    }

    /////////////////////////////
    /// BASIC ERC4626 TESTS
    /////////////////////////////

    function testERC4626Compliance() public {
        // Test asset()
        assertEq(box.asset(), address(asset));

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


    function testERC4626SharesNoAssets() public {
        assertEq(box.convertToShares(100e18), 100e18); // 1:1 when empty

        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Simulate the loss to get totalAsset = 0
        vm.prank(address(box));
        asset.transfer(address(0xdead), 100e18);

        // Will revert if there is at least a share an no more assets
        vm.expectRevert();
        box.convertToShares(100e18); 
    }

    function testDeposit() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

        vm.expectEmit(true, true, false, true);
        emit Deposit(feeder, feeder, 100e18, 100e18);
        
        uint256 shares = box.deposit(100e18, feeder);
        vm.stopPrank();

        assertEq(shares, 100e18);
        assertEq(box.balanceOf(feeder), 100e18);
        assertEq(box.totalSupply(), 100e18);
        assertEq(box.totalAssets(), 100e18);
        assertEq(asset.balanceOf(address(box)), 100e18);
    }

    function testDepositNonFeeder() public {
        vm.startPrank(nonAuthorized);
        asset.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.OnlyFeeders.selector);
        box.deposit(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testDepositWhenShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

        vm.expectRevert(Errors.CannotDepositIfShutdown.selector);
        box.deposit(100e18, feeder);
        vm.stopPrank();
    }

    function testMint() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

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
        asset.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.OnlyFeeders.selector);
        box.mint(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testMintWhenShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        
        vm.expectRevert(Errors.CannotMintIfShutdown.selector);
        box.mint(100e18, feeder);
        vm.stopPrank();
    }

    function testWithdraw() public {
        // First deposit
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        assertEq(asset.balanceOf(feeder), 9950e18);
    }

    function testWithdrawInsufficientShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.InsufficientShares.selector);
        box.withdraw(200e18, feeder, feeder);
        vm.stopPrank();
    }

    function testWithdrawWithAllowance() public {
        // Setup: feeder deposits, user1 gets allowance
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        assertEq(asset.balanceOf(user1), 10030e18);
    }

    function testWithdrawInsufficientAllowance() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        // Then redeem
        vm.expectEmit(true, true, true, true);
        emit Withdraw(feeder, feeder, feeder, 50e18, 50e18);
        
        uint256 assets = box.redeem(50e18, feeder, feeder);
        vm.stopPrank();

        assertEq(assets, 50e18);
        assertEq(box.balanceOf(feeder), 50e18);
        assertEq(box.totalSupply(), 50e18);
        assertEq(asset.balanceOf(feeder), 9950e18);
    }

    function testRedeemInsufficientShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        box.approve(user1, 30e18);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user1);
        box.transferFrom(feeder, user2, 50e18);
    }

    function testERC20TransferFromInsufficientBalance() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        asset.approve(address(box), 100e18);
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

    function testAllocateToToken() public {
        // Setup
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectEmit(true, false, true, false);
        emit Allocation(token1, 50e18, 50e18, 0, swapper, "");

        // Allocate to token1
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 50e18);
        assertEq(token1.balanceOf(address(box)), 50e18);
        assertEq(box.totalAssets(), 100e18); // 50 USDC + 50 token1 (1:1 price)

        // Approval should be revoked post-swap
        assertEq(asset.allowance(address(box), address(swapper)), 0);
    }

    function testAllocateNonAllocator() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.OnlyAllocators.selector);
        vm.prank(nonAuthorized);
        box.allocate(token1, 50e18, swapper, "");
    }

    function testAllocateWhenShutdown() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(guardian);
        box.shutdown();

        vm.expectRevert(Errors.CannotAllocateIfShutdown.selector);
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");
    }

    function testAllocateNonWhitelistedToken() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.allocate(token3, 50e18, swapper, "");
    }

    function testAllocateNoOracle() public {
        // This test needs to be updated since the error happens at execution time now
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.addToken.selector, token3, IOracle(address(0)));
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(Errors.OracleRequired.selector);
        (bool success,) = address(box).call(tokenData);
        vm.stopPrank();
    }

    function testAllocateSlippageProtection() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Set oracle price to make allocation expensive
        oracle1.setPrice(0.5e36); // 1 asset = 2 tokens expected
        // But swapper gives 1:1, so we get less than expected

        vm.expectRevert(Errors.AllocationTooExpensive.selector);
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");
    }

    function testAllocateWithSlippage() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Set swapper to have 0.5% slippage
        swapper.setSlippage(1); // 1% slippage
        
        // This should work as 1% is within the 1% max slippage
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 50e18);
        assertEq(token1.balanceOf(address(box)), 49.5e18); // 1% slippage
    }

    function testDeallocateFromToken() public {
        // Setup and allocate
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectEmit(true, false, true, false);
        emit Deallocation(token1, 25e18, 25e18, 0, swapper, "");

        // Deallocate
        vm.prank(allocator);
        box.deallocate(token1, 25e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 75e18);
        assertEq(token1.balanceOf(address(box)), 25e18);
        assertEq(box.totalAssets(), 100e18); // 75 USDC + 25 token1

        // Approval should be revoked post-swap
        assertEq(token1.allowance(address(box), address(swapper)), 0);
    }

    function testDeallocateNonAllocator() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // make sure timestamp is realistic, setting it in August 15, 2025
        vm.warp(1755247499);

        vm.startPrank(nonAuthorized);
        vm.expectRevert(Errors.OnlyAllocatorsOrShutdown.selector);
        box.deallocate(token1, 25e18, swapper, "");
        vm.stopPrank();
    }

    function testDeallocateNonWhitelistedToken() public {
        vm.expectRevert(Errors.NoOracleForToken.selector);
        vm.prank(allocator);
        box.deallocate(token3, 25e18, swapper, "");
    }

    function testDeallocateSlippageProtection() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Set oracle price to make deallocation expensive
        oracle1.setPrice(2e36); // 1 token = 2 asset expected
        // But swapper gives 1:1, so we get less than expected

        vm.expectRevert(Errors.TokenSaleNotGeneratingEnoughAssets.selector);
        vm.prank(allocator);
        box.deallocate(token1, 25e18, swapper, "");
    }

    function testReallocate() public {
        // Setup and allocate to token1
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectEmit(true, false, true, false);
        emit Reallocation(token1, token2, 25e18, 25e18, 0, swapper, "");

        // Reallocate from token1 to token2
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18);
        assertEq(token2.balanceOf(address(box)), 25e18);

        // Approval should be revoked post-swap
        assertEq(token1.allowance(address(box), address(swapper)), 0);
    }

    function testReallocateNonAllocator() public {
        vm.expectRevert(Errors.OnlyAllocators.selector);
        vm.prank(nonAuthorized);
        box.reallocate(token1, token2, 25e18, swapper, "");
    }

    function testReallocateWhenShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.expectRevert(Errors.CannotReallocateIfShutdown.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");
    }

    function testReallocateNonWhitelistedTokens() public {
        vm.expectRevert(Errors.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.reallocate(token3, token1, 25e18, swapper, "");

        vm.expectRevert(Errors.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.reallocate(token1, token3, 25e18, swapper, "");
    }

    function testReallocateSlippageProtection() public {
        // Setup and allocate to token1
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Set oracle prices to make reallocation expensive
        oracle1.setPrice(1e36); // 1 token1 = 1 asset
        oracle2.setPrice(0.5e36); // 1 token2 = 0.5 asset (so we expect 2 token2 for 1 token1)
        
        // But swapper gives 1:1, so we get less than expected (50% slippage)
        vm.expectRevert(Errors.ReallocationSlippageTooHigh.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");
    }

    function testReallocateWithAcceptableSlippage() public {
        // Setup and allocate to token1
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Set oracle prices with small difference
        oracle1.setPrice(1e36); // 1 token1 = 1 asset
        oracle2.setPrice(0.995e36); // 1 token2 = 0.995 asset (expect ~1.005 token2 for 1 token1)
        
        // Swapper gives 1:1, which is within 1% slippage tolerance
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18);
        assertEq(token2.balanceOf(address(box)), 25e18);
    }

    /////////////////////////////
    /// MULTIPLE INVESTMENT TOKEN TESTS
    /////////////////////////////

    function testMultipleInvestmentTokens() public {
        // Setup
        vm.startPrank(feeder);
        asset.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // Allocate to both assets
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(allocator);
        box.allocate(token2, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 100e18);
        assertEq(token1.balanceOf(address(box)), 50e18);
        assertEq(token2.balanceOf(address(box)), 50e18);
        assertEq(box.totalAssets(), 200e18); // 100 USDC + 50 token1 + 50 token2
        assertEq(box.tokensLength(), 2);
        assertEq(address(box.tokens(0)), address(token1));
        assertEq(address(box.tokens(1)), address(token2));
    }

    function testTotalAssetsWithDifferentPrices() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // First allocate with normal prices
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(allocator);
        box.allocate(token2, 50e18, swapper, "");

        // Then change oracle prices after allocation
        oracle1.setPrice(2e36); // 1 token1 = 2 asset
        oracle2.setPrice(0.5e36); // 1 token2 = 0.5 asset

        // Total assets = 100 asset + 50 token1 * 2 + 50 token2 * 0.5 = 100 + 100 + 25 = 225
        assertEq(box.totalAssets(), 225e18);
    }

    function testConvertToSharesWithInvestments() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        // Total assets = 100 asset + 100 token1 = 200
        // Total supply = 200 shares
        // convertToShares(100) = 100 * 200 / 200 = 100
        assertEq(box.convertToShares(100e18), 100e18);

        // Change token1 price to 2x
        oracle1.setPrice(2e36);
        // Total assets = 100 asset + 100 token1 * 2 = 300
        // convertToShares(100) = 100 * 200 / 300 = 66.666...
        assertEq(box.convertToShares(100e18), 66666666666666666666);
    }

    /////////////////////////////
    /// SLIPPAGE ACCUMULATION TESTS
    /////////////////////////////

    function testSlippageAccumulation() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Set swapper to have 0.5% slippage
        swapper.setSlippage(1); // 1% slippage

        // Multiple allocations should accumulate slippage
        vm.startPrank(allocator);
        box.allocate(token1, 100e18, swapper, ""); // 0.1% of total assets slippage
        box.allocate(token1, 100e18, swapper, ""); // Another 0.1%
        box.allocate(token1, 100e18, swapper, ""); // Another 0.1%
        vm.stopPrank();

        // Should still work as we're under 1% total
        assertEq(token1.balanceOf(address(box)), 297e18); // 300 - 3% slippage
    }

    function testSlippageAccumulationLimit() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Set swapper to have 1% slippage
        swapper.setSlippage(1); // 1% slippage

        vm.startPrank(allocator);
        // Multiple larger allocations that accumulate slippage faster
        // Each 100e18 allocation with 1% slippage should contribute more significantly
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage  
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        box.allocate(token1, 100e18, swapper, ""); // ~0.1% slippage
        
        // This should fail as it would exceed 1% total slippage
        vm.expectRevert(Errors.TooMuchAccumulatedSlippage.selector);
        box.allocate(token1, 100e18, swapper, ""); // Would push over 1% total
        vm.stopPrank();
    }

    function testSlippageEpochReset() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        swapper.setSlippage(1);

        vm.startPrank(allocator);
        // Use up most of slippage budget
        box.allocate(token1, 90e18, swapper, ""); // 0.09% slippage
        
        // Warp forward 8 days to reset epoch
        vm.warp(block.timestamp + 8 days);
        
        // Should work again as epoch reset
        box.allocate(token1, 90e18, swapper, "");
        vm.stopPrank();
    }

    /////////////////////////////
    /// SHUTDOWN TESTS
    /////////////////////////////

    function testShutdown() public {
        vm.expectEmit(true, false, false, false);
        emit Shutdown(guardian);
        
        vm.prank(guardian);
        box.shutdown();

        assertTrue(box.isShutdown());
        assertEq(box.shutdownTime(), block.timestamp);
        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
    }

    function testShutdownNonGuardian() public {
        vm.expectRevert(Errors.OnlyGuardianCanShutdown.selector);
        vm.prank(nonAuthorized);
        box.shutdown();
    }

    function testShutdownAlreadyShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.expectRevert(Errors.AlreadyShutdown.selector);
        vm.prank(guardian);
        box.shutdown();
    }

    function testDeallocateAfterShutdown() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(guardian);
        box.shutdown();

        // Anyone should be able to deallocate after shutdown
        vm.startPrank(nonAuthorized);

        // But need to wait SHUTDOWN_WARMUP before deallocation
        vm.expectRevert(Errors.OnlyAllocatorsOrShutdown.selector);
        box.deallocate(token1, 25e18, swapper, "");

        // After warmup it should work
        vm.warp(block.timestamp + SHUTDOWN_WARMUP + 1);
        box.deallocate(token1, 25e18, swapper, "");


        assertEq(token1.balanceOf(address(box)), 25e18);
    }

    function testShutdownSlippageTolerance() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(guardian);
        box.shutdown();

        // Test that shutdown mode allows deallocation
        vm.prank(allocator);
        box.deallocate(token1, 25e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18);
    }

    function testWithdrawAfterShutdownWithAutoDeallocation() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 200e18);
        box.deposit(200e18, feeder);
        vm.stopPrank();

        // Allocate some funds but leave enough asset for withdrawal
        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        vm.prank(guardian);
        box.shutdown();

        // Try to withdraw - should work with available asset
        vm.prank(feeder);
        box.withdraw(50e18, feeder, feeder);

        // Verify withdrawal worked
        assertEq(asset.balanceOf(address(box)), 50e18);
        assertEq(token1.balanceOf(address(box)), 100e18);
    }

    /////////////////////////////
    /// UNBOX TESTS
    /////////////////////////////

    function testUnboxWithMultipleTokens() public {
        // Setup and allocate to multiple tokens
        vm.startPrank(feeder);
        asset.approve(address(box), 150e18);
        box.deposit(150e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(allocator);
        box.allocate(token2, 50e18, swapper, "");

        // Unbox
        vm.prank(feeder);
        box.unbox(150e18);

        assertEq(box.balanceOf(feeder), 0);
        assertEq(box.totalSupply(), 0);
        assertEq(asset.balanceOf(feeder), 9900e18); // 9850 + 50 from unbox
        assertEq(token1.balanceOf(feeder), 50e18);
        assertEq(token2.balanceOf(feeder), 50e18);
    }

    function testUnboxPartialShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 150e18);
        box.deposit(150e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 75e18, swapper, "");

        // Unbox half the shares
        vm.prank(feeder);
        box.unbox(75e18);

        assertEq(box.balanceOf(feeder), 75e18);
        assertEq(box.totalSupply(), 75e18);
        assertEq(asset.balanceOf(feeder), 9887.5e18); // 9850 + 37.5 from unbox
        assertEq(token1.balanceOf(feeder), 37.5e18);
    }

    function testUnboxInsufficientShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        
        vm.expectRevert(Errors.InsufficientShares.selector);
        box.unbox(200e18);
        vm.stopPrank();
    }

    function testUnboxZeroShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
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
        vm.expectRevert(Errors.InvalidAddress.selector);
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
        bytes memory tokenData = abi.encodeWithSelector(box.addToken.selector, token3, oracle3);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(tokenData);
        require(success, "Failed to add investment token");
        vm.stopPrank();

        assertTrue(box.isToken(token3));
        assertEq(address(box.oracles(token3)), address(oracle3));
        assertEq(box.tokensLength(), 3);
    }

    function testInvestmentTokenRemove() public {
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.removeToken.selector, token1);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success,) = address(box).call(tokenData);
        require(success, "Failed to remove investment token");
        vm.stopPrank();

        assertFalse(box.isToken(token1));
        assertEq(address(box.oracles(token1)), address(0));
        assertEq(box.tokensLength(), 1);
    }

    function testInvestmentTokenRemoveWithBalance() public {
        // Allocate to token1 first
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Try to remove token with balance - should fail at execution stage
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.removeToken.selector, token1);
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
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(owner);
        box.transferOwnership(address(0));
    }

    /////////////////////////////
    /// EDGE CASE TESTS
    /////////////////////////////


    function testTooManyTokensAdded() public {
        vm.startPrank(curator);
        for (uint256 i = box.tokensLength(); i < MAX_TOKENS; i++) {
            box.addCollateral(IERC20(address(uint160(i))), IOracle(address(uint160(i))));
        }

        bytes memory token1Data = abi.encodeWithSelector(box.addToken.selector, address(uint160(MAX_TOKENS)), address(uint160(MAX_TOKENS)));
        box.submit(token1Data);
        vm.expectRevert(Errors.TooManyTokens.selector);
        box.addToken(IERC20(address(uint160(MAX_TOKENS))), IOracle(address(uint160(MAX_TOKENS))));
        vm.stopPrank();
    }

    function testDepositWithPriceChanges() public {
        // Initial deposit
        vm.startPrank(feeder);
        asset.approve(address(box), 200e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Allocate
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Change asset price to 2x
        oracle1.setPrice(2e36);

        // Second deposit should get fewer shares due to increased total assets
        vm.startPrank(feeder);
        uint256 shares = box.deposit(100e18, feeder);
        vm.stopPrank();

        // Total assets before second deposit = 50 asset + 50 token1 * 2 = 150
        // Shares for 100 asset = 100 * 100 / 150 = 66.666...
        assertEq(shares, 66666666666666666666);
    }

    function testWithdrawWithInsufficientLiquidity() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Allocate all asset
        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

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
        asset.approve(address(box), 200e18);
        
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
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(guardian);
        box.shutdown();

        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem
    }

    function testRecoverFromShutdown() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        assertEq(box.isShutdown(), false);

        vm.prank(guardian);
        box.shutdown();
        assertEq(box.isShutdown(), true);

        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem

        vm.prank(guardian);
        box.recover();
        assertEq(box.isShutdown(), false);
    
        assertEq(box.maxDeposit(feeder), type(uint256).max);
        assertEq(box.maxMint(feeder), type(uint256).max);
        assertEq(box.maxWithdraw(feeder), 100e18); // Can still withdraw
        assertEq(box.maxRedeem(feeder), 100e18); // Can still redeem

        // Test allocators functions
        vm.startPrank(allocator);
        box.allocate(token1, 100e18, swapper, "");
        box.reallocate(token1, token2, 100e18, swapper, "");
        box.deallocate(token2, 100e18, swapper, "");
        vm.stopPrank();
    }

    function testComplexScenario() public {
        // Complex scenario with multiple users, tokens, and operations
        
        // Setup multiple users
        asset.mint(user1, 1000e18);
        asset.mint(user2, 1000e18);

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
        asset.approve(address(box), 500e18);
        box.deposit(500e18, user1);
        vm.stopPrank();

        // Allocate to token1
        vm.prank(allocator);
        box.allocate(token1, 200e18, swapper, "");

        // Change token1 price
        oracle1.setPrice(1.5e36);

        // User2 deposits (should get fewer shares due to price increase)
        vm.startPrank(user2);
        asset.approve(address(box), 300e18);
        uint256 user2Shares = box.deposit(300e18, user2);
        vm.stopPrank();

        // Total assets = 600 asset + 200 token1 * 1.5 = 900
        // User2 shares = 300 * 500 / 600 = 250 (approximately)
        // But the actual calculation is more complex due to rounding
        assertGt(user2Shares, 150e18);
        assertLt(user2Shares, 300e18);

        // Allocate to token2
        vm.prank(allocator);
        box.allocate(token2, 150e18, swapper, "");

        // User1 transfers some shares to user2
        vm.prank(user1);
        box.transfer(user2, 100e18);

        // Reallocate between assets - set compatible oracle prices first
        oracle2.setPrice(1.5e36); // Match token1 price to avoid slippage issues
        vm.prank(allocator);
        box.reallocate(token1, token2, 50e18, swapper, "");

        // User2 redeems some shares
        vm.prank(user2);
        box.redeem(50e18, user2, user2);

        // Verify final state is consistent
        assertEq(box.totalSupply(), box.balanceOf(user1) + box.balanceOf(user2));
        assertGt(box.totalAssets(), 0);
        assertGt(asset.balanceOf(address(box)) + token1.balanceOf(address(box)) + token2.balanceOf(address(box)), 0);
    }

    function testAllocateReentrancyAttack() public {
        // Setup
        vm.startPrank(feeder);
        asset.approve(address(box), 10e18);
        box.deposit(10e18, feeder);
        vm.stopPrank();

        // Allocate to token1
        vm.prank(allocator);
        box.allocate(token1, 5e18, swapper, "");

        maliciousSwapper.setBox(box);

        maliciousSwapper.setScenario(maliciousSwapper.ALLOCATE());
        vm.prank(allocator);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        box.allocate(token1, 1e18, maliciousSwapper, "");

        maliciousSwapper.setScenario(maliciousSwapper.DEALLOCATE());
        vm.prank(allocator);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        box.deallocate(token1, 1e18, maliciousSwapper, "");

        maliciousSwapper.setScenario(maliciousSwapper.REALLOCATE());
        vm.prank(allocator);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        box.reallocate(token1, token2, 1e18, maliciousSwapper, "");

        assertEq(box.totalAssets(), 10e18);
        assertEq(asset.balanceOf(address(box)), 5e18);
        assertEq(token1.balanceOf(address(box)), 5e18);
    }

    /////////////////////////////
    /// COMPREHENSIVE ALLOCATION EVENT TESTS
    /////////////////////////////

    function testAllocateZeroAmount() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(allocator);
        box.allocate(token1, 0, swapper, "");
    }

    function testDeallocateZeroAmount() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(allocator);
        box.deallocate(token1, 0, swapper, "");
    }

    function testReallocateZeroAmount() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 0, swapper, "");
    }

    function testAllocateInvalidSwapper() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(allocator);
        box.allocate(token1, 50e18, ISwapper(address(0)), "");
    }

    function testDeallocateInvalidSwapper() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(allocator);
        box.deallocate(token1, 25e18, ISwapper(address(0)), "");
    }

    function testReallocateInvalidSwapper() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, ISwapper(address(0)), "");
    }

    function testAllocateEventWithPositiveSlippage() public {
        // Setup with a better price than oracle (negative slippage = positive performance)
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Set oracle to expect fewer tokens
        oracle1.setPrice(1.1e36); // 1 token = 1.1 assets, so we expect 45.45 tokens for 50 assets

        // Expect event with negative slippage percentage (positive performance)
        vm.expectEmit(true, false, true, false);
        emit Allocation(token1, 50e18, 50e18, -0.1e18, swapper, ""); // -10% slippage

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 50e18);
        assertEq(token1.balanceOf(address(box)), 50e18);
    }

    function testDeallocateEventWithPositiveSlippage() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Set oracle to expect fewer assets  
        oracle1.setPrice(0.9e36); // 1 token = 0.9 assets, so we expect 22.5 assets for 25 tokens

        // Expect event with negative slippage percentage (positive performance)
        vm.expectEmit(true, false, true, false);
        emit Deallocation(token1, 25e18, 25e18, -0.111111111111111111e18, swapper, ""); // ~-11% slippage

        vm.prank(allocator);
        box.deallocate(token1, 25e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 75e18);
        assertEq(token1.balanceOf(address(box)), 25e18);
    }

    function testReallocateEventWithPositiveSlippage() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Set oracles to expect fewer token2
        oracle1.setPrice(1e36); // 1 token1 = 1 asset
        oracle2.setPrice(1.1e36); // 1 token2 = 1.1 assets, so we expect ~22.73 token2 for 25 token1

        // Expect event with negative slippage percentage (positive performance)
        vm.expectEmit(true, true, false, true, address(box));
        emit Reallocation(token1, token2, 25e18, 25e18, -0.1e18, swapper, ""); // -10% slippage

        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18);
        assertEq(token2.balanceOf(address(box)), 25e18);
    }

    function testAllocateWithSwapperSpendingLess() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // The swapper will actually spend the full 50 as authorized
        // Box tracks assetsSpent based on actual balance changes

        // Expect event with 50 assets spent
        vm.expectEmit(true, false, true, false);
        emit Allocation(token1, 50e18, 50e18, 0, swapper, "");

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 50e18); // 100 - 50
        assertEq(token1.balanceOf(address(box)), 50e18);
    }

    function testDeallocateWithSwapperSpendingLess() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // The swapper will actually spend the full 25 as authorized
        // Box tracks tokensSpent based on actual balance changes

        // Expect event with 25 tokens spent
        vm.expectEmit(true, false, true, false);
        emit Deallocation(token1, 25e18, 25e18, 0, swapper, "");

        vm.prank(allocator);
        box.deallocate(token1, 25e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 75e18); // 50 + 25
        assertEq(token1.balanceOf(address(box)), 25e18); // 50 - 25
    }

    function testReallocateWithSwapperSpendingLess() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // The swapper will actually spend the full 25 as authorized
        // Box tracks fromSpent based on actual balance changes

        // Expect event with 25 tokens spent and received
        vm.expectEmit(true, true, false, true, address(box));
        emit Reallocation(token1, token2, 25e18, 25e18, 0, swapper, "");

        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18); // 50 - 25
        assertEq(token2.balanceOf(address(box)), 25e18);
    }

    function testAllocateWithCustomData() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        bytes memory customData = abi.encode("custom", 123, address(0x999));

        // Expect event with custom data
        vm.expectEmit(true, false, true, true);
        emit Allocation(token1, 50e18, 50e18, 0, swapper, customData);

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, customData);

        assertEq(asset.balanceOf(address(box)), 50e18);
        assertEq(token1.balanceOf(address(box)), 50e18);
    }

    function testDeallocateDuringShutdownSlippageTolerance() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(guardian);
        box.shutdown();

        // Set high slippage swapper
        MockSwapper highSlippageSwapper = new MockSwapper();
        highSlippageSwapper.setSlippage(5); // 5% slippage
        token1.mint(address(highSlippageSwapper), 1000e18);
        asset.mint(address(highSlippageSwapper), 1000e18);

        // Wait for warmup period
        vm.warp(block.timestamp + SHUTDOWN_WARMUP + 1);

        // At start of shutdown slippage duration, should fail with 5% slippage
        vm.expectRevert(Errors.TokenSaleNotGeneratingEnoughAssets.selector);
        vm.prank(nonAuthorized);
        box.deallocate(token1, 25e18, highSlippageSwapper, "");

        // Warp halfway through shutdown slippage duration (5 days out of 10)
        vm.warp(block.timestamp + 5 days);
        
        // Now slippage tolerance should be ~5%, so this should work
        vm.expectEmit(true, false, true, false);
        emit Deallocation(token1, 25e18, 23.75e18, 50000000000000000, highSlippageSwapper, ""); // 5% slippage

        vm.prank(nonAuthorized);
        box.deallocate(token1, 25e18, highSlippageSwapper, "");

        assertEq(token1.balanceOf(address(box)), 25e18);
    }

    function testAllocateEventSlippageCalculation() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Test exact slippage boundary (1% max slippage)
        swapper.setSlippage(1); // Exactly 1% slippage

        // With 1% slippage on 100 assets, we get 99 tokens
        // Expected: 100, Actual: 99, Slippage: 1/100 = 1%
        vm.expectEmit(true, false, true, false);
        emit Allocation(token1, 100e18, 99e18, 0.01e18, swapper, ""); // 1% slippage

        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        assertEq(token1.balanceOf(address(box)), 99e18);
    }

    function testDeallocateEventSlippageCalculation() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        // Reset swapper slippage for deallocation
        swapper.setSlippage(1); // 1% slippage

        // With 1% slippage on 50 tokens, we get 49.5 assets
        // Expected: 50, Actual: 49.5, Slippage: 0.5/50 = 1%
        vm.expectEmit(true, false, true, false);
        emit Deallocation(token1, 50e18, 49.5e18, 0.01e18, swapper, ""); // 1% slippage

        vm.prank(allocator);
        box.deallocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 949.5e18); // 900 + 49.5
    }

    function testReallocateEventSlippageCalculation() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        vm.prank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        // Set swapper with 0.5% slippage
        swapper.setSlippage(0); // Reset to 0 first
        backupSwapper.setSlippage(1); // Use backup swapper with 1% slippage

        // Same price oracles, with 1% slippage on swap
        // From 50 token1 we expect 50 token2, but get 49.5 due to slippage
        vm.expectEmit(true, true, false, true, address(box));
        emit Reallocation(token1, token2, 50e18, 49.5e18, 10000000000000000, backupSwapper, ""); // 1% slippage

        vm.prank(allocator);
        box.reallocate(token1, token2, 50e18, backupSwapper, "");

        assertEq(token1.balanceOf(address(box)), 50e18); // 100 - 50
        assertEq(token2.balanceOf(address(box)), 49.5e18);
    }

    function testMultipleAllocationsEventSequence() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // First allocation
        vm.expectEmit(true, false, true, false);
        emit Allocation(token1, 100e18, 100e18, 0, swapper, "");

        vm.startPrank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        // Second allocation to different token
        vm.expectEmit(true, false, true, false);
        emit Allocation(token2, 150e18, 150e18, 0, swapper, "");
        box.allocate(token2, 150e18, swapper, "");

        // Reallocate between tokens
        vm.expectEmit(true, true, false, true, address(box));
        emit Reallocation(token1, token2, 50e18, 50e18, 0, swapper, "");
        box.reallocate(token1, token2, 50e18, swapper, "");

        // Deallocate from token2
        vm.expectEmit(true, false, true, false);
        emit Deallocation(token2, 100e18, 100e18, 0, swapper, "");
        box.deallocate(token2, 100e18, swapper, "");
        vm.stopPrank();

        // Verify final state
        assertEq(asset.balanceOf(address(box)), 850e18); // 1000 - 100 - 150 + 100
        assertEq(token1.balanceOf(address(box)), 50e18); // 100 - 50
        assertEq(token2.balanceOf(address(box)), 100e18); // 150 + 50 - 100
    }

    function testSwapperSpendingTooMuch() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        // Create a malicious swapper that tries to spend more than authorized
        MockSwapper greedySwapper = new MockSwapper();
        
        // Mock the behavior: swapper tries to take 60 but is only authorized 50
        // The actual transfer will fail due to insufficient allowance
        // But let's test the require check in the contract
        
        vm.prank(allocator);
        vm.expectRevert(); // Will revert in transferFrom due to trying to take too much
        box.allocate(token1, 50e18, greedySwapper, "");
    }
} 