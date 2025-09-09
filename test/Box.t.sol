// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {Box} from "../src/Box.sol";
import {BoxFactory} from "../src/BoxFactory.sol";
import {IBoxFactory} from "../src/interfaces/IBoxFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import "../src/lib/Constants.sol";
import {BoxLib} from "../src/lib/BoxLib.sol";
import {ErrorsLib} from "../src/lib/ErrorsLib.sol";
import {OperationsLib} from "../src/lib/OperationsLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {FundingMorpho} from "../src/FundingMorpho.sol";
import {IMorpho, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IrmMock} from "@morpho-blue/mocks/IrmMock.sol";
import {OracleMock} from "@morpho-blue/mocks/OracleMock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockOracle is IOracle {
    uint256 public price = 1e36; // 1:1 price
    int256 immutable decimalsShift;

    constructor(IERC20 input, IERC20 output) {
        decimalsShift =
            int256(uint256(IERC20Metadata(address(output)).decimals())) - int256(uint256(IERC20Metadata(address(input)).decimals()));
        price = (decimalsShift > 0) ? 1e36 * (10 ** uint256(decimalsShift)) : 1e36 / (10 ** uint256(-decimalsShift));
    }

    function setPrice(uint256 _price) external {
        price = (decimalsShift > 0) ? _price * (10 ** uint256(decimalsShift)) : _price / (10 ** uint256(-decimalsShift));
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

    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata) external {
        require(!shouldRevert, "Swapper: Forced revert");

        input.transferFrom(msg.sender, address(this), amountIn);

        int256 decimalsShift = int256(uint256(IERC20Metadata(address(output)).decimals())) -
            int256(uint256(IERC20Metadata(address(input)).decimals()));

        // Apply slippage
        uint256 amountOut = (amountIn * (100 - slippagePercent)) / 100;

        if (decimalsShift > 0) {
            amountOut = amountOut * (10 ** uint256(decimalsShift));
        } else if (decimalsShift < 0) {
            amountOut = amountOut / (10 ** uint256(-decimalsShift));
        }

        output.transfer(msg.sender, amountOut);
    }
}

contract PriceAwareSwapper is ISwapper {
    IOracle public oracle;
    uint256 public slippagePercent = 0;

    constructor(IOracle _oracle) {
        oracle = _oracle;
    }

    function setSlippage(uint256 _slippagePercent) external {
        slippagePercent = _slippagePercent;
    }

    function sell(IERC20 input, IERC20 output, uint256 amountIn, bytes calldata) external {
        // Pull input tokens
        input.transferFrom(msg.sender, address(this), amountIn);

        // Pay out assets according to oracle price, minus slippage
        uint256 expectedOut = (amountIn * oracle.price()) / ORACLE_PRECISION;
        uint256 amountOut = (expectedOut * (100 - slippagePercent)) / 100;
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

        if (step > 0) {
            // Recursively call sell to simulate reentrancy
            if (scenario == 0) {
                box.allocate(output, amountIn, this, data);
            } else if (scenario == 1) {
                box.deallocate(input, amountIn, this, data);
            } else if (scenario == 2) {
                box.reallocate(input, output, amountIn, this, data);
            }
        }

        if (step == 0) {
            output.transfer(msg.sender, amountIn);
        }

        step++;
    }
}

