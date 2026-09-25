// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {FundingAaveV4} from "../src/FundingAaveV4.sol";
import {FundingAaveV4Factory} from "../src/factories/FundingAaveV4Factory.sol";
import {IAaveV4Spoke} from "../src/interfaces/aave-v4/IAaveV4Spoke.sol";
import {IBox} from "../src/interfaces/IBox.sol";
import {IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ISwapper} from "../src/interfaces/ISwapper.sol";
import {MAX_SHUTDOWN_WARMUP} from "../src/libraries/Constants.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {FlashLoanAave, IPoolAddressesProviderAave} from "../src/periphery/FlashLoanAave.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

interface IAaveV4Oracle {
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

interface IAaveV4Hub {
    struct SpokeConfig {
        uint40 addCap;
        uint40 drawCap;
        uint24 riskPremiumThreshold;
        bool active;
        bool halted;
    }

    function getSpokeConfig(uint256 assetId, address spoke) external view returns (SpokeConfig memory);
}

interface ISpokeAdmin {
    function updateReserveConfig(uint256 reserveId, IAaveV4Spoke.ReserveConfig calldata params) external;

    function addDynamicReserveConfig(uint256 reserveId, IAaveV4Spoke.DynamicReserveConfig calldata config) external returns (uint32);

    function updateDynamicReserveConfig(uint256 reserveId, uint32 key, IAaveV4Spoke.DynamicReserveConfig calldata config) external;
}

/// @dev Spoke entry points a third party can call about another user's position (test only)
interface IAaveV4SpokeThirdParty {
    struct PositionManagerUpdate {
        address positionManager;
        bool approve;
    }

    struct SetUserPositionManagers {
        address onBehalfOf;
        PositionManagerUpdate[] updates;
        uint256 nonce;
        uint256 deadline;
    }

    function setUserPositionManagersWithSig(SetUserPositionManagers calldata params, bytes calldata signature) external;

    function isPositionManager(address user, address positionManager) external view returns (bool);

    function liquidationCall(
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address user,
        uint256 debtToCover,
        bool receiveShares
    ) external;
}

interface IHubAdmin {
    function updateSpokeConfig(uint256 assetId, address spoke, IAaveV4Hub.SpokeConfig calldata config) external;
}

/// @dev Box oracle (1e36 scale, Box-asset units per token unit) derived from a Spoke's own Aave oracle, so that the Box
///      nav and the Spoke's health factor use the same prices.
contract SpokeRatioOracle is IOracle {
    IAaveV4Oracle public immutable spokeOracle;
    uint256 public immutable tokenReserveId;
    uint256 public immutable assetReserveId;
    uint256 public immutable scale;

    constructor(IAaveV4Oracle _spokeOracle, uint256 _tokenReserveId, uint8 tokenDecimals, uint256 _assetReserveId, uint8 assetDecimals) {
        spokeOracle = _spokeOracle;
        tokenReserveId = _tokenReserveId;
        assetReserveId = _assetReserveId;
        scale = 10 ** (36 + uint256(assetDecimals) - uint256(tokenDecimals));
    }

    function price() external view returns (uint256) {
        return (spokeOracle.getReservePrice(tokenReserveId) * scale) / spokeOracle.getReservePrice(assetReserveId);
    }
}

/**
 * @title Box + FundingAaveV4 against the real Aave v4 deployment on Avalanche
 * @dev AVAX Correlated Spoke (sAVAX collateral, WAVAX debt) for the loop, the governance scenarios and the flash
 *      leverage; Main Spoke (USDt collateral, USDC debt) for the stablecoin carry.
 */
contract BoxLeverageAaveV4AvalancheTest is Test {
    using BoxLib for Box;

    uint256 internal constant FORK_BLOCK = 96_000_000;

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);
    address internal user = address(0x5);
    address internal anyone = address(0x6);

    // Aave v4 on Avalanche
    IAaveV4Spoke internal constant AVAX_SPOKE = IAaveV4Spoke(0x3b517594277c67307CF2d7CBE6FE1D4399B68c41);
    IAaveV4Spoke internal constant MAIN_SPOKE = IAaveV4Spoke(0x435272CefF93a1E657E8ABfdf0A13e95900A3a56);
    address internal constant SPOKE_CONFIGURATOR = 0x8F72573F1Aa0A1e39fFD2a2A69e9EDAa8B982642;
    address internal constant HUB_CONFIGURATOR = 0xbdf92ed96FF6D678469aFAFFa1e7d37B25beaa33;

    // Aave v3 on Avalanche (flash loans)
    address internal constant AAVE_V3_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address internal constant AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    IERC20 internal constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 internal constant SAVAX = IERC20(0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE);
    IERC20 internal constant BTCB = IERC20(0x152b9d0FdC40C096757F570A51E494bd4b943E50);
    IERC20 internal constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 internal constant USDT = IERC20(0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7);
    IERC20 internal constant EURC = IERC20(0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD);

    // AVAX Correlated Spoke reserves
    uint256 internal constant SAVAX_ID = 0;
    uint256 internal constant WAVAX_ID = 1;
    // Main Spoke reserves
    uint256 internal constant MAIN_USDC_ID = 2;
    uint256 internal constant MAIN_USDT_ID = 3;

    uint256 internal constant LLTV_CAP = 0.95e18;

    bytes4 internal constant UNAUTHORIZED = bytes4(keccak256("Unauthorized()"));
    bytes4 internal constant HEALTH_FACTOR_BELOW_THRESHOLD = bytes4(keccak256("HealthFactorBelowThreshold()"));
    bytes4 internal constant RESERVE_PAUSED = bytes4(keccak256("ReservePaused()"));
    bytes4 internal constant RESERVE_FROZEN = bytes4(keccak256("ReserveFrozen()"));
    bytes4 internal constant SPOKE_HALTED = bytes4(keccak256("SpokeHalted()"));
    bytes4 internal constant DRAW_CAP_EXCEEDED = bytes4(keccak256("DrawCapExceeded(uint256)"));
    bytes4 internal constant INVALID_SIGNATURE = bytes4(keccak256("InvalidSignature()"));

    bytes internal constant EMPTY = "";

    FundingAaveV4Factory internal factory;
    IAaveV4Oracle internal avaxSpokeOracle;
    SpokeRatioOracle internal savaxOracle;
    MockOracle internal wavaxUnitOracle;

    Box internal box;
    FundingAaveV4 internal module;

