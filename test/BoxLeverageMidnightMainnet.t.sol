// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingMidnight} from "../src/FundingMidnight.sol";
import {FundingMidnightFactory} from "../src/factories/FundingMidnightFactory.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {CollateralParams, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {IdLib} from "../src/libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "../src/libraries/midnight/MidnightMathLib.sol";
import {TickLib} from "../src/libraries/midnight/TickLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {MidnightForkTest} from "./helpers/MidnightForkTest.sol";
import {IMidnightTest, IVmEvmVersion} from "./helpers/MidnightTestInterfaces.sol";

/**
 * @title Box + FundingMidnight against the real Morpho Midnight deployment on Ethereum
 * @dev Block 26,043,970 (2026-09-24 01:12:11 UTC). Market: WBTC/USDC maturing 2026-12-25 15:00 UTC, with collateral
 *      sorted as [0] WBTC, [1] USDC. The market has no positions at this block, so every offer is created by the test.
 *      Settlement and continuous fees are 0 (checked in setUp), so buyer assets equal seller assets in every take.
 * @dev The module and factory are the same bytecode as on Base: only the constructor's Midnight address changes.
 * @dev Midnight's bytecode uses the Osaka CLZ opcode: setUp switches the execution EVM right after forking.
 * @dev The Box oracle for WBTC is the Midnight market oracle, so Box nav and the module ltv share one price.
 */