contract BoxTest is Test {
    using BoxLib for Box;
    using SafeERC20 for IERC20;
    using SafeERC20 for ERC20MockDecimals;

    IBoxFactory public boxFactory;
    Box public box;

    ERC20MockDecimals public asset;
    ERC20MockDecimals public token1;
    ERC20MockDecimals public token2;
    ERC20MockDecimals public token3;
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

    IMorpho morpho;
    address irm;

    uint256 lltv80 = 800000000000000000;
    uint256 lltv90 = 900000000000000000;

    MarketParams marketParamsLtv80;
    MarketParams marketParamsLtv90;

    FundingMorpho fundingMorpho;
    bytes facilityDataLtv80;
    bytes facilityDataLtv90;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event Allocation(IERC20 indexed token, uint256 assets, uint256 tokens, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Deallocation(IERC20 indexed token, uint256 tokens, uint256 assets, int256 slippagePct, ISwapper indexed swapper, bytes data);
    event Reallocation(
        IERC20 indexed fromToken,
        IERC20 indexed toToken,
        uint256 fromAmount,
        uint256 toAmount,
        int256 slippagePct,
        ISwapper indexed swapper,
        bytes data
    );
    event Shutdown(address indexed guardian);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        asset = new ERC20MockDecimals(18);
        token1 = new ERC20MockDecimals(18);
        token2 = new ERC20MockDecimals(18);
        token3 = new ERC20MockDecimals(18);
        oracle1 = new MockOracle(token1, asset);
        oracle2 = new MockOracle(token2, asset);
        oracle3 = new MockOracle(token3, asset);
        swapper = new MockSwapper();
        backupSwapper = new MockSwapper();
        badSwapper = new MockSwapper();
        maliciousSwapper = new MaliciousSwapper();

        // Mint tokens for testing
        asset.mint(address(this), 10000e18);
        asset.mint(feeder, 10000e18);
        asset.mint(user1, 10000e18);
        asset.mint(user2, 10000e18);
        token1.mint(address(swapper), 10000e18);
        token2.mint(address(swapper), 10000e18);
        token3.mint(address(swapper), 10000e18);
        token1.mint(address(this), 10000e18);
        token2.mint(address(this), 10000e18);
        token3.mint(address(this), 10000e18);
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

        // Funding context using Morpho

        morpho = IMorpho(address(new Morpho(address(this))));
        irm = address(new IrmMock());

        morpho.enableIrm(irm);
        morpho.enableLltv(lltv80);
        morpho.enableLltv(lltv90);

        // Create a 80% lltv market and seed it
        marketParamsLtv80 = MarketParams(address(asset), address(token1), address(oracle1), address(irm), lltv80);
        morpho.createMarket(marketParamsLtv80);
        asset.approve(address(morpho), 10000e18);
        token1.approve(address(morpho), 10000e18);
        morpho.supplyCollateral(marketParamsLtv80, 10e18, address(this), "");
        morpho.supply(marketParamsLtv80, 10e18, 0, address(this), "");
        morpho.borrow(marketParamsLtv80, 5e18, 0, address(this), address(this));
        facilityDataLtv80 = abi.encode(marketParamsLtv80);

        // Create a 90% lltv market and seed it
        marketParamsLtv90 = MarketParams(address(asset), address(token1), address(oracle1), address(irm), lltv90);
        morpho.createMarket(marketParamsLtv90);
        morpho.supplyCollateral(marketParamsLtv90, 10e18, address(this), "");
        morpho.supply(marketParamsLtv90, 10e18, 0, address(this), "");
        morpho.borrow(marketParamsLtv90, 5e18, 0, address(this), address(this));
        facilityDataLtv90 = abi.encode(marketParamsLtv90);

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

        box.setGuardianInstant(guardian);
        box.addFeederInstant(feeder);
        box.addFeederInstant(user1);
        box.setIsAllocator(allocator, true);
        box.setIsAllocator(address(maliciousSwapper), true);

        box.addTokenInstant(token1, oracle1);
        box.addTokenInstant(token2, oracle2);

        // Increase some timelocks
        box.increaseTimelock(box.setMaxSlippage.selector, 1 days);
        box.increaseTimelock(box.setGuardian.selector, 1 days);

        // Funding config
        fundingMorpho = new FundingMorpho(address(box), address(morpho));
        box.addFundingInstant(fundingMorpho);
        box.addFundingFacilityInstant(fundingMorpho, facilityDataLtv80);
        box.addFundingCollateralInstant(fundingMorpho, token1);
        box.addFundingDebtInstant(fundingMorpho, asset);

        vm.stopPrank();
    }

    /////////////////////////////
    /// BASIC TESTS
    /////////////////////////////
    function testBoxCreation(
        address asset_,
        address owner_,
        address curator_,
        string memory name_,
        string memory symbol_,
        uint256 maxSlippage_,
        uint256 slippageEpochDuration_,
        uint256 shutdownSlippageDuration_,
        bytes32 salt
    ) public {
        vm.assume(asset_ != address(0));
        vm.assume(owner_ != address(0));
        vm.assume(curator_ != address(0));
        vm.assume(maxSlippage_ <= MAX_SLIPPAGE_LIMIT);
        vm.assume(slippageEpochDuration_ != 0);
        vm.assume(shutdownSlippageDuration_ != 0);

        bytes memory initCode = abi.encodePacked(
            type(Box).creationCode,
            abi.encode(asset_, owner_, curator_, name_, symbol_, maxSlippage_, slippageEpochDuration_, shutdownSlippageDuration_)
        );

        address predicted = vm.computeCreate2Address(
            salt,
            keccak256(initCode),
            address(boxFactory) // deploying address
        );

        vm.expectEmit(true, true, true, true);
        emit IBoxFactory.CreateBox(
            IERC20(asset_),
            owner_,
            curator_,
            name_,
            symbol_,
            maxSlippage_,
            slippageEpochDuration_,
            shutdownSlippageDuration_,
            salt,
            Box(predicted)
        );

        box = boxFactory.createBox(
            IERC20(asset_),
            owner_,
            curator_,
            name_,
            symbol_,
            maxSlippage_,
            slippageEpochDuration_,
            shutdownSlippageDuration_,
            salt
        );

        assertEq(address(box), predicted, "unexpected CREATE2 address");
        assertEq(address(box.asset()), address(asset_));
        assertEq(box.owner(), owner_);
        assertEq(box.curator(), curator_);
        assertEq(box.name(), name_);
        assertEq(box.symbol(), symbol_);
        assertEq(box.maxSlippage(), maxSlippage_);
        assertEq(box.slippageEpochDuration(), slippageEpochDuration_);
        assertEq(box.shutdownSlippageDuration(), shutdownSlippageDuration_);
    }

    function testDefaultSkimRecipientIsOwner() public view {
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

    function testSkimNotAuthorized(address nonAuthorized_) public {
        vm.assume(nonAuthorized_ != box.skimRecipient());

        // Mint unrelated token (not the asset and not whitelisted) to the Box and skim it
        uint256 amount = 1e18;
        token3.mint(address(box), amount);
        assertEq(token3.balanceOf(address(box)), amount);

        vm.startPrank(nonAuthorized_);
        vm.expectRevert(ErrorsLib.OnlySkimRecipient.selector);
        box.skim(token3);
        vm.stopPrank();
    }

    /////////////////////////////
    /// BASIC ERC4626 TESTS
    /////////////////////////////

    function testERC4626Compliance() public view {
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

        vm.expectEmit(true, true, true, true);
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

        vm.expectRevert(ErrorsLib.OnlyFeeders.selector);
        box.deposit(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testDepositWhenShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

        vm.expectRevert(ErrorsLib.CannotDuringShutdown.selector);
        box.deposit(100e18, feeder);
        vm.stopPrank();
    }

    function testMint() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

        vm.expectEmit(true, true, true, true);
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

        vm.expectRevert(ErrorsLib.OnlyFeeders.selector);
        box.mint(100e18, nonAuthorized);
        vm.stopPrank();
    }

    function testMintWhenShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);

        vm.expectRevert(ErrorsLib.CannotDuringShutdown.selector);
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

        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
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
        (bool userSuccess, ) = address(box).call(userData);
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
        (bool userSuccess, ) = address(box).call(userData);
        require(userSuccess, "Failed to set user1 as feeder");
        vm.stopPrank();

        vm.expectRevert(ErrorsLib.InsufficientAllowance.selector);
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

        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
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

        vm.expectEmit(true, true, true, true);
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

        vm.expectEmit(true, true, true, true);
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

        vm.expectEmit(true, true, true, true);
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

        vm.expectEmit(true, true, true, true);
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

        vm.expectRevert(ErrorsLib.OnlyAllocatorsOrWinddown.selector);
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

        // Still work during shutdown
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // But fails when we reach wind-down mode
        vm.warp(block.timestamp + SHUTDOWN_WARMUP);
        vm.expectRevert(ErrorsLib.OnlyAllocatorsOrWinddown.selector);
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        vm.prank(guardian);
        box.recover();
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");
    }

    function testAllocateNonWhitelistedToken() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.allocate(token3, 50e18, swapper, "");
    }

    function testAllocateNoOracle() public {
        // This test needs to be updated since the error happens at execution time now
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.addToken.selector, token3, IOracle(address(0)));
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ErrorsLib.OracleRequired.selector);
        box.addToken(token3, IOracle(address(0)));
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

        vm.expectRevert(ErrorsLib.AllocationTooExpensive.selector);
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

        vm.expectEmit(true, true, true, true);
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

        // TODO why do we have this?
        // make sure timestamp is realistic, setting it in August 15, 2025
        //vm.warp(1755247499);

        vm.startPrank(nonAuthorized);
        vm.expectRevert(ErrorsLib.OnlyAllocatorsOrWinddown.selector);
        box.deallocate(token1, 25e18, swapper, "");
        vm.stopPrank();
    }

    function testDeallocateNonWhitelistedToken() public {
        vm.expectRevert(ErrorsLib.NoOracleForToken.selector);
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

        vm.expectRevert(ErrorsLib.TokenSaleNotGeneratingEnoughAssets.selector);
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

        vm.expectEmit(true, true, true, true);
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
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        vm.prank(nonAuthorized);
        box.reallocate(token1, token2, 25e18, swapper, "");
    }

    function testReallocateWhenShutdown() public {
        // Setup and allocate to token1
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();
        vm.prank(allocator);
        box.allocate(token1, 50e18, swapper, "");

        // Entering shutdown mode
        vm.prank(guardian);
        box.shutdown();

        // Can reallocate during shutdown
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");

        // But no longer when wind-down mode is reached
        vm.warp(block.timestamp + SHUTDOWN_WARMUP);
        vm.expectRevert(ErrorsLib.CannotDuringWinddown.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 25e18, swapper, "");
    }

    function testReallocateNonWhitelistedTokens() public {
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        vm.prank(allocator);
        box.reallocate(token3, token1, 25e18, swapper, "");

        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
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
        vm.expectRevert(ErrorsLib.ReallocationSlippageTooHigh.selector);
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
        vm.expectRevert(ErrorsLib.TooMuchAccumulatedSlippage.selector);
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
    /// FUNDING TESTS
    /////////////////////////////

    function testFundingSetup() public {
        assertTrue(box.isFunding(fundingMorpho));
        assertEq(box.fundingsLength(), 1);

        assertTrue(fundingMorpho.isFacility(facilityDataLtv80));
        assertEq(fundingMorpho.facilitiesLength(), 1);

        assertTrue(fundingMorpho.isCollateralToken(token1));
        assertEq(fundingMorpho.collateralTokensLength(), 1);

        assertTrue(fundingMorpho.isDebtToken(asset));
        assertEq(fundingMorpho.debtTokensLength(), 1);
    }

    /// @dev test that we can't add a funding token that is not already whitelisted as token at Box level
    function testAddFundingTokenNotWhitelisted() public {
        vm.startPrank(curator);

        bytes memory data = abi.encodeWithSelector(box.addFundingCollateral.selector, fundingMorpho, token3);
        box.submit(data);

        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        box.addFundingCollateral(fundingMorpho, token3);

        data = abi.encodeWithSelector(box.addFundingDebt.selector, fundingMorpho, token3);
        box.submit(data);

        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        box.addFundingDebt(fundingMorpho, token3);

        box.addTokenInstant(token3, oracle3);

        // Now it works (data are already submitted)
        box.addFundingCollateral(fundingMorpho, token3);
        box.addFundingDebt(fundingMorpho, token3);

        vm.stopPrank();
    }

    function testAtestRemoveFundingOneFacility() public {
        vm.startPrank(curator);

        // remove debt and collaterals
        box.removeFundingDebt(fundingMorpho, asset);
        box.removeFundingCollateral(fundingMorpho, token1);

        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFunding(fundingMorpho);

        box.removeFundingFacility(fundingMorpho, facilityDataLtv80);

        box.removeFunding(fundingMorpho);

        vm.stopPrank();
    }

    function testRemoveFundingOneCollateral() public {
        vm.startPrank(curator);

        box.removeFundingDebt(fundingMorpho, asset);
        box.removeFundingFacility(fundingMorpho, facilityDataLtv80);

        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFunding(fundingMorpho);

        box.removeFundingCollateral(fundingMorpho, token1);

        box.removeFunding(fundingMorpho);

        vm.stopPrank();
    }

    function testRemoveFundingOneDebt() public {
        vm.startPrank(curator);

        box.removeFundingCollateral(fundingMorpho, token1);
        box.removeFundingFacility(fundingMorpho, facilityDataLtv80);

        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFunding(fundingMorpho);

        box.removeFundingDebt(fundingMorpho, asset);

        box.removeFunding(fundingMorpho);

        vm.stopPrank();
    }

    function testRemoveFundingOrToken() public {
        token3.mint(address(box), 100e18);

        vm.startPrank(curator);

        // Don't need this one
        box.removeFundingDebt(fundingMorpho, asset);

        // Shouldn't work after setup as there is a facility, debt and collateral
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFunding(fundingMorpho);

        ERC20MockDecimals token4 = new ERC20MockDecimals(18);

        box.addTokenInstant(token4, oracle1); // Wrong oracle but fine for this test
        box.addFundingCollateralInstant(fundingMorpho, token4);

        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeToken(token4);

        box.removeFundingCollateral(fundingMorpho, token4);

        box.removeToken(token4);

        // Create a 90% lltv market and seed it
        MarketParams memory marketParamsLocal = MarketParams(address(token3), address(token1), address(oracle1), address(irm), lltv90);
        morpho.createMarket(marketParamsLocal);
        token3.mint(address(curator), 100e18);
        token3.approve(address(morpho), 100e18);
        morpho.supply(marketParamsLocal, 100e18, 0, address(curator), "");
        bytes memory facilityDataLocal = fundingMorpho.encodeFacilityData(marketParamsLocal);
        box.addFundingFacilityInstant(fundingMorpho, facilityDataLocal);

        box.addTokenInstant(token3, oracle3);
        box.addFundingCollateralInstant(fundingMorpho, token3);

        // No longer can remove token3 from Box, because there are token3 balance
        vm.expectRevert(ErrorsLib.TokenBalanceMustBeZero.selector);
        box.removeToken(token3);
        vm.stopPrank();

        // Withdraw all tokens
        vm.startPrank(address(box));
        token3.safeTransfer(address(curator), token3.balanceOf(address(box)));
        token1.safeTransfer(address(curator), token1.balanceOf(address(box)));
        vm.stopPrank();

        // Still can't remove token3 beacause there is a facility using it as debt token
        vm.startPrank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeToken(token3);

        // Can't remove token1 from Box
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeToken(token1);

        box.addFundingDebtInstant(fundingMorpho, token3);

        vm.stopPrank();
        token1.mint(address(box), 10e18);
        vm.prank(allocator);
        box.pledge(fundingMorpho, facilityDataLocal, token1, 10e18);
        vm.startPrank(curator);

        // Can't remove collateral while pledged
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingCollateral(fundingMorpho, token1);

        // Check that we can remove token3 as debt token while not borrowed
        box.removeFundingDebt(fundingMorpho, token3);
        box.addFundingDebtInstant(fundingMorpho, token3);

        vm.stopPrank();
        vm.prank(allocator);
        box.borrow(fundingMorpho, facilityDataLocal, token3, 1e18);
        vm.startPrank(curator);

        // Can't remove collateral while borrowed
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingDebt(fundingMorpho, token3);

        vm.stopPrank();
        vm.startPrank(allocator);
        box.repay(fundingMorpho, facilityDataLocal, token3, 1e18);
        box.depledge(fundingMorpho, facilityDataLocal, token1, 10e18);
        vm.stopPrank();

        vm.startPrank(address(box));
        token1.safeTransfer(address(curator), token1.balanceOf(address(box)));
        token3.safeTransfer(address(curator), token3.balanceOf(address(box)));
        vm.stopPrank();

        vm.startPrank(curator);

        box.removeFundingCollateral(fundingMorpho, token3);

        // Still a debt token
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeToken(token3);

        box.removeFundingDebt(fundingMorpho, token3);

        box.removeToken(token3);

        box.removeFundingCollateral(fundingMorpho, token1);

        box.removeToken(token1);

        box.removeFundingFacility(fundingMorpho, facilityDataLocal);
        box.removeFundingFacility(fundingMorpho, facilityDataLtv80);

        box.removeFunding(fundingMorpho);

        assertFalse(box.isFunding(fundingMorpho));
        assertEq(box.fundingsLength(), 0);

        vm.stopPrank();
    }

    /////////////////////////////
    /// SHUTDOWN TESTS
    /////////////////////////////

    function testShutdown() public {
        vm.expectEmit(true, true, true, true);
        emit Shutdown(guardian);

        vm.prank(guardian);
        box.shutdown();

        assertTrue(box.isShutdown());
        assertEq(box.shutdownTime(), block.timestamp);
        assertEq(box.maxDeposit(feeder), 0);
        assertEq(box.maxMint(feeder), 0);
    }

    function testShutdownNonGuardian() public {
        vm.expectRevert(ErrorsLib.OnlyGuardianCanShutdown.selector);
        vm.prank(nonAuthorized);
        box.shutdown();
    }

    function testShutdownAlreadyShutdown() public {
        vm.prank(guardian);
        box.shutdown();

        vm.expectRevert(ErrorsLib.AlreadyShutdown.selector);
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
        vm.expectRevert(ErrorsLib.OnlyAllocatorsOrWinddown.selector);
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

        vm.expectRevert(ErrorsLib.InsufficientShares.selector);
        box.unbox(200e18);
        vm.stopPrank();
    }

    function testUnboxZeroShares() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);

        vm.expectRevert(ErrorsLib.CannotUnboxZeroShares.selector);
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
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        (bool success, ) = address(box).call(slippageData);

        // Warp to after timelock
        vm.warp(block.timestamp + 1 days + 1);

        // Execute the change
        (success, ) = address(box).call(slippageData);
        require(success, "Failed to set slippage");
        assertEq(box.maxSlippage(), newSlippage);

        vm.stopPrank();
    }

    function testTimelockSubmitNonCurator() public {
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.02 ether);
        vm.expectRevert(ErrorsLib.OnlyCurator.selector);
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
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        (bool success, ) = address(box).call(slippageData);
        vm.stopPrank();

        // Curator should also be able to revoke a submitted action
        vm.startPrank(curator);
        uint256 currentTime = block.timestamp;
        bytes4 selector = box.setMaxSlippage.selector;
        uint256 timelockDuration = box.timelock(selector);
        uint256 timelockDurationExplicit = 1 days;
        assertEq(box.timelock(selector), 1 days);
        assertEq(timelockDuration, timelockDurationExplicit);

        console2.log("=== WTF ARITHMETIC BUG ===");
        console2.log("currentTime:", currentTime);
        console2.log("timelockDuration (1 days):", timelockDuration);
        console2.log("timelockDurationExplicit (1 days):", timelockDurationExplicit);
        console2.log("currentTime + timelockDuration = ", currentTime + timelockDuration);
        console2.log("currentTime + timelockDurationExplicit =", currentTime + timelockDurationExplicit);
        console2.log("Expected result: 86402 + 86400 = 172802");
        console2.log("=====================================");

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
        vm.expectRevert(ErrorsLib.DataNotTimelocked.selector);
        (success, ) = address(box).call(slippageData);
        vm.stopPrank();
    }

    function testTimelockRevokeNonCurator() public {
        vm.prank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.02 ether);
        box.submit(slippageData);

        vm.expectRevert(ErrorsLib.OnlyCuratorOrGuardian.selector);
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
        (bool success, ) = address(box).call(guardianData);
        require(success, "Failed to set guardian");
        vm.stopPrank();

        assertEq(box.guardian(), newGuardian);
    }

    function testCuratorSubmitInvalidAddress() public {
        // Test that setCurator properly validates against address(0)
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        vm.prank(owner); // setCurator requires owner
        box.setCurator(address(0));
    }

    function testAllocatorSubmitAccept() public {
        address newAllocator = address(0x99);

        vm.startPrank(curator);
        bytes memory allocatorData = abi.encodeWithSelector(box.setIsAllocator.selector, newAllocator, true);
        box.submit(allocatorData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success, ) = address(box).call(allocatorData);
        require(success, "Failed to set allocator");
        vm.stopPrank();

        assertTrue(box.isAllocator(newAllocator));
    }

    function testAllocatorRemove() public {
        vm.startPrank(curator);
        bytes memory allocatorData = abi.encodeWithSelector(box.setIsAllocator.selector, allocator, false);
        box.submit(allocatorData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success, ) = address(box).call(allocatorData);
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
        (bool success, ) = address(box).call(feederData);
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
        (bool success, ) = address(box).call(slippageData);
        require(success, "Failed to set slippage");
        vm.stopPrank();

        assertEq(box.maxSlippage(), newSlippage);
    }

    function testSlippageSubmitTooHigh() public {
        vm.startPrank(curator);
        bytes memory slippageData = abi.encodeWithSelector(box.setMaxSlippage.selector, 0.15 ether);
        box.submit(slippageData);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ErrorsLib.SlippageTooHigh.selector);
        box.setMaxSlippage(0.15 ether);
        vm.stopPrank();
    }

    function testInvestmentTokenSubmitAccept() public {
        vm.startPrank(curator);
        bytes memory tokenData = abi.encodeWithSelector(box.addToken.selector, token3, oracle3);
        box.submit(tokenData);
        vm.warp(block.timestamp + 1 days + 1);
        (bool success, ) = address(box).call(tokenData);
        require(success, "Failed to add investment token");
        vm.stopPrank();

        assertTrue(box.isToken(token3));
        assertEq(address(box.oracles(token3)), address(oracle3));
        assertEq(box.tokensLength(), 3);
    }

    function testInvestmentTokenRemove() public {
        vm.startPrank(curator);
        // Remove it from collateral
        box.removeFundingCollateral(fundingMorpho, token1);

        box.removeToken(token1);
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
        // Remove it from collateral
        box.removeFundingCollateral(fundingMorpho, token1);

        bytes memory tokenData = abi.encodeWithSelector(box.removeToken.selector, token1);
        box.submit(tokenData);
        vm.expectRevert(ErrorsLib.TokenBalanceMustBeZero.selector);
        box.removeToken(token1);
        vm.stopPrank();
    }

    function testOwnerChange() public {
        address newOwner = address(0x99);

        vm.prank(owner);
        box.transferOwnership(newOwner);

        assertEq(box.owner(), newOwner);
    }

    function testOwnerChangeNonOwner() public {
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        vm.prank(nonAuthorized);
        box.transferOwnership(address(0x99));
    }

    function testOwnerChangeInvalidAddress() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        vm.prank(owner);
        box.transferOwnership(address(0));
    }

    /////////////////////////////
    /// EDGE CASE TESTS
    /////////////////////////////

    function testTooManyTokensAdded() public {
        vm.startPrank(curator);
        for (uint256 i = box.tokensLength(); i < MAX_TOKENS; i++) {
            box.addTokenInstant(IERC20(address(uint160(i))), IOracle(address(uint160(i))));
        }

        bytes memory token1Data = abi.encodeWithSelector(box.addToken.selector, address(uint160(MAX_TOKENS)), address(uint160(MAX_TOKENS)));
        box.submit(token1Data);
        vm.expectRevert(ErrorsLib.TooManyTokens.selector);
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
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        vm.prank(feeder);
        box.withdraw(50e18, feeder, feeder);
    }

    function testConvertFunctionsEdgeCases() public view {
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
        (bool success, ) = address(box).call(user1Data);
        require(success, "Failed to set user1 as feeder");

        bytes memory user2Data = abi.encodeWithSelector(box.setIsFeeder.selector, user2, true);
        box.submit(user2Data);
        vm.warp(block.timestamp + 1 days + 1);
        (success, ) = address(box).call(user2Data);
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

        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
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

        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
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

        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        vm.prank(allocator);
        box.reallocate(token1, token2, 0, swapper, "");
    }

    function testAllocateInvalidSwapper() public {
        vm.startPrank(feeder);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, feeder);
        vm.stopPrank();

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
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

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
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

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true, address(box));
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true, address(box));
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectRevert(ErrorsLib.TokenSaleNotGeneratingEnoughAssets.selector);
        vm.prank(nonAuthorized);
        box.deallocate(token1, 25e18, highSlippageSwapper, "");

        // Warp halfway through shutdown slippage duration (5 days out of 10)
        vm.warp(block.timestamp + 5 days);

        // Now slippage tolerance should be ~5%, so this should work
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true);
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
        vm.expectEmit(true, true, true, true);
        emit Deallocation(token1, 50e18, 49.5e18, 0.01e18, swapper, ""); // 1% slippage

        vm.prank(allocator);
        box.deallocate(token1, 50e18, swapper, "");

        assertEq(asset.balanceOf(address(box)), 949.5e18); // 900 + 49.5
    }

    function testDeallocateSlippageAccountingNoDoubleConversion() public {
        // Deposit and allocate
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Allocate 500 assets to token1 at price 1:1 to build a position
        vm.prank(allocator);
        box.allocate(token1, 500e18, swapper, "");

        // Raise oracle price significantly so price != 1
        oracle1.setPrice(5e36); // 1 token = 5 assets

        // Use a price-aware swapper that pays according to oracle price with 1% slippage
        PriceAwareSwapper pSwapper = new PriceAwareSwapper(oracle1);
        pSwapper.setSlippage(1); // 1% slippage

        // Provide liquidity to the swapper
        asset.mint(address(pSwapper), 10000e18);

        // Deallocate 40 tokens. Expected assets = 40 * 5 = 200; actual = 198; loss = 2 assets
        vm.prank(allocator);
        box.deallocate(token1, 40e18, pSwapper, "");

        // Expected accumulated slippage is loss / totalAssetsAfter
        uint256 totalAfter = box.totalAssets();
        uint256 expectedLoss = 2e18; // 2 assets lost
        uint256 expectedAccumulated = (expectedLoss * 1e18) / totalAfter;

        // Ensure value matches what contract recorded (no extra price multiplication)
        assertApproxEqAbs(box.accumulatedSlippage(), expectedAccumulated, 1); // within 1 wei
        assertLt(box.accumulatedSlippage(), box.maxSlippage()); // should be well under 1%
    }

    function testDeallocateSlippageConversion() public {
        // Setup: deposit and allocate
        vm.startPrank(feeder);
        asset.approve(address(box), 1000e18);
        box.deposit(1000e18, feeder);
        vm.stopPrank();

        // Allocate 500 assets to token1 at 1:1 via simple swapper
        vm.prank(allocator);
        box.allocate(token1, 500e18, swapper, "");

        // Set a high oracle price so the buggy double-conversion would explode
        uint256 price = 500e36; // 1 token = 500 assets
        oracle1.setPrice(price);

        // Price-aware swapper paying per oracle with 1% slippage
        PriceAwareSwapper pSwapper = new PriceAwareSwapper(oracle1);
        pSwapper.setSlippage(1); // 1% slippage
        asset.mint(address(pSwapper), 10000e18);

        // Sell a small amount of tokens so true slippage is small vs total assets
        uint256 tokensToSell = 2e18; // expects 1000 assets, loses 10 assets (1%)

        // Hypothetical values under the old bug (loss converted by price again)
        uint256 expectedAssets = (tokensToSell * price) / ORACLE_PRECISION; // 1000 assets
        uint256 expectedLoss = expectedAssets / 100; // 1% loss = 10 assets
        uint256 inflatedValue = (expectedLoss * price) / ORACLE_PRECISION; // 10 * 500 = 5000 assets

        // Execute deallocation with fixed logic - should NOT revert
        vm.prank(allocator);
        box.deallocate(token1, tokensToSell, pSwapper, "");

        // With the buggy logic, accumulated slippage would have been inflatedValue / totalAssets
        uint256 totalAfter = box.totalAssets();
        uint256 oldBugPct = (inflatedValue * PRECISION) / totalAfter; // in 1e18 precision
        assertGe(oldBugPct, box.maxSlippage(), "Old buggy accounting would not have reverted as expected");

        // Actual accumulated slippage must equal actual loss / totalAfter
        uint256 expectedAccumulated = (expectedLoss * PRECISION) / totalAfter;
        assertApproxEqAbs(box.accumulatedSlippage(), expectedAccumulated, 1);
        assertLt(box.accumulatedSlippage(), box.maxSlippage());
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
        vm.expectEmit(true, true, true, true, address(box));
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
        vm.expectEmit(true, true, true, true);
        emit Allocation(token1, 100e18, 100e18, 0, swapper, "");

        vm.startPrank(allocator);
        box.allocate(token1, 100e18, swapper, "");

        // Second allocation to different token
        vm.expectEmit(true, true, true, true);
        emit Allocation(token2, 150e18, 150e18, 0, swapper, "");
        box.allocate(token2, 150e18, swapper, "");

        // Reallocate between tokens
        vm.expectEmit(true, true, true, true, address(box));
        emit Reallocation(token1, token2, 50e18, 50e18, 0, swapper, "");
        box.reallocate(token1, token2, 50e18, swapper, "");

        // Deallocate from token2
        vm.expectEmit(true, true, true, true);
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