    function setUp() public {
        vm.createSelectFork(vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc")), FORK_BLOCK);

        factory = new FundingAaveV4Factory();
        avaxSpokeOracle = IAaveV4Oracle(AVAX_SPOKE.ORACLE());
        savaxOracle = new SpokeRatioOracle(avaxSpokeOracle, SAVAX_ID, 18, WAVAX_ID, 18);
        wavaxUnitOracle = new MockOracle(1e36);

        box = new Box(address(WAVAX), owner, curator, "Box WAVAX", "BOXWAVAX", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);
        module = factory.createFundingAaveV4(address(box), address(AVAX_SPOKE), _ids2(SAVAX_ID, WAVAX_ID), LLTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(SAVAX, savaxOracle);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, EMPTY);
        box.addFundingCollateralInstant(module, SAVAX);
        box.addFundingDebtInstant(module, WAVAX);
        vm.stopPrank();

        deal(address(WAVAX), address(this), 1_000e18);
        WAVAX.approve(address(box), 1_000e18);
        box.deposit(1_000e18, address(this));
        deal(address(SAVAX), address(box), 1_000e18);
    }

    // ========== ACCESS ==========

    /// @dev Nobody but the module can move its Spoke position: it never approved a position manager
    function testThirdPartiesCannotActOnModulePosition() public {
        _open(1_000e18);
        uint256 suppliedBefore = AVAX_SPOKE.getUserSuppliedAssets(SAVAX_ID, address(module));
        uint256 debtBefore = AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module));

        deal(address(SAVAX), anyone, 10e18);
        deal(address(WAVAX), anyone, 10e18);
        vm.startPrank(anyone);
        SAVAX.approve(address(AVAX_SPOKE), type(uint256).max);
        WAVAX.approve(address(AVAX_SPOKE), type(uint256).max);

        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.supply(SAVAX_ID, 1e18, address(module));
        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.withdraw(SAVAX_ID, 1e18, address(module));
        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.borrow(WAVAX_ID, 1e18, address(module));
        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.repay(WAVAX_ID, 1e18, address(module));
        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.setUsingAsCollateral(SAVAX_ID, false, address(module));
        vm.stopPrank();