contract BoxLeverageMidnightMainnetTest is MidnightForkTest {
    using BoxLib for Box;
    using Math for uint256;

    uint256 internal constant FORK_BLOCK = 26_043_970;
    uint256 internal constant FORK_TIMESTAMP = 1_790_212_331;

    uint256 internal constant DEC25_MATURITY = 1_798_210_800;
    bytes32 internal constant DEC25_ID = 0x3323abf2d2a3ec804f46552db920d900bb9c7ffd3f48143ab879a918fd6c0977;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant CURSOR = 0.3e18;
    uint256 internal constant LLTV_CAP = 0.9e18;
    uint256 internal constant MAX_APR = 0.08e18;
    uint256 internal constant COLLATERAL = 5e8; // 5 WBTC, about 421k USDC
    uint256 internal constant WBTC_INDEX = 0;

    IERC20 internal constant USDC = IERC20(ETHEREUM_USDC);
    IERC20 internal constant WBTC = IERC20(ETHEREUM_WBTC);

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);

    FundingMidnightFactory internal factory;
    Box internal box;
    FundingMidnight internal module;
    bytes internal fd;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        IVmEvmVersion(address(vm)).setEvmVersion("osaka");

        midnight = IMidnightTest(ETHEREUM_MIDNIGHT);
        setterRatifier = ETHEREUM_SETTER_RATIFIER;
        ecrecoverRatifier = ETHEREUM_ECRECOVER_RATIFIER;

        assertEq(midnight.settlementFee(DEC25_ID, DEC25_MATURITY - block.timestamp), 0, "no settlement fee on Dec-25");
        assertEq(midnight.continuousFee(DEC25_ID), 0, "no continuous fee on Dec-25");

        factory = new FundingMidnightFactory();
        box = new Box(address(USDC), owner, curator, "Box USDC", "BOXUSDC", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(WBTC, IOracle(ETHEREUM_WBTC_USDC_ORACLE));
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        vm.stopPrank();

        module = factory.createFundingMidnight(address(box), ETHEREUM_MIDNIGHT, LLTV_CAP);
        fd = module.encodeFacilityData(_dec25Market(), WBTC_INDEX, MAX_APR);
        vm.startPrank(curator);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, WBTC);
        box.addFundingDebtInstant(module, USDC);
        box.addFundingFacilityInstant(module, fd);
        vm.stopPrank();

        // Face exceeds proceeds: the Box needs extra USDC to close the position at face value
        deal(address(USDC), address(this), 50_000e6);
        USDC.approve(address(box), 50_000e6);
        box.deposit(50_000e6, address(this));
        deal(address(WBTC), address(box), COLLATERAL);

        _setUpLender(USDC, 10_000_000e6);
    }

    // ========== DEPLOYMENT ==========

    function testForkDeploymentOnEthereum() public view {
        assertEq(IVmEvmVersion(address(vm)).getEvmVersion(), "osaka", "execution EVM switched to Osaka");
        assertEq(block.chainid, ETHEREUM_CHAIN_ID, "Ethereum");
        assertEq(block.number, FORK_BLOCK, "pinned block");
        assertEq(block.timestamp, FORK_TIMESTAMP, "pinned timestamp");

        assertEq(IdLib.toId(_dec25Market()), DEC25_ID, "Dec-25 market id");
        assertEq(keccak256(abi.encode(midnight.toMarket(DEC25_ID))), keccak256(abi.encode(_dec25Market())), "Dec-25 literal");
        assertEq(midnight.tickSpacing(DEC25_ID), 4, "Dec-25 created");

        assertTrue(factory.isFundingMidnight(address(module)), "created by the factory");
        assertEq(module.owner(), address(box), "owned by the Box");
        assertEq(address(module.midnight()), ETHEREUM_MIDNIGHT, "Ethereum Midnight");
        assertEq(module.lltvCap(), LLTV_CAP, "lltvCap");
        assertTrue(box.isFunding(module), "module attached");
        assertTrue(module.isFacility(fd), "facility registered");
        assertEq(fd, abi.encode(_dec25Market(), WBTC_INDEX, MAX_APR), "canonical facilityData");
        assertEq(module.marketId(fd), DEC25_ID, "facility on the Dec-25 market");
        assertEq(module.facilityOfMarket(DEC25_ID), keccak256(fd), "market mapped to the facility");
        assertEq(module.maturity(fd), DEC25_MATURITY, "maturity from the market");
    }

    // ========== CORE FLOW ==========

    function testCoreFlowWbtcUsdc() public {
        uint256 moduleUsdcBefore = USDC.balanceOf(address(module));
        uint256 moduleWbtcBefore = WBTC.balanceOf(address(module));
        uint256 navStart = box.totalAssets();

        vm.prank(allocator);
        box.pledge(module, fd, WBTC, COLLATERAL);

        assertEq(WBTC.balanceOf(address(box)), 0, "all WBTC left the Box");
        assertEq(midnight.collateral(DEC25_ID, address(module), WBTC_INDEX), COLLATERAL, "WBTC pledged at index 0");
        assertEq(midnight.collateral(DEC25_ID, address(module), 1), 0, "nothing at index 1 (USDC)");
        assertEq(module.collateralBalance(fd, WBTC), COLLATERAL, "facility collateralBalance");
        assertEq(WBTC.balanceOf(address(module)), moduleWbtcBefore, "no WBTC kept by the module");
        assertEq(box.totalAssets(), navStart, "pledge keeps totalAssets");

        // Tick 4212 implies about 5.97% a year on this market, within the 8% bound
        uint256 tick = 4212;
        uint256 price = TickLib.tickToPrice(tick);
        uint256 ttm = DEC25_MATURITY - block.timestamp;
        assertGe(price, MidnightMathLib.minSellerPrice(MAX_APR, ttm), "tick 4212 within 8%");

        Offer memory bid = _bid(_dec25Market(), ecrecoverRatifier, tick, "ethereum", 500_000e6);
        bytes memory rd = _signForEcrecover(bid);

        uint256 amount = 100_000e6;
        uint256 expectedUnits = MidnightMathLib.unitsForSellerAssets(amount, price);
        uint256 expectedProceeds = (expectedUnits * price) / WAD;

        uint256 navBefore = box.totalAssets();
        uint256 usdcBefore = USDC.balanceOf(address(box));
        uint256 lenderBefore = USDC.balanceOf(lender);

        vm.startPrank(allocator);
        module.stageBorrow(fd, _fills(bid, rd), block.timestamp + 1 hours);
        box.borrow(module, fd, USDC, amount);
        vm.stopPrank();

        uint256 received = USDC.balanceOf(address(box)) - usdcBefore;
        uint256 face = midnight.debt(DEC25_ID, address(module));
        console2.log("proceeds", received);
        console2.log("face    ", face);
        console2.log("ltv     ", module.ltv(fd));

        assertGe(received, amount, "Box received at least the amount");
        assertEq(received, expectedProceeds, "proceeds of the units sold at tick 4212");
        assertEq(face, expectedUnits, "Midnight debt = units sold");
        assertGt(face, received, "face above proceeds");
        assertEq(module.debtBalance(fd, USDC), face, "facility debtBalance = face");
        assertEq(module.debtBalance(USDC), face, "token debtBalance = face");
        assertEq(midnight.consumed(lender, "ethereum"), received, "signed bid consumed in buyer assets");
        assertEq(lenderBefore - USDC.balanceOf(lender), received, "lender paid the proceeds");
        assertEq(USDC.balanceOf(address(module)), moduleUsdcBefore, "no USDC kept by the module");
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertEq(validUntil, 0, "staging consumed");

        uint256 collateralValue = (COLLATERAL * IOracle(ETHEREUM_WBTC_USDC_ORACLE).price()) / 1e36;
        assertEq(module.ltv(fd), face.mulDiv(WAD, collateralValue, Math.Rounding.Ceil), "ltv = face / collateral value");
        assertLe(module.ltv(fd), (LLTV * LLTV_CAP) / WAD, "ltv within LLTV x lltvCap");
        // Debt is valued at the proceeds (accretion starts there), rounded up by at most 1 wei as the discount rounds down
        uint256 valueAfterBorrow = module.debtValue(fd);
        assertApproxEqAbs(valueAfterBorrow, received, 1, "debt valued at the proceeds within 1 wei");
        assertGe(valueAfterBorrow, received, "debt value never below the proceeds");
        assertEq(module.nav(IOracleCallback(address(box))), collateralValue - valueAfterBorrow, "nav = collateral - debt value");
        assertApproxEqAbs(box.totalAssets(), navBefore, 1, "borrow keeps totalAssets within 1 wei");

        vm.warp(block.timestamp + 30 days);
        uint256 value = module.debtValue(fd);
        assertGt(value, received, "debt value accretes");
        assertLt(value, face, "debt value below face before maturity");

        uint256 repaid = 40_000e6;
        usdcBefore = USDC.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fd, USDC, repaid);
        assertEq(usdcBefore - USDC.balanceOf(address(box)), repaid, "Box paid exactly the partial amount");
        assertEq(midnight.debt(DEC25_ID, address(module)), face - repaid, "Midnight debt down by the partial amount");
        assertEq(module.debtBalance(fd, USDC), face - repaid, "debtBalance down by the partial amount");

        usdcBefore = USDC.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, fd, USDC, type(uint256).max);
        assertEq(usdcBefore - USDC.balanceOf(address(box)), face - repaid, "Box paid the remaining face");
        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "debt closed exactly");
        assertEq(module.debtBalance(fd, USDC), 0, "no debtBalance");
        assertEq(module.debtValue(fd), 0, "no debt value");
        assertEq(USDC.balanceOf(address(module)), moduleUsdcBefore, "no USDC kept by the module");

        vm.prank(allocator);
        box.depledge(module, fd, WBTC, type(uint256).max);
        assertEq(WBTC.balanceOf(address(box)), COLLATERAL, "all WBTC back in the Box");
        assertEq(midnight.collateral(DEC25_ID, address(module), WBTC_INDEX), 0, "no collateral on Midnight");
        assertEq(module.collateralBalance(fd, WBTC), 0, "no collateralBalance");
        assertEq(WBTC.balanceOf(address(module)), moduleWbtcBefore, "no WBTC kept by the module");
        assertEq(module.nav(IOracleCallback(address(box))), 0, "empty position has no nav");

        // The whole cost of the loan is the face paid above the proceeds
        assertEq(navStart - box.totalAssets(), face - received, "totalAssets fell by face - proceeds");

        vm.startPrank(curator);
        box.removeFundingFacility(module, fd);
        box.removeFundingDebt(module, USDC);
        box.removeFundingCollateral(module, WBTC);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(module.isFacility(fd), "facility removed");
        assertEq(module.facilitiesLength(), 0, "no facility left");
        assertEq(module.facilityOfMarket(DEC25_ID), bytes32(0), "market released");
        assertFalse(box.isFunding(module), "module detached");
    }

    function testBorrowRevertsWhenOnlyAboveBoundOffer() public {
        // Tick 4100 implies about 10.45% a year on this market, above the 8% bound
        Offer memory bid = _bid(_dec25Market(), ecrecoverRatifier, 4100, "expensive", 1_000_000e6);
        bytes memory rd = _signForEcrecover(bid);
        assertLt(TickLib.tickToPrice(4100), MidnightMathLib.minSellerPrice(MAX_APR, DEC25_MATURITY - block.timestamp));

        vm.startPrank(allocator);
        box.pledge(module, fd, WBTC, COLLATERAL);
        module.stageBorrow(fd, _fills(bid, rd), block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 usdcBefore = USDC.balanceOf(address(box));
        uint256 lenderBefore = USDC.balanceOf(lender);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        box.borrow(module, fd, USDC, 10_000e6);

        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "no Midnight debt");
        assertEq(midnight.consumed(lender, "expensive"), 0, "bid not consumed");
        assertEq(USDC.balanceOf(address(box)), usdcBefore, "Box USDC unchanged");
        assertEq(USDC.balanceOf(lender), lenderBefore, "lender USDC unchanged");
    }

    function testBorrowAboveGuardReverts() public {
        Offer memory bid = _bid(_dec25Market(), setterRatifier, 4212, "guard", 1_000_000e6);
        bytes memory rd = _ratifyWithSetter(bid);
        vm.startPrank(allocator);
        box.pledge(module, fd, WBTC, COLLATERAL);
        module.stageBorrow(fd, _fills(bid, rd), block.timestamp + 1 hours);
        vm.stopPrank();

        // A face at 80% of the collateral value exceeds LLTV x lltvCap (77.4%) while Midnight still sees it healthy
        uint256 collateralValue = (COLLATERAL * IOracle(ETHEREUM_WBTC_USDC_ORACLE).price()) / 1e36;
        uint256 amount = (collateralValue.mulDiv(0.8e18, WAD) * TickLib.tickToPrice(4212)) / WAD;
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, fd, USDC, amount);

        assertEq(midnight.debt(DEC25_ID, address(module)), 0, "no Midnight debt");
        assertEq(midnight.consumed(lender, "guard"), 0, "bid not consumed");
    }

    // ========== HELPERS ==========

    /// @dev Collateral sorted by address: [0] WBTC (LLTV 0.86), [1] USDC (LLTV 0.98)
    function _dec25Market() internal pure returns (Market memory market) {
        market.chainId = ETHEREUM_CHAIN_ID;
        market.midnight = ETHEREUM_MIDNIGHT;
        market.loanToken = ETHEREUM_USDC;
        market.collateralParams = new CollateralParams[](2);
        market.collateralParams[0] = CollateralParams(ETHEREUM_WBTC, LLTV, CURSOR, ETHEREUM_WBTC_USDC_ORACLE);
        market.collateralParams[1] = CollateralParams(ETHEREUM_USDC, 0.98e18, CURSOR, ETHEREUM_USDC_USDC_ORACLE);
        market.maturity = DEC25_MATURITY;
        market.rcfThreshold = 300_000e6;
    }
}
