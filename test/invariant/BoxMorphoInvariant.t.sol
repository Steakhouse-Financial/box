// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {IrmMock} from "@morpho-blue/mocks/IrmMock.sol";
import {OracleMock} from "@morpho-blue/mocks/OracleMock.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingMorpho} from "../../src/FundingMorpho.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockSwapper} from "../mocks/MockSwapper.sol";
import {BoxMorphoHandler, BoxMorphoSystem} from "./handlers/BoxMorphoHandler.sol";

/// @notice Stateful invariants of a real Box with FundingMorpho on a local Morpho Blue. The handler drives deposits,
/// withdrawals, redemptions, swaps, pledge/borrow/repay/depledge on three facilities, time, WETH price moves, donations,
/// skims and a guardian shutdown followed by winddown actions from an address with no role.
/// @dev Facilities: WETH -> USDC (LLTV 86%), USDC -> WETH (91.5%) and WETH -> USDC (77%); lltvCap 90%. USDC is the Box
///      asset (valued 1:1), WETH a Box token with a MockOracle that the swapper and the Morpho market oracles follow.
contract BoxMorphoInvariantTest is Test {
    using BoxLib for IBox;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;

    uint256 internal constant ORACLE_SCALE = 1e36;
    uint256 internal constant WETH_PRICE = 3_000e24; // 3,000 USDC per WETH
    uint256 internal constant LLTV_CAP = 0.9e18;

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal supplier = makeAddr("supplier");

    IMorpho internal morpho;
    IBox internal box;
    FundingMorpho internal module;
    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal weth;
    MockOracle internal wethOracle;
    MarketParams[3] internal markets;
    BoxMorphoHandler internal handler;

    function setUp() public {
        morpho = IMorpho(address(new Morpho(address(this))));
        address irm = address(new IrmMock());
        morpho.enableIrm(irm);
        usdc = new ERC20MockDecimals(6);
        weth = new ERC20MockDecimals(18);
        wethOracle = new MockOracle(WETH_PRICE);

        markets[0] = _createMarket(address(usdc), address(weth), WETH_PRICE, irm, 0.86e18);
        markets[1] = _createMarket(address(weth), address(usdc), Math.mulDiv(ORACLE_SCALE, ORACLE_SCALE, WETH_PRICE), irm, 0.915e18);
        markets[2] = _createMarket(address(usdc), address(weth), WETH_PRICE, irm, 0.77e18);
        _supply(markets[0], 20_000_000e6);
        _supply(markets[1], 5_000e18);
        _supply(markets[2], 20_000_000e6);

        box = IBox(address(new Box(address(usdc), boxOwner, curator, "Box Invariant", "BOXI", 0.01 ether, 7 days, 10 days, 1 days)));
        module = new FundingMorpho(address(box), address(morpho), LLTV_CAP);

        address[3] memory feeders = [makeAddr("feeder0"), makeAddr("feeder1"), makeAddr("feeder2")];
        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(weth, wethOracle);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, weth);
        box.addFundingCollateralInstant(module, usdc);
        box.addFundingDebtInstant(module, usdc);
        box.addFundingDebtInstant(module, weth);
        for (uint256 i; i < 3; i++) {
            box.addFundingFacilityInstant(module, abi.encode(markets[i]));
            box.addFeederInstant(feeders[i]);
        }
        vm.stopPrank();

        MockSwapper swapper = new MockSwapper();
        swapper.setOracle(usdc, new MockOracle(ORACLE_SCALE));
        swapper.setOracle(weth, wethOracle);
        usdc.mint(address(swapper), 1e30);
        weth.mint(address(swapper), 1e30);

        // Starting state: 1M USDC deposited, 100 WETH held, one open position
        usdc.mint(feeders[0], 1_000_000e6);
        vm.startPrank(feeders[0]);
        usdc.approve(address(box), 1_000_000e6);
        box.deposit(1_000_000e6, feeders[0]);
        vm.stopPrank();
        weth.mint(address(box), 100e18);
        vm.startPrank(allocator);
        box.pledge(module, abi.encode(markets[0]), weth, 50e18);
        box.borrow(module, abi.encode(markets[0]), usdc, 50_000e6);
        vm.stopPrank();

        handler = new BoxMorphoHandler(
            BoxMorphoSystem({
                box: box,
                module: module,
                morpho: morpho,
                usdc: usdc,
                weth: weth,
                wethOracle: wethOracle,
                swapper: swapper,
                markets: markets,
                allocator: allocator,
                guardian: guardian,
                feeders: feeders
            })
        );
        targetContract(address(handler));
    }

    // ========== INVARIANTS ==========

    /// @dev VAL-FUZZ-014: totalAssets = asset balance + floored value of every Box token + FundingMorpho nav
    function invariant_totalAssetsEqualsSumOfParts() public view {
        uint256 expected = usdc.balanceOf(address(box)) + module.nav(IOracleCallback(address(box)));
        uint256 length = box.tokensLength();
        for (uint256 i; i < length; i++) {
            IERC20 token = box.tokens(i);
            expected += Math.mulDiv(token.balanceOf(address(box)), box.oracles(token).price(), ORACLE_SCALE);
        }
        assertEq(box.totalAssets(), expected, "totalAssets = idle holdings + module nav");
    }

    /// @dev VAL-FUZZ-014: nav = sum over facilities of max(0, floor(collateral * p / 1e36) - ceil(debt * p / 1e36))
    function invariant_navMatchesPerFacilityReference() public view {
        uint256 expected;
        for (uint256 i; i < 3; i++) {
            MarketParams memory mp = markets[i];
            uint256 collateral = morpho.position(mp.id(), address(module)).collateral;
            if (collateral == 0) continue;
            uint256 collateralValue = Math.mulDiv(collateral, _boxPrice(mp.collateralToken), ORACLE_SCALE);
            uint256 debt = morpho.expectedBorrowAssets(mp, address(module));
            uint256 debtValue = Math.mulDiv(debt, _boxPrice(mp.loanToken), ORACLE_SCALE, Math.Rounding.Ceil);
            expected += collateralValue > debtValue ? collateralValue - debtValue : 0;
        }
        assertEq(module.nav(IOracleCallback(address(box))), expected, "nav = sum of floored per-facility values");
    }

    /// @dev VAL-FUZZ-014: token-level balances equal the sum of the per-facility balances of that token
    function invariant_balancesAggregateFacilities() public view {
        IERC20[2] memory tokens = [IERC20(address(usdc)), IERC20(address(weth))];
        for (uint256 t; t < 2; t++) {
            uint256 debt;
            uint256 collateral;
            for (uint256 i; i < 3; i++) {
                bytes memory fd = abi.encode(markets[i]);
                if (markets[i].loanToken == address(tokens[t])) debt += module.debtBalance(fd, tokens[t]);
                if (markets[i].collateralToken == address(tokens[t])) collateral += module.collateralBalance(fd, tokens[t]);
            }
            assertEq(module.debtBalance(tokens[t]), debt, "debtBalance(token) = sum of facility debts");
            assertEq(module.collateralBalance(tokens[t]), collateral, "collateralBalance(token) = sum of facility collateral");
        }
    }

    /// @dev VAL-FUZZ-014: totalAssets and nav never reverted after any action, and do not revert now
    function invariant_navNeverReverts() public view {
        assertEq(handler.navFailures(), 0, "no nav or totalAssets revert after any action");
        try box.totalAssets() returns (uint256) {} catch {
            assertTrue(false, "totalAssets reverts");
        }
        try module.nav(IOracleCallback(address(box))) returns (uint256) {} catch {
            assertTrue(false, "nav reverts");
        }
    }

    /// @dev VAL-FUZZ-015: the module holds exactly the donations not yet skimmed, and skims never touch nav
    function invariant_moduleHoldsOnlyDonations() public view {
        assertEq(usdc.balanceOf(address(module)), handler.donations(address(usdc)), "idle USDC = unskimmed donations");
        assertEq(weth.balanceOf(address(module)), handler.donations(address(weth)), "idle WETH = unskimmed donations");
        assertEq(handler.skimNavChanges(), 0, "skimming a donation leaves nav unchanged");
        assertEq(handler.skimFailures(), 0, "a donation can always be skimmed");
    }

    /// @dev VAL-FUZZ-015: every successful borrow or depledge left the facility at or below lltv * lltvCap
    function invariant_ltvWithinCapAfterBorrowAndDepledge() public view {
        assertEq(handler.ltvViolations(), 0, "ltv <= lltv * lltvCap right after every borrow and depledge");
    }

    /// @dev VAL-FUZZ-015: no deposit, withdraw or redeem decreased the price per share
    function invariant_sharePriceNotDecreasedByDepositOrWithdrawal() public view {
        assertEq(handler.sharePriceDecreases(), 0, "deposit/withdraw/redeem never decrease the share price");
    }

    /// @dev Non-vacuity: every sequence executes actions (reverted calls are not counted)
    function afterInvariant() public view {
        assertGt(handler.successfulActions(), 0, "the sequence executed at least one action");
    }

    // ========== HANDLER COVERAGE ==========

    /// @dev Drives every handler action once, in the normal regime then in winddown through the role-less stranger, and
    ///      checks each one really executed and that all invariants hold along the way
    function testHandlerExecutesEveryAction() public {
        handler.deposit(0, 100_000e6);
        handler.withdraw(0, 10e6);
        handler.redeem(0, 1e18);
        handler.allocate(50_000e6);
        handler.pledge(0, 10e18 + 1);
        handler.pledge(1, 100_000e6);
        handler.borrow(0, 1_000e6);
        handler.borrow(1, 1e18);
        handler.repay(0, 1);
        handler.depledge(0, 1e18 + 1);
        handler.warp(1 hours);
        handler.movePrice(3_100e24);
        handler.donate(true, 1e18);
        handler.skim(true);
        handler.deallocate(weth.balanceOf(address(box))); // sells every WETH so that winddown needs an allocation to repay
        handler.donate(false, 5e6);
        _checkAllInvariants();

        handler.shutdown();
        handler.warp(2 days);
        assertTrue(box.isWinddown(), "winddown reached");
        // Exactly the value of the WETH shortfall, within the winddown cap
        handler.allocate(Math.mulDiv(module.debtBalance(weth), wethOracle.price(), ORACLE_SCALE, Math.Rounding.Ceil));
        handler.repay(1, 0); // type(uint256).max
        handler.depledge(1, 0); // type(uint256).max
        handler.repay(0, 0);
        handler.depledge(0, 0);
        handler.skim(false);
        handler.deallocate(weth.balanceOf(address(box)));
        _checkAllInvariants();

        assertEq(handler.depositOk(), 1, "deposit");
        assertEq(handler.withdrawOk(), 1, "withdraw");
        assertEq(handler.redeemOk(), 1, "redeem");
        assertEq(handler.allocateOk(), 2, "allocate");
        assertEq(handler.deallocateOk(), 2, "deallocate");
        assertEq(handler.pledgeOk(), 2, "pledge");
        assertEq(handler.borrowOk(), 2, "borrow");
        assertEq(handler.repayOk(), 3, "repay");
        assertEq(handler.depledgeOk(), 3, "depledge");
        assertEq(handler.warpOk(), 2, "warp");
        assertEq(handler.priceOk(), 1, "price");
        assertEq(handler.donateOk(), 2, "donate");
        assertEq(handler.skimOk(), 2, "skim");
        assertEq(handler.shutdownOk(), 1, "shutdown");
        assertEq(handler.winddownActionOk(), 7, "winddown actions by the stranger");
        assertEq(module.debtBalance(weth), 0, "WETH debt closed in winddown");
        assertEq(module.debtBalance(usdc), 0, "USDC debt closed in winddown");
    }

    // ========== HELPERS ==========

    function _checkAllInvariants() internal view {
        invariant_totalAssetsEqualsSumOfParts();
        invariant_navMatchesPerFacilityReference();
        invariant_balancesAggregateFacilities();
        invariant_navNeverReverts();
        invariant_moduleHoldsOnlyDonations();
        invariant_ltvWithinCapAfterBorrowAndDepledge();
        invariant_sharePriceNotDecreasedByDepositOrWithdrawal();
    }

    function _boxPrice(address token) internal view returns (uint256) {
        return token == address(usdc) ? ORACLE_SCALE : box.oracles(IERC20(token)).price();
    }

    function _createMarket(
        address loanToken,
        address collateralToken,
        uint256 price,
        address irm,
        uint256 lltv
    ) internal returns (MarketParams memory mp) {
        OracleMock oracle = new OracleMock();
        oracle.setPrice(price);
        if (!morpho.isLltvEnabled(lltv)) morpho.enableLltv(lltv);
        mp = MarketParams(loanToken, collateralToken, address(oracle), irm, lltv);
        morpho.createMarket(mp);
    }

    function _supply(MarketParams memory mp, uint256 amount) internal {
        ERC20MockDecimals(mp.loanToken).mint(supplier, amount);
        vm.startPrank(supplier);
        IERC20(mp.loanToken).approve(address(morpho), amount);
        morpho.supply(mp, amount, 0, supplier, "");
        vm.stopPrank();
    }
}