        assertEq(AVAX_SPOKE.getUserSuppliedAssets(SAVAX_ID, address(module)), suppliedBefore, "supplied assets unchanged");
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), debtBefore, "debt unchanged");
        (bool usingAsCollateral, bool borrowing) = AVAX_SPOKE.getUserReserveStatus(SAVAX_ID, address(module));
        assertTrue(usingAsCollateral, "still used as collateral");
        assertFalse(borrowing, "collateral reserve not borrowed");
        assertEq(SAVAX.balanceOf(anyone), 10e18, "third party kept its sAVAX");
        assertEq(WAVAX.balanceOf(anyone), 10e18, "third party kept its WAVAX");
    }

    /// @dev The module has code but no ERC-1271 `isValidSignature`, so no signed intent
    ///      can approve a position manager on its behalf
    function testSignedIntentCannotApprovePositionManagerForModule() public {
        _open(1_000e18);
        IAaveV4SpokeThirdParty spoke = IAaveV4SpokeThirdParty(address(AVAX_SPOKE));
        IAaveV4SpokeThirdParty.PositionManagerUpdate[] memory updates = new IAaveV4SpokeThirdParty.PositionManagerUpdate[](1);
        updates[0] = IAaveV4SpokeThirdParty.PositionManagerUpdate({positionManager: anyone, approve: true});
        IAaveV4SpokeThirdParty.SetUserPositionManagers memory params = IAaveV4SpokeThirdParty.SetUserPositionManagers({
            onBehalfOf: address(module),
            updates: updates,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes[3] memory signatures = [
            bytes(""),
            abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27)),
            abi.encode(bytes4(0x1626ba7e)) // the ERC-1271 magic value itself
        ];
        vm.startPrank(anyone);
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.expectRevert(INVALID_SIGNATURE);
            spoke.setUserPositionManagersWithSig(params, signatures[i]);
        }
        vm.stopPrank();

        assertFalse(spoke.isPositionManager(address(module), anyone), "no position manager approved");
        vm.prank(anyone);
        vm.expectRevert(UNAUTHORIZED);
        AVAX_SPOKE.borrow(WAVAX_ID, 1e18, address(module));
    }

    /// @dev Liquidation is the only third-party write on the module's position. Afterwards the views still track the
    ///      Spoke, nav computes, nothing lands in the module, and the Box can still close and remove the position.
    function testThirdPartyLiquidationLeavesPositionClosable() public {
        _open(1_000e18);
        uint256 navBefore = box.totalAssets();
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        uint256 collateralBefore = module.collateralBalance(EMPTY, SAVAX);

        // Governance edits the collateral factor of the key the position is bound to (95% -> 60%): HF about 0.77
        uint32 key = AVAX_SPOKE.getUserPosition(SAVAX_ID, address(module)).dynamicConfigKey;
        IAaveV4Spoke.DynamicReserveConfig memory config = AVAX_SPOKE.getDynamicReserveConfig(SAVAX_ID, key);
        config.collateralFactor = 6000;
        vm.prank(SPOKE_CONFIGURATOR);
        ISpokeAdmin(address(AVAX_SPOKE)).updateDynamicReserveConfig(SAVAX_ID, key, config);
        assertLt(AVAX_SPOKE.getUserAccountData(address(module)).healthFactor, 1e18, "liquidatable");

        deal(address(WAVAX), anyone, 100e18);
        vm.startPrank(anyone);
        WAVAX.approve(address(AVAX_SPOKE), 100e18);
        IAaveV4SpokeThirdParty(address(AVAX_SPOKE)).liquidationCall(SAVAX_ID, WAVAX_ID, address(module), 100e18, false);
        vm.stopPrank();

        uint256 repaid = 100e18 - WAVAX.balanceOf(anyone);
        uint256 seized = SAVAX.balanceOf(anyone);
        assertGt(repaid, 0, "liquidator repaid debt");
        assertGt(seized, 0, "liquidator seized collateral");
        assertApproxEqAbs(module.debtBalance(EMPTY, WAVAX), debtBefore - repaid, 1, "debt reduced by the repaid amount");
        assertLe(module.collateralBalance(EMPTY, SAVAX), collateralBefore - seized, "collateral reduced by at least the seized amount");
        _assertViewsMatchSpoke();
        _assertNoIdle(module);
        uint256 navAfter = box.totalAssets();
        assertLt(navAfter, navBefore, "the liquidation bonus is a loss for the Box");
        assertEq(module.nav(IOracleCallback(address(box))), navAfter - WAVAX.balanceOf(address(box)), "module nav is the rest");

        vm.startPrank(allocator);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        box.depledge(module, EMPTY, SAVAX, type(uint256).max);
        vm.stopPrank();
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), 0, "debt closed");
        assertEq(AVAX_SPOKE.getUserSuppliedShares(SAVAX_ID, address(module)), 0, "collateral withdrawn");
        _assertNoIdle(module);

        vm.startPrank(curator);
        box.removeFundingFacility(module, EMPTY);
        box.removeFundingCollateral(module, SAVAX);
        box.removeFundingDebt(module, WAVAX);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
    }

    /// @dev A factory-created module becomes usable only once the timelocked addFunding has been executed
    function testTimelockedAttachOfFactoryModule() public {
        Box box2 = new Box(address(WAVAX), owner, curator, "Box WAVAX 2", "BOXWAVAX2", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);
        FundingAaveV4 module2 = factory.createFundingAaveV4(address(box2), address(AVAX_SPOKE), _ids2(SAVAX_ID, WAVAX_ID), LLTV_CAP);
        assertTrue(factory.isFundingAaveV4(address(module2)), "created by the factory");
        assertEq(module2.owner(), address(box2), "owned by the Box");

        vm.startPrank(curator);
        box2.setGuardianInstant(guardian);
        box2.addTokenInstant(SAVAX, savaxOracle);
        box2.setIsAllocator(allocator, true);
        box2.addFeederInstant(address(this));
        box2.increaseTimelock(IBox.addFunding.selector, 1 days);
        box2.submit(abi.encodeWithSelector(IBox.addFunding.selector, address(module2)));
        vm.stopPrank();

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.TimelockNotExpired.selector);
        box2.addFunding(module2);
        assertFalse(box2.isFunding(module2), "not attached before the delay");

        deal(address(SAVAX), address(box2), 100e18);
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box2.pledge(module2, EMPTY, SAVAX, 100e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(anyone);
        box2.addFunding(module2);
        assertTrue(box2.isFunding(module2), "attached after the delay by an address with no role");

        vm.startPrank(curator);
        box2.addFundingFacilityInstant(module2, EMPTY);
        box2.addFundingCollateralInstant(module2, SAVAX);
        box2.addFundingDebtInstant(module2, WAVAX);
        vm.stopPrank();

        vm.startPrank(allocator);
        box2.pledge(module2, EMPTY, SAVAX, 100e18);
        box2.borrow(module2, EMPTY, WAVAX, 50e18);
        vm.stopPrank();

        assertEq(WAVAX.balanceOf(address(box2)), 50e18, "borrowed WAVAX delivered to the Box");
        assertEq(SAVAX.balanceOf(address(box2)), 0, "sAVAX pledged");
        assertApproxEqAbs(module2.collateralBalance(EMPTY, SAVAX), 100e18, 1, "collateral supplied (rounded down)");
        assertApproxEqAbs(module2.debtBalance(EMPTY, WAVAX), 50e18, 1, "debt recorded (rounded up)");
    }

    // ========== AVAX CORRELATED SPOKE: sAVAX / WAVAX ==========

    function testPledgeBorrowIsNavNeutral() public {
        uint256 navBefore = box.totalAssets();

        vm.prank(allocator);
        box.pledge(module, EMPTY, SAVAX, 1_000e18);

        (bool usingAsCollateral, ) = AVAX_SPOKE.getUserReserveStatus(SAVAX_ID, address(module));
        assertTrue(usingAsCollateral, "sAVAX enabled as collateral");
        IAaveV4Spoke.UserAccountData memory data = AVAX_SPOKE.getUserAccountData(address(module));
        assertGe(data.activeCollateralCount, 1, "active collateral counted");
        assertGt(data.totalCollateralValue, 0, "collateral valued by the Spoke");
        assertApproxEqAbs(box.totalAssets(), navBefore, 1, "pledge is nav neutral");

        uint256 wavaxBefore = WAVAX.balanceOf(address(box));
        vm.prank(allocator);
        box.borrow(module, EMPTY, WAVAX, 1_000e18);
        uint256 navAfter = box.totalAssets();

        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);
        assertEq(WAVAX.balanceOf(address(box)) - wavaxBefore, 1_000e18, "Box received exactly the borrowed amount");
        assertApproxEqAbs(navAfter, navBefore, 2, "pledge + borrow is nav neutral");
        _assertNoIdle(module);

        uint256 debt = AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module));
        uint256 supplied = AVAX_SPOKE.getUserSuppliedAssets(SAVAX_ID, address(module));
        assertApproxEqAbs(debt, 1_000e18, 1, "debt = borrowed amount (rounded up)");
        assertApproxEqAbs(supplied, 1_000e18, 1, "supplied = pledged amount (rounded down)");

        uint256 expectedLtv = (debt * avaxSpokeOracle.getReservePrice(WAVAX_ID) * 1e18) /
            (supplied * avaxSpokeOracle.getReservePrice(SAVAX_ID));
        uint256 ltv = module.ltv(EMPTY);
        console2.log("ltv", ltv);
        assertApproxEqRel(ltv, expectedLtv, 1e9, "ltv matches the Spoke oracle within 1e-9");
        assertGt(ltv, 0.77e18, "ltv around 0.7776");
        assertLt(ltv, 0.785e18, "ltv around 0.7776");
    }

    function testLeverageLoopStaysInsideCap() public {
        MockSwapper swapper = _newSwapper();
        uint256 navBefore = box.totalAssets();

        vm.prank(allocator);
        box.pledge(module, EMPTY, SAVAX, 1_000e18);
        uint256 totalPledged = 1_000e18;
        uint256 totalBorrowed;

        for (uint256 i = 0; i < 3; i++) {
            uint256 step = 1_000e18;
            vm.startPrank(allocator);
            uint256 savaxBefore = SAVAX.balanceOf(address(box));
            box.allocate(SAVAX, step, ISwapper(address(swapper)), "");
            uint256 bought = SAVAX.balanceOf(address(box)) - savaxBefore;
            box.pledge(module, EMPTY, SAVAX, bought);
            box.borrow(module, EMPTY, WAVAX, step);
            vm.stopPrank();

            totalPledged += bought;
            totalBorrowed += step;
            uint256 collateral = module.collateralBalance(EMPTY, SAVAX);
            uint256 debt = module.debtBalance(EMPTY, WAVAX);
            console2.log("iteration", i + 1);
            console2.log("  collateral  ", collateral);
            console2.log("  debt        ", debt);
            console2.log("  ltv         ", module.ltv(EMPTY));
            console2.log("  totalAssets ", box.totalAssets());
            assertApproxEqAbs(collateral, totalPledged, i + 2, "collateral = total pledged (1 wei per supply)");
            assertApproxEqAbs(debt, totalBorrowed, i + 1, "debt = total borrowed (1 wei per borrow)");
            _assertNoIdle(module);
        }

        uint256 capLtv = (0.95e18 * LLTV_CAP) / 1e18;
        assertLe(module.ltv(EMPTY), capLtv, "final ltv within collateral factor x lltvCap");
        assertApproxEqRel(box.totalAssets(), navBefore, 0.0001e18, "loop keeps nav within 0.01%");
        assertEq(SAVAX.balanceOf(address(box)), 0, "everything bought was pledged");
    }

    function testInterestAccrualLowersNavByAccruedInterest() public {
        _open(1_000e18);
        _assertViewsMatchSpoke();
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        uint256 navBefore = box.totalAssets();
        uint256 ltvBefore = module.ltv(EMPTY);
        uint256 priceBefore = savaxOracle.price();

        vm.warp(block.timestamp + 30 days);

        uint256 debtAfter = module.debtBalance(EMPTY, WAVAX);
        uint256 navAfter = box.totalAssets();
        console2.log("debt before", debtBefore);
        console2.log("debt after ", debtAfter);
        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);

        assertEq(savaxOracle.price(), priceBefore, "sAVAX/WAVAX Spoke price unchanged on the fork");
        assertGt(debtAfter, debtBefore, "interest accrued without a transaction");
        assertGt(debtAfter - debtBefore, 3e18, "about 3.3 WAVAX of interest over 30 days");
        assertLt(debtAfter - debtBefore, 3.6e18, "about 3.3 WAVAX of interest over 30 days");
        assertApproxEqAbs(navBefore - navAfter, debtAfter - debtBefore, 2, "nav drops by exactly the accrued interest");
        assertGt(module.ltv(EMPTY), ltvBefore, "ltv rises with the debt");
        assertEq(module.nav(IOracleCallback(address(box))), navAfter - WAVAX.balanceOf(address(box)), "module nav is the rest");
        _assertViewsMatchSpoke();
    }

    function testBorrowBeyondCapReverts() public {
        _open(1_000e18);
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        uint256 wavaxBefore = WAVAX.balanceOf(address(box));
        uint256 navBefore = box.totalAssets();

        // Beyond 95% of the collateral-factor limit, still inside Aave's own limit
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, EMPTY, WAVAX, 200e18);

        // Beyond Aave's collateral-factor limit
        vm.prank(allocator);
        vm.expectRevert(HEALTH_FACTOR_BELOW_THRESHOLD);
        box.borrow(module, EMPTY, WAVAX, 400e18);

        assertEq(module.debtBalance(EMPTY, WAVAX), debtBefore, "debt unchanged");
        assertEq(WAVAX.balanceOf(address(box)), wavaxBefore, "Box WAVAX unchanged");
        assertEq(box.totalAssets(), navBefore, "totalAssets unchanged");

        // Just inside the cap still works
        vm.prank(allocator);
        box.borrow(module, EMPTY, WAVAX, 100e18);
        assertGe(AVAX_SPOKE.getUserAccountData(address(module)).healthFactor, module.minHealthFactor(), "guard holds");
    }

    function testDepledgeBeyondCapReverts() public {
        _open(1_000e18);
        uint256 suppliedBefore = module.collateralBalance(EMPTY, SAVAX);
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);

        // Health factor would be about 1.0385, below ceil(1e36 / 0.95e18)
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, EMPTY, SAVAX, 150e18);
        assertEq(module.collateralBalance(EMPTY, SAVAX), suppliedBefore, "collateral unchanged");
        assertEq(module.debtBalance(EMPTY, WAVAX), debtBefore, "debt unchanged");
        assertEq(SAVAX.balanceOf(address(box)), 0, "nothing delivered");

        vm.prank(allocator);
        box.depledge(module, EMPTY, SAVAX, 10e18);
        assertEq(SAVAX.balanceOf(address(box)), 10e18, "Box received exactly the depledged amount");
        assertApproxEqAbs(module.collateralBalance(EMPTY, SAVAX), suppliedBefore - 10e18, 1, "collateral reduced");
        assertGe(AVAX_SPOKE.getUserAccountData(address(module)).healthFactor, module.minHealthFactor(), "guard holds");
        _assertNoIdle(module);
    }

    function testFullUnwindAfterAccrualAndRemovalOrder() public {
        uint256 savaxBeforePledge = SAVAX.balanceOf(address(box));
        _open(1_000e18);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingFacility(module, EMPTY);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingCollateral(module, SAVAX);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingDebt(module, WAVAX);
        vm.stopPrank();

        uint256 debt = module.debtBalance(EMPTY, WAVAX);
        uint256 wavaxBefore = WAVAX.balanceOf(address(box));
        vm.prank(allocator);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);

        assertEq(wavaxBefore - WAVAX.balanceOf(address(box)), debt, "Box paid exactly the debt");
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), 0, "no debt left");
        IAaveV4Spoke.UserPosition memory position = AVAX_SPOKE.getUserPosition(WAVAX_ID, address(module));
        assertEq(position.drawnShares, 0, "no drawn shares");
        assertEq(position.premiumShares, 0, "no premium shares");
        (, bool borrowing) = AVAX_SPOKE.getUserReserveStatus(WAVAX_ID, address(module));
        assertFalse(borrowing, "borrowing flag cleared");
        assertEq(WAVAX.balanceOf(address(module)), 0, "no WAVAX left in the module");

        vm.prank(allocator);
        box.depledge(module, EMPTY, SAVAX, type(uint256).max);
        assertEq(AVAX_SPOKE.getUserSuppliedShares(SAVAX_ID, address(module)), 0, "no supplied shares left");
        assertEq(module.collateralBalance(EMPTY, SAVAX), 0, "no collateral left");
        assertApproxEqAbs(SAVAX.balanceOf(address(box)), savaxBeforePledge, 1, "all sAVAX back in the Box");
        _assertNoIdle(module);

        vm.startPrank(curator);
        box.removeFundingFacility(module, EMPTY);
        box.removeFundingCollateral(module, SAVAX);
        box.removeFundingDebt(module, WAVAX);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module), "module detached");
        assertEq(
            box.totalAssets(),
            WAVAX.balanceOf(address(box)) + (SAVAX.balanceOf(address(box)) * savaxOracle.price()) / 1e36,
            "totalAssets is only idle Box holdings"
        );
    }

    /// @dev Borrows stay at or below 1 WAVAX per sAVAX (ltv about 0.78), inside the 0.9025 guard cap. The only nav
    ///      change over the round trip is the interest paid; sAVAX returns to the Box within 1 wei of supply rounding.
    /// forge-config: default.fuzz.runs = 16
    function testFuzz_PledgeBorrowRepayDepledgeRoundTrip(uint256 collateral, uint256 borrowAmount, uint256 elapsed) public {
        collateral = bound(collateral, 1e18, 1_000e18);
        borrowAmount = bound(borrowAmount, 1e15, collateral);
        elapsed = bound(elapsed, 0, 30 days);

        uint256 savaxBefore = SAVAX.balanceOf(address(box));
        uint256 navBefore = box.totalAssets();

        vm.startPrank(allocator);
        box.pledge(module, EMPTY, SAVAX, collateral);
        uint256 wavaxBefore = WAVAX.balanceOf(address(box));
        box.borrow(module, EMPTY, WAVAX, borrowAmount);
        vm.stopPrank();

        assertEq(WAVAX.balanceOf(address(box)) - wavaxBefore, borrowAmount, "Box received exactly the borrowed amount");
        // Supply rounds down 1 wei of sAVAX (up to 2 wei of value), debt rounds up 1 wei, and the Box and module sAVAX
        // values are floored separately (1 wei)
        assertApproxEqAbs(box.totalAssets(), navBefore, 4, "pledge + borrow nav neutral within 4 wei");
        assertLe(module.ltv(EMPTY), (0.95e18 * LLTV_CAP) / 1e18, "ltv within collateral factor x lltvCap");
        _assertViewsMatchSpoke();
        _assertNoIdle(module);

        vm.warp(block.timestamp + elapsed);
        uint256 debt = module.debtBalance(EMPTY, WAVAX);
        assertGe(debt, borrowAmount, "debt never below the borrowed amount");
        uint256 interest = debt - borrowAmount;

        wavaxBefore = WAVAX.balanceOf(address(box));
        vm.startPrank(allocator);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        box.depledge(module, EMPTY, SAVAX, type(uint256).max);
        vm.stopPrank();

        assertEq(wavaxBefore - WAVAX.balanceOf(address(box)), debt, "repay(max) paid exactly the debt");
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), 0, "no debt left");
        assertEq(AVAX_SPOKE.getUserSuppliedShares(SAVAX_ID, address(module)), 0, "no supplied shares left");
        assertEq(module.debtBalance(EMPTY, WAVAX), 0, "facility debt 0");
        assertEq(module.collateralBalance(EMPTY, SAVAX), 0, "facility collateral 0");
        assertApproxEqAbs(SAVAX.balanceOf(address(box)), savaxBefore, 1, "all sAVAX back in the Box within 1 wei");
        _assertNoIdle(module);
        assertApproxEqAbs(box.totalAssets(), navBefore - interest, 2, "totalAssets = start - interest paid within 2 wei");
    }

    // ========== WINDDOWN ==========

    function testWinddownAnyoneRepaysAndDepledgesWithGuard() public {
        _open(1_000e18);
        _enterWinddown();

        vm.startPrank(allocator);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        box.pledge(module, EMPTY, SAVAX, 1);
        vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
        box.borrow(module, EMPTY, WAVAX, 1e18);
        vm.stopPrank();

        uint256 suppliedBefore = module.collateralBalance(EMPTY, SAVAX);
        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, EMPTY, SAVAX, 150e18);
        assertEq(module.collateralBalance(EMPTY, SAVAX), suppliedBefore, "guarded depledge left the position unchanged");

        vm.prank(anyone);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        assertEq(module.debtBalance(EMPTY, WAVAX), 0, "debt closed by a random address");
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), 0, "no debt on the Spoke");

        vm.prank(anyone);
        box.depledge(module, EMPTY, SAVAX, type(uint256).max);
        assertEq(AVAX_SPOKE.getUserSuppliedShares(SAVAX_ID, address(module)), 0, "no supplied shares left");
        assertEq(module.collateralBalance(EMPTY, SAVAX), 0, "no collateral left");
        assertApproxEqAbs(SAVAX.balanceOf(address(box)), 1_000e18, 1, "all collateral back in the Box");
        _assertNoIdle(module);
    }

    function testWinddownDeallocateOfTokenUnknownToModule() public {
        // 8,000 WAVAX per BTC.b; BTC.b has 8 decimals, WAVAX 18
        MockOracle btcbOracle = new MockOracle(8_000 * 1e10 * 1e36);
        vm.prank(curator);
        box.addTokenInstant(BTCB, btcbOracle);
        MockSwapper swapper = new MockSwapper();
        swapper.setOracle(BTCB, btcbOracle);
        swapper.setOracle(WAVAX, wavaxUnitOracle);
        deal(address(WAVAX), address(swapper), 10_000e18);
        deal(address(BTCB), address(box), 1e8);

        _open(1_000e18);
        _enterWinddown();
        vm.warp(block.timestamp + 1 days);
        assertGt(module.debtBalance(EMPTY, WAVAX), 0, "module still holds debt");

        IERC20[3] memory unknown = [BTCB, IERC20(address(0)), IERC20(address(0xdead))];
        for (uint256 i = 0; i < unknown.length; i++) {
            assertEq(module.debtBalance(unknown[i]), 0, "unknown token debt = 0");
            assertEq(module.collateralBalance(unknown[i]), 0, "unknown token collateral = 0");
            assertEq(module.debtBalance(EMPTY, unknown[i]), 0, "unknown token facility debt = 0");
            assertEq(module.collateralBalance(EMPTY, unknown[i]), 0, "unknown token facility collateral = 0");
        }

        uint256 wavaxBefore = WAVAX.balanceOf(address(box));
        vm.prank(anyone);
        box.deallocate(BTCB, 1e8, ISwapper(address(swapper)), "");
        assertEq(BTCB.balanceOf(address(box)), 0, "BTC.b sold");
        assertEq(WAVAX.balanceOf(address(box)) - wavaxBefore, 8_000e18, "sold at the oracle price");
        assertGt(box.totalAssets(), 0, "totalAssets computes");
    }

    // ========== RESERVE CONFIG REJECTIONS ==========

    function testTokensDisallowedByReserveConfigRejected() public {
        FundingAaveV4 fresh = factory.createFundingAaveV4(address(box), address(AVAX_SPOKE), _ids2(SAVAX_ID, WAVAX_ID), LLTV_CAP);
        vm.startPrank(curator);
        box.addFundingInstant(fresh);
        box.addFundingFacilityInstant(fresh, EMPTY);

        // WAVAX has a zero collateral factor on the AVAX Correlated Spoke
        box.submit(abi.encodeWithSelector(IBox.addFundingCollateral.selector, address(fresh), address(WAVAX)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFundingCollateral(fresh, WAVAX);

        // sAVAX is not borrowable there
        box.submit(abi.encodeWithSelector(IBox.addFundingDebt.selector, address(fresh), address(SAVAX)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFundingDebt(fresh, SAVAX);
        vm.stopPrank();

        assertEq(fresh.collateralTokensLength(), 0, "no collateral token registered");
        assertEq(fresh.debtTokensLength(), 0, "no debt token registered");

        // EURC has a zero collateral factor on the Main Spoke
        (Box usdcBox, FundingAaveV4 mainModule) = _deployMainBox();
        MockOracle eurcOracle = new MockOracle(1.14e36);
        vm.startPrank(curator);
        usdcBox.addTokenInstant(EURC, eurcOracle);
        usdcBox.submit(abi.encodeWithSelector(IBox.addFundingCollateral.selector, address(mainModule), address(EURC)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        usdcBox.addFundingCollateral(mainModule, EURC);
        vm.stopPrank();

        assertEq(mainModule.collateralTokensLength(), 1, "only USDt registered as collateral");
        assertEq(mainModule.debtTokensLength(), 1, "only USDC registered as debt");
        assertFalse(mainModule.isCollateralToken(EURC), "EURC rejected");
    }

    // ========== MAIN SPOKE: STABLECOIN CARRY ==========

    function testStablecoinCarryOnMainSpoke() public {
        (Box usdcBox, FundingAaveV4 mainModule) = _deployMainBox();
        IAaveV4Oracle mainOracle = IAaveV4Oracle(MAIN_SPOKE.ORACLE());

        deal(address(USDC), address(this), 10_000e6);
        USDC.approve(address(usdcBox), 10_000e6);
        usdcBox.deposit(10_000e6, address(this));
        deal(address(USDT), address(usdcBox), 100_000e6);

        // The module's deterministic test address already holds USDC and USDt dust on Avalanche: that stray balance
        // is not part of the position, so nav must ignore it and the carry must not add to it.
        uint256[] memory idleBefore = _idleBalances(mainModule);
        assertEq(mainModule.nav(IOracleCallback(address(usdcBox))), 0, "idle balances are not part of the module nav");

        uint256 navBefore = usdcBox.totalAssets();
        uint256 usdcBefore = USDC.balanceOf(address(usdcBox));
        vm.startPrank(allocator);
        usdcBox.pledge(mainModule, EMPTY, USDT, 100_000e6);
        usdcBox.borrow(mainModule, EMPTY, USDC, 70_000e6);
        vm.stopPrank();
        uint256 navAfter = usdcBox.totalAssets();

        console2.log("totalAssets before", navBefore);
        console2.log("totalAssets after ", navAfter);
        assertEq(USDC.balanceOf(address(usdcBox)) - usdcBefore, 70_000e6, "Box received exactly 70,000 USDC");
        assertApproxEqAbs(navAfter, navBefore, 2, "carry is nav neutral within 2 units");
        _assertIdleUnchanged(mainModule, idleBefore);

        uint256 debt = MAIN_SPOKE.getUserTotalDebt(MAIN_USDC_ID, address(mainModule));
        uint256 supplied = MAIN_SPOKE.getUserSuppliedAssets(MAIN_USDT_ID, address(mainModule));
        uint256 expectedLtv = (debt * mainOracle.getReservePrice(MAIN_USDC_ID) * 1e18) /
            (supplied * mainOracle.getReservePrice(MAIN_USDT_ID));
        uint256 ltv = mainModule.ltv(EMPTY);
        console2.log("ltv", ltv);
        assertApproxEqRel(ltv, expectedLtv, 1e9, "ltv matches the Spoke oracle within 1e-9");
        assertGt(ltv, 0.69e18, "ltv around 0.70");
        assertLt(ltv, 0.71e18, "ltv around 0.70");

        // Past 0.78 x 0.95 of the collateral value the guard stops the carry
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        usdcBox.borrow(mainModule, EMPTY, USDC, 5_000e6);

        // BTC.b is flagged borrowable, but its draw cap is 0 on this Spoke
        MockOracle btcbOracle = new MockOracle((84_000 * 1e36 * 1e6) / 1e8);
        vm.startPrank(curator);
        usdcBox.addTokenInstant(BTCB, btcbOracle);
        usdcBox.addFundingDebtInstant(mainModule, BTCB);
        vm.stopPrank();
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(DRAW_CAP_EXCEEDED, uint256(0)));
        usdcBox.borrow(mainModule, EMPTY, BTCB, 1e6);

        // Unwind
        vm.startPrank(allocator);
        usdcBox.repay(mainModule, EMPTY, USDC, type(uint256).max);
        usdcBox.depledge(mainModule, EMPTY, USDT, type(uint256).max);
        vm.stopPrank();
        assertEq(mainModule.debtBalance(EMPTY, USDC), 0, "carry closed");
        assertEq(MAIN_SPOKE.getUserSuppliedShares(MAIN_USDT_ID, address(mainModule)), 0, "no supplied shares left");
        assertApproxEqAbs(USDT.balanceOf(address(usdcBox)), 100_000e6, 1, "USDt back in the Box");
        _assertIdleUnchanged(mainModule, idleBefore);
    }

    // ========== GOVERNANCE ==========

    function testPausedReserveKeepsNavAndBlocksWhatSpokeBlocks() public {
        _open(1_000e18);
        uint256[6] memory before = _snapshot();

        // Debt reserve paused: views unchanged, repay and borrow blocked
        _setPaused(WAVAX_ID, true);
        _assertSnapshot(before);
        vm.startPrank(allocator);
        vm.expectRevert(RESERVE_PAUSED);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        vm.expectRevert(RESERVE_PAUSED);
        box.borrow(module, EMPTY, WAVAX, 1e18);
        vm.stopPrank();
        _setPaused(WAVAX_ID, false);

        // Collateral reserve paused: views unchanged, depledge blocked
        _setPaused(SAVAX_ID, true);
        _assertSnapshot(before);
        vm.prank(allocator);
        vm.expectRevert(RESERVE_PAUSED);
        box.depledge(module, EMPTY, SAVAX, 10e18);
        _setPaused(SAVAX_ID, false);

        _assertSnapshot(before);
        _unwindAndAssertClosed();
    }

    function testFrozenReserveBlocksWhatSpokeBlocks() public {
        _open(1_000e18);
        uint256[6] memory before = _snapshot();

        // Debt reserve frozen: borrow blocked, repay allowed
        _setFrozen(WAVAX_ID, true);
        _assertSnapshot(before);
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        vm.startPrank(allocator);
        vm.expectRevert(RESERVE_FROZEN);
        box.borrow(module, EMPTY, WAVAX, 1e18);
        box.repay(module, EMPTY, WAVAX, 100e18);
        vm.stopPrank();
        assertApproxEqAbs(module.debtBalance(EMPTY, WAVAX), debtBefore - 100e18, 1, "repay works on a frozen reserve");
        _setFrozen(WAVAX_ID, false);

        // Collateral reserve frozen: in-cap depledge allowed, pledge blocked
        _setFrozen(SAVAX_ID, true);
        vm.startPrank(allocator);
        box.depledge(module, EMPTY, SAVAX, 10e18);
        assertEq(SAVAX.balanceOf(address(box)), 10e18, "depledge works on a frozen reserve");
        vm.expectRevert(RESERVE_FROZEN);
        box.pledge(module, EMPTY, SAVAX, 10e18);
        vm.stopPrank();
        assertEq(SAVAX.balanceOf(address(box)), 10e18, "failed pledge kept the sAVAX in the Box");
        _setFrozen(SAVAX_ID, false);

        _unwindAndAssertClosed();
    }

    function testHaltedSpokeKeepsNavAndBlocksRepayAndDepledge() public {
        _open(1_000e18);
        uint256[6] memory before = _snapshot();

        // Debt asset halted for this Spoke
        _setHalted(WAVAX_ID, true);
        _assertSnapshot(before);
        vm.prank(allocator);
        vm.expectRevert(SPOKE_HALTED);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        _setHalted(WAVAX_ID, false);

        // Collateral asset halted for this Spoke
        _setHalted(SAVAX_ID, true);
        _assertSnapshot(before);
        vm.prank(allocator);
        vm.expectRevert(SPOKE_HALTED);
        box.depledge(module, EMPTY, SAVAX, 10e18);
        _setHalted(SAVAX_ID, false);

        _unwindAndAssertClosed();
    }

    function testLoweredCollateralFactorBlocksBorrowAndDepledgeNotRepay() public {
        _open(1_000e18);
        uint256[6] memory before = _snapshot();
        uint256 ltvBefore = module.ltv(EMPTY);
        uint256 hfBefore = AVAX_SPOKE.getUserAccountData(address(module)).healthFactor;

        // CF 40% would put the position at a health factor of about 0.51
        vm.prank(SPOKE_CONFIGURATOR);
        ISpokeAdmin(address(AVAX_SPOKE)).addDynamicReserveConfig(SAVAX_ID, IAaveV4Spoke.DynamicReserveConfig(4000, 11000, 1000));
        uint32 latestKey = AVAX_SPOKE.getReserve(SAVAX_ID).dynamicConfigKey;
        assertEq(AVAX_SPOKE.getDynamicReserveConfig(SAVAX_ID, latestKey).collateralFactor, 4000, "new key is the latest");

        _assertSnapshot(before);
        assertEq(module.ltv(EMPTY), ltvBefore, "ltv unchanged (stale key)");
        assertEq(AVAX_SPOKE.getUserAccountData(address(module)).healthFactor, hfBefore, "view health factor unchanged (stale key)");

        vm.startPrank(allocator);
        vm.expectRevert(HEALTH_FACTOR_BELOW_THRESHOLD);
        box.borrow(module, EMPTY, WAVAX, 1);
        vm.expectRevert(HEALTH_FACTOR_BELOW_THRESHOLD);
        box.depledge(module, EMPTY, SAVAX, 1);

        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        box.repay(module, EMPTY, WAVAX, 100e18);
        assertApproxEqAbs(module.debtBalance(EMPTY, WAVAX), debtBefore - 100e18, 1, "partial repay works");
        vm.stopPrank();

        _unwindAndAssertClosed();
    }

    // ========== FLASH LEVERAGE (AAVE V3 POOL) ==========

    function testFlashLoanLeverageThroughAaveV3() public {
        _open(1_000e18);
        MockSwapper swapper = _newSwapper();

        FlashLoanAave flash = new FlashLoanAave(IPoolAddressesProviderAave(AAVE_V3_PROVIDER));
        assertEq(address(flash.POOL()), AAVE_V3_POOL, "Aave v3 pool on Avalanche");
        uint256 premiumBps = flash.POOL().FLASHLOAN_PREMIUM_TOTAL();
        assertEq(premiumBps, 5, "0.05% flash premium");
        vm.prank(curator);
        box.setIsAllocator(address(flash), true);

        // The allocator pays the premium of both flash loans
        deal(address(WAVAX), allocator, 1e18);
        vm.prank(allocator);
        WAVAX.approve(address(flash), type(uint256).max);

        uint256 loan = 1_000e18;
        uint256 collateralBefore = module.collateralBalance(EMPTY, SAVAX);
        uint256 debtBefore = module.debtBalance(EMPTY, WAVAX);
        uint256 navBefore = box.totalAssets();
        uint256 expectedBought = (loan * 1e36) / savaxOracle.price();

        vm.prank(allocator);
        flash.leverage(box, module, EMPTY, ISwapper(address(swapper)), "", SAVAX, WAVAX, loan);

        uint256 collateralAfter = module.collateralBalance(EMPTY, SAVAX);
        uint256 debtAfter = module.debtBalance(EMPTY, WAVAX);
        uint256 ltv = module.ltv(EMPTY);
        uint256 navAfter = box.totalAssets();
        console2.log("collateral", collateralBefore, "->", collateralAfter);
        console2.log("debt      ", debtBefore, "->", debtAfter);
        console2.log("ltv       ", ltv);
        console2.log("totalAssets", navBefore, "->", navAfter);

        assertApproxEqAbs(collateralAfter - collateralBefore, expectedBought, 1, "collateral rises by the sAVAX bought");
        assertApproxEqAbs(debtAfter - debtBefore, loan, 1, "debt rises by the loan, the allocator pays the premium");
        assertEq(WAVAX.balanceOf(allocator), 1e18 - (loan * premiumBps) / 10_000, "allocator paid exactly the premium");
        assertEq(WAVAX.balanceOf(address(flash)), 0, "helper keeps no float");
        assertLe(ltv, (0.95e18 * LLTV_CAP) / 1e18, "ltv inside the cap");
        assertGe(AVAX_SPOKE.getUserAccountData(address(module)).healthFactor, module.minHealthFactor(), "guard holds");
        _assertNoIdle(module);
        assertEq(SAVAX.balanceOf(address(box)), 0, "all sAVAX bought was pledged");
        assertApproxEqRel(navAfter, navBefore, 0.001e18, "nav within 0.1%");

        // Partial deleverage with explicit amounts
        vm.prank(allocator);
        flash.deleverage(box, module, EMPTY, ISwapper(address(swapper)), "", SAVAX, 400e18, WAVAX, 500e18);

        assertApproxEqAbs(module.debtBalance(EMPTY, WAVAX), debtAfter - 500e18, 1, "debt lowered by the repaid loan");
        assertApproxEqAbs(module.collateralBalance(EMPTY, SAVAX), collateralAfter - 400e18, 1, "collateral lowered");
        assertEq(SAVAX.balanceOf(address(box)), 0, "withdrawn sAVAX sold back to WAVAX");
        _assertNoIdle(module);
        assertApproxEqRel(box.totalAssets(), navBefore, 0.001e18, "nav within 0.1% after deleverage");
    }

    // ========== HELPERS ==========

    function _ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _open(uint256 borrowAmount) internal {
        vm.startPrank(allocator);
        box.pledge(module, EMPTY, SAVAX, 1_000e18);
        box.borrow(module, EMPTY, WAVAX, borrowAmount);
        vm.stopPrank();
    }

    function _enterWinddown() internal {
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + MAX_SHUTDOWN_WARMUP + 1);
        assertTrue(box.isWinddown(), "winddown");
    }

    function _newSwapper() internal returns (MockSwapper swapper) {
        swapper = new MockSwapper();
        swapper.setOracle(WAVAX, wavaxUnitOracle);
        swapper.setOracle(SAVAX, savaxOracle);
        deal(address(WAVAX), address(swapper), 100_000e18);
        deal(address(SAVAX), address(swapper), 100_000e18);
    }

    /// @dev USDC Box with a Main Spoke module (WAVAX, BTC.b, USDC, USDt, EURC reserves), USDt collateral, USDC debt
    function _deployMainBox() internal returns (Box usdcBox, FundingAaveV4 mainModule) {
        usdcBox = new Box(address(USDC), owner, curator, "Box USDC", "BOXUSDC", 0.01 ether, 7 days, 10 days, MAX_SHUTDOWN_WARMUP);
        uint256[] memory ids = new uint256[](5);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = MAIN_USDC_ID;
        ids[3] = MAIN_USDT_ID;
        ids[4] = 5;
        mainModule = factory.createFundingAaveV4(address(usdcBox), address(MAIN_SPOKE), ids, LLTV_CAP);
        SpokeRatioOracle usdtOracle = new SpokeRatioOracle(IAaveV4Oracle(MAIN_SPOKE.ORACLE()), MAIN_USDT_ID, 6, MAIN_USDC_ID, 6);

        vm.startPrank(curator);
        usdcBox.setGuardianInstant(guardian);
        usdcBox.addTokenInstant(USDT, usdtOracle);
        usdcBox.setIsAllocator(allocator, true);
        usdcBox.addFeederInstant(address(this));
        usdcBox.addFundingInstant(mainModule);
        usdcBox.addFundingFacilityInstant(mainModule, EMPTY);
        usdcBox.addFundingCollateralInstant(mainModule, USDT);
        usdcBox.addFundingDebtInstant(mainModule, USDC);
        vm.stopPrank();
    }

    function _assertNoIdle(FundingAaveV4 m) internal view {
        _assertIdleUnchanged(m, new uint256[](m.reserveIdsArray().length));
    }

    /// @dev Module balance of the underlying of every configured reserve, in reserve list order
    function _idleBalances(FundingAaveV4 m) internal view returns (uint256[] memory balances) {
        uint256[] memory ids = m.reserveIdsArray();
        IAaveV4Spoke s = m.spoke();
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            balances[i] = IERC20(s.getReserve(ids[i]).underlying).balanceOf(address(m));
        }
    }

    function _assertIdleUnchanged(FundingAaveV4 m, uint256[] memory expected) internal view {
        uint256[] memory balances = _idleBalances(m);
        for (uint256 i = 0; i < balances.length; i++) {
            assertEq(balances[i], expected[i], "module holds no idle configured token beyond its starting balance");
        }
    }

    function _assertViewsMatchSpoke() internal view {
        uint256 debt = AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module));
        uint256 supplied = AVAX_SPOKE.getUserSuppliedAssets(SAVAX_ID, address(module));
        assertEq(module.debtBalance(EMPTY, WAVAX), debt, "facility debt = Spoke total debt");
        assertEq(module.debtBalance(WAVAX), debt, "token debt = Spoke total debt");
        assertEq(module.collateralBalance(EMPTY, SAVAX), supplied, "facility collateral = Spoke supplied assets");
        assertEq(module.collateralBalance(SAVAX), supplied, "token collateral = Spoke supplied assets");
    }

    /// @dev totalAssets, module nav and the four balance views
    function _snapshot() internal view returns (uint256[6] memory s) {
        s[0] = box.totalAssets();
        s[1] = module.nav(IOracleCallback(address(box)));
        s[2] = module.debtBalance(EMPTY, WAVAX);
        s[3] = module.collateralBalance(EMPTY, SAVAX);
        s[4] = module.debtBalance(WAVAX);
        s[5] = module.collateralBalance(SAVAX);
    }

    function _assertSnapshot(uint256[6] memory expected) internal view {
        uint256[6] memory s = _snapshot();
        assertEq(s[0], expected[0], "totalAssets unchanged");
        assertEq(s[1], expected[1], "module nav unchanged");
        assertEq(s[2], expected[2], "facility debt unchanged");
        assertEq(s[3], expected[3], "facility collateral unchanged");
        assertEq(s[4], expected[4], "token debt unchanged");
        assertEq(s[5], expected[5], "token collateral unchanged");
    }

    function _unwindAndAssertClosed() internal {
        vm.startPrank(allocator);
        box.repay(module, EMPTY, WAVAX, type(uint256).max);
        box.depledge(module, EMPTY, SAVAX, type(uint256).max);
        vm.stopPrank();
        assertEq(AVAX_SPOKE.getUserTotalDebt(WAVAX_ID, address(module)), 0, "debt closed");
        assertEq(AVAX_SPOKE.getUserSuppliedShares(SAVAX_ID, address(module)), 0, "collateral withdrawn");
        assertApproxEqAbs(SAVAX.balanceOf(address(box)), 1_000e18, 1, "all sAVAX back in the Box");
        _assertNoIdle(module);
    }

    function _setPaused(uint256 reserveId, bool paused) internal {
        IAaveV4Spoke.ReserveConfig memory config = AVAX_SPOKE.getReserveConfig(reserveId);
        config.paused = paused;
        vm.prank(SPOKE_CONFIGURATOR);
        ISpokeAdmin(address(AVAX_SPOKE)).updateReserveConfig(reserveId, config);
        assertEq(AVAX_SPOKE.getReserveConfig(reserveId).paused, paused, "paused flag applied");
    }

    function _setFrozen(uint256 reserveId, bool frozen) internal {
        IAaveV4Spoke.ReserveConfig memory config = AVAX_SPOKE.getReserveConfig(reserveId);
        config.frozen = frozen;
        vm.prank(SPOKE_CONFIGURATOR);
        ISpokeAdmin(address(AVAX_SPOKE)).updateReserveConfig(reserveId, config);
        assertEq(AVAX_SPOKE.getReserveConfig(reserveId).frozen, frozen, "frozen flag applied");
    }

    function _setHalted(uint256 reserveId, bool halted) internal {
        IAaveV4Spoke.Reserve memory reserve = AVAX_SPOKE.getReserve(reserveId);
        IAaveV4Hub hub = IAaveV4Hub(reserve.hub);
        IAaveV4Hub.SpokeConfig memory config = hub.getSpokeConfig(reserve.assetId, address(AVAX_SPOKE));
        config.halted = halted;
        vm.prank(HUB_CONFIGURATOR);
        IHubAdmin(address(hub)).updateSpokeConfig(reserve.assetId, address(AVAX_SPOKE), config);
        assertEq(hub.getSpokeConfig(reserve.assetId, address(AVAX_SPOKE)).halted, halted, "halted flag applied");
    }
}
