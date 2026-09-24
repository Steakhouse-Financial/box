// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingAave, IPool} from "../src/FundingAave.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockAaveV3BalanceToken, MockAaveV3Pool} from "./mocks/MockAaveV3Pool.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockOracleProvider} from "./mocks/MockOracleProvider.sol";
import {MockSwapper} from "./mocks/MockSwapper.sol";

/// @dev Module-level tests: the module is owned by a mock oracle provider standing in for the Box.
contract FundingAaveTest is Test {
    MockAaveV3Pool internal pool;
    ERC20MockDecimals internal loan; // Box asset stand-in, 18 decimals
    ERC20MockDecimals internal coll; // listed, 18 decimals
    ERC20MockDecimals internal debtX; // listed, 6 decimals
    ERC20MockDecimals internal unlisted; // deployed token that is not a reserve

    MockOracleProvider internal provider;
    MockOracle internal collOracle;
    MockOracle internal debtXOracle;
    address internal owner;

    FundingAave internal module;

    function setUp() public {
        pool = new MockAaveV3Pool();
        loan = new ERC20MockDecimals(18);
        coll = new ERC20MockDecimals(18);
        debtX = new ERC20MockDecimals(6);
        unlisted = new ERC20MockDecimals(18);

        pool.listReserve(address(loan), 1e8);
        pool.listReserve(address(coll), 2e8);
        pool.listReserve(address(debtX), 1e8);
        loan.mint(address(pool), 1_000_000e18);
        debtX.mint(address(pool), 1_000_000e6);

        provider = new MockOracleProvider(address(loan));
        collOracle = new MockOracle(2e36);
        debtXOracle = new MockOracle(1e48);
        provider.setOracle(coll, collOracle);
        provider.setOracle(debtX, debtXOracle);
        owner = address(provider);

        module = new FundingAave(owner, IPool(address(pool)), 0);
    }

    // ========== HELPERS ==========

    function _unknownTokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](3);
        tokens[0] = IERC20(address(unlisted));
        tokens[1] = IERC20(address(0));
        tokens[2] = IERC20(address(0xdead)); // no code
    }

    function _facilityDatas() internal pure returns (bytes[] memory fds) {
        fds = new bytes[](4);
        fds[0] = "";
        fds[1] = hex"00";
        fds[2] = abi.encode(uint256(1), address(0xbeef));
        fds[3] = bytes("not a facility");
    }

    function _assertUnknownTokenViewsAreZero() internal view {
        IERC20[] memory tokens = _unknownTokens();
        bytes[] memory fds = _facilityDatas();
        for (uint256 i; i < tokens.length; i++) {
            assertEq(module.debtBalance(tokens[i]), 0, "debtBalance(token)");
            assertEq(module.collateralBalance(tokens[i]), 0, "collateralBalance(token)");
            for (uint256 j; j < fds.length; j++) {
                assertEq(module.debtBalance(fds[j], tokens[i]), 0, "debtBalance(fd, token)");
                assertEq(module.collateralBalance(fds[j], tokens[i]), 0, "collateralBalance(fd, token)");
            }
        }
    }

    function _registerAll() internal {
        vm.startPrank(owner);
        module.addFacility("");
        module.addCollateralToken(coll);
        module.addCollateralToken(loan);
        module.addDebtToken(loan);
        module.addDebtToken(debtX);
        vm.stopPrank();
    }

    function _pledge(ERC20MockDecimals token, uint256 amount) internal {
        token.mint(address(module), amount);
        vm.prank(owner);
        module.pledge("", token, amount);
    }

    function _borrow(IERC20 token, uint256 amount) internal {
        vm.prank(owner);
        module.borrow("", token, amount);
    }

    function _aToken(IERC20 token) internal view returns (IERC20 aToken) {
        (, , , , , , , , address a, , , , , , ) = pool.getReserveData(address(token));
        return IERC20(a);
    }

    function _debtToken(IERC20 token) internal view returns (IERC20 debtToken) {
        (, , , , , , , , , , address d, , , , ) = pool.getReserveData(address(token));
        return IERC20(d);
    }

    // ========== MOCK FIDELITY ==========

    function testMockReportsUnlistedTokenLikeRealPool() public view {
        (, , , , , , , , address aToken, address stableDebtToken, address variableDebtToken, address strategy, , , ) = pool.getReserveData(
            address(unlisted)
        );
        assertEq(aToken, address(0), "aToken");
        assertEq(variableDebtToken, address(0), "variableDebtToken");
        assertTrue(stableDebtToken != address(0), "stable debt token is non-zero for unlisted assets");
        assertTrue(strategy != address(0), "strategy is non-zero for unlisted assets");
    }

    // ========== UNKNOWN-TOKEN VIEWS (VAL-AAVE3-001) ==========

    function testUnknownTokenViewsReturnZeroOnEmptyModule() public view {
        _assertUnknownTokenViewsAreZero();
    }

    function testUnknownTokenViewsReturnZeroWithOpenPosition() public {
        _registerAll();
        _pledge(coll, 100e18);
        _pledge(loan, 50e18);
        _borrow(loan, 30e18);
        _borrow(debtX, 10e6);
        pool.accrueDebt(address(module), address(loan), 1);

        _assertUnknownTokenViewsAreZero();

        bytes[] memory fds = _facilityDatas();
        for (uint256 j; j < fds.length; j++) {
            assertEq(module.collateralBalance(fds[j], coll), 100e18, "coll per-facility");
            assertEq(module.collateralBalance(fds[j], loan), 50e18, "loan coll per-facility");
            assertEq(module.debtBalance(fds[j], loan), 30e18 + 1, "loan debt per-facility");
            assertEq(module.debtBalance(fds[j], debtX), 10e6, "debtX per-facility");
        }
        assertEq(module.collateralBalance(coll), _aToken(coll).balanceOf(address(module)), "coll = aToken balance");
        assertEq(module.collateralBalance(loan), _aToken(loan).balanceOf(address(module)), "loan = aToken balance");
        assertEq(module.debtBalance(loan), _debtToken(loan).balanceOf(address(module)), "loan = debt token balance");
        assertEq(module.debtBalance(debtX), _debtToken(debtX).balanceOf(address(module)), "debtX = debt token balance");
        assertEq(module.debtBalance(coll), 0, "listed token without debt");
    }

    function testViewsCheckTheirOwnReserveField() public {
        ERC20MockDecimals halfListed = new ERC20MockDecimals(18);
        (address aToken, address debtToken) = pool.listReserve(address(halfListed), 1e8);
        vm.startPrank(address(pool));
        MockAaveV3BalanceToken(aToken).mint(address(module), 7);
        MockAaveV3BalanceToken(debtToken).mint(address(module), 9);
        vm.stopPrank();

        pool.setReserveTokens(address(halfListed), aToken, address(0));
        assertEq(module.collateralBalance(halfListed), 7, "aToken set");
        assertEq(module.debtBalance(halfListed), 0, "variable debt token unset");
        assertEq(module.debtBalance("", halfListed), 0, "variable debt token unset, per facility");

        pool.setReserveTokens(address(halfListed), address(0), debtToken);
        assertEq(module.collateralBalance(halfListed), 0, "aToken unset");
        assertEq(module.collateralBalance("", halfListed), 0, "aToken unset, per facility");
        assertEq(module.debtBalance(halfListed), 9, "variable debt token set");
    }

    // ========== ADD COLLATERAL TOKEN (VAL-AAVE3-002) ==========

    function testAddCollateralTokenRejectsUnlistedReserve() public {
        IERC20[] memory tokens = _unknownTokens();
        vm.startPrank(owner);
        for (uint256 i; i < tokens.length; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.addCollateralToken(tokens[i]);
        }
        vm.stopPrank();
        assertEq(module.collateralTokensLength(), 0, "no collateral token added");
        assertFalse(module.isCollateralToken(unlisted), "unlisted not registered");
    }

    function testAddCollateralTokenListedDuplicateAndAccess() public {
        vm.prank(owner);
        module.addCollateralToken(coll);
        assertEq(module.collateralTokensLength(), 1, "listed reserve added");
        assertTrue(module.isCollateralToken(coll), "coll registered");

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addCollateralToken(coll);

        vm.startPrank(address(0xbad));
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addCollateralToken(loan);
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addCollateralToken(unlisted);
        vm.stopPrank();
        assertEq(module.collateralTokensLength(), 1, "length unchanged");
    }

    function testAddCollateralTokenRequiresAToken() public {
        ERC20MockDecimals halfListed = new ERC20MockDecimals(18);
        (address aToken, ) = pool.listReserve(address(halfListed), 1e8);
        pool.setReserveTokens(address(halfListed), address(0), address(1));

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addCollateralToken(halfListed);

        pool.setReserveTokens(address(halfListed), aToken, address(0));
        vm.prank(owner);
        module.addCollateralToken(halfListed);
        assertTrue(module.isCollateralToken(halfListed), "only the aToken field matters");
    }

    // ========== ADD DEBT TOKEN (VAL-AAVE3-003) ==========

    function testAddDebtTokenRejectsUnlistedReserve() public {
        IERC20[] memory tokens = _unknownTokens();
        vm.startPrank(owner);
        for (uint256 i; i < tokens.length; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.addDebtToken(tokens[i]);
        }
        vm.stopPrank();
        assertEq(module.debtTokensLength(), 0, "no debt token added");
        assertFalse(module.isDebtToken(unlisted), "unlisted not registered");
    }

    function testAddDebtTokenListedDuplicateAndAccess() public {
        vm.prank(owner);
        module.addDebtToken(loan);
        assertEq(module.debtTokensLength(), 1, "listed reserve added");
        assertTrue(module.isDebtToken(loan), "loan registered");

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addDebtToken(loan);

        vm.startPrank(address(0xbad));
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addDebtToken(debtX);
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addDebtToken(unlisted);
        vm.stopPrank();
        assertEq(module.debtTokensLength(), 1, "length unchanged");
    }

    function testAddDebtTokenRequiresVariableDebtToken() public {
        ERC20MockDecimals halfListed = new ERC20MockDecimals(18);
        (, address debtToken) = pool.listReserve(address(halfListed), 1e8);
        pool.setReserveTokens(address(halfListed), address(1), address(0));

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addDebtToken(halfListed);

        pool.setReserveTokens(address(halfListed), address(0), debtToken);
        vm.prank(owner);
        module.addDebtToken(halfListed);
        assertTrue(module.isDebtToken(halfListed), "only the variable debt token field matters");
    }

    // ========== NAV (VAL-AAVE3-005) ==========

    function testNavZeroWithRegisteredTokensAndNoPosition() public {
        _registerAll();
        assertEq(module.nav(provider), 0, "empty position");
    }

    function testNavMatchesHandComputation() public {
        _registerAll();
        collOracle.setPrice(1.5e36 + 7);
        debtXOracle.setPrice(1e48 + 3);

        _pledge(coll, 100e18 + 1);
        _pledge(loan, 40e18);
        _borrow(loan, 25e18);
        _borrow(debtX, 20e6);
        pool.accrueDebt(address(module), address(loan), 1);
        pool.accrueDebt(address(module), address(debtX), 3);

        uint256 collValue = Math.mulDiv(100e18 + 1, 1.5e36 + 7, 1e36, Math.Rounding.Floor);
        uint256 debtXValue = Math.mulDiv(20e6 + 3, 1e48 + 3, 1e36, Math.Rounding.Ceil);
        // Both products have a fractional part, so the rounding direction is observable.
        assertLt(collValue, Math.mulDiv(100e18 + 1, 1.5e36 + 7, 1e36, Math.Rounding.Ceil), "coll rounding observable");
        assertGt(debtXValue, Math.mulDiv(20e6 + 3, 1e48 + 3, 1e36, Math.Rounding.Floor), "debt rounding observable");

        uint256 expected = collValue + 40e18 - (25e18 + 1) - debtXValue;
        assertEq(module.nav(provider), expected, "nav = coll (down) + asset coll - asset debt - debt (up)");

        // Idle balances held by the module are excluded.
        coll.mint(address(module), 5e18);
        loan.mint(address(module), 5e18);
        assertEq(module.nav(provider), expected, "idle balances excluded");
    }

    function testNavFlooredAtZero() public {
        _registerAll();
        _pledge(coll, 100e18);
        _borrow(loan, 100e18);
        assertEq(module.nav(provider), 100e18, "200 coll value - 100 debt");

        collOracle.setPrice(0.5e36);
        assertEq(module.nav(provider), 0, "negative equity floored at 0");
    }
}

/// @dev Real Box + FundingAave on the mock pool: the scenarios that bricked the Box before the fix.
contract FundingAaveBoxTest is Test {
    using BoxLib for Box;

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal allocator = address(0x4);
    address internal stranger = address(0xbeef);

    MockAaveV3Pool internal pool;
    ERC20MockDecimals internal asset;
    ERC20MockDecimals internal listed; // Aave reserve and Box token
    ERC20MockDecimals internal pt; // Box token that Aave does not list
    MockSwapper internal swapper;
    Box internal box;
    FundingAave internal module;

    function setUp() public {
        pool = new MockAaveV3Pool();
        asset = new ERC20MockDecimals(18);
        listed = new ERC20MockDecimals(18);
        pt = new ERC20MockDecimals(18);
        pool.listReserve(address(asset), 1e8);
        pool.listReserve(address(listed), 1e8);
        asset.mint(address(pool), 1_000_000e18);

        box = new Box(address(asset), owner, curator, "Box", "BOX", 0.01 ether, 1 days, 1 days, 1 days);
        IOracle one = new MockOracle(1e36);

        swapper = new MockSwapper();
        swapper.setOracle(asset, one);
        swapper.setOracle(listed, one);
        swapper.setOracle(pt, one);
        asset.mint(address(swapper), 1_000_000e18);
        listed.mint(address(swapper), 1_000_000e18);
        pt.mint(address(swapper), 1_000_000e18);

        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addTokenInstant(pt, one);
        box.addTokenInstant(listed, one);
        vm.stopPrank();

        module = new FundingAave(address(box), IPool(address(pool)), 0);

        asset.mint(address(this), 100e18);
        asset.approve(address(box), 100e18);
        box.deposit(100e18, address(this));
    }

    function _attach(bool withPosition) internal {
        vm.startPrank(curator);
        box.addFundingInstant(module);
        if (withPosition) {
            box.addFundingFacilityInstant(module, "");
            box.addFundingCollateralInstant(module, listed);
            box.addFundingDebtInstant(module, asset);
        }
        vm.stopPrank();

        if (withPosition) {
            vm.startPrank(allocator);
            box.allocate(listed, 20e18, swapper, "");
            box.pledge(module, "", listed, 20e18);
            box.borrow(module, "", asset, 10e18);
            vm.stopPrank();
        }
    }

    function _winddownDeallocateUnlistedToken() internal {
        vm.prank(allocator);
        box.allocate(pt, 50e18, swapper, "");

        vm.prank(curator);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown(), "winddown");
        assertEq(module.debtBalance(pt), 0, "unlisted token has no debt");

        uint256 assetBefore = asset.balanceOf(address(box));
        vm.prank(allocator);
        (, uint256 received) = box.deallocate(pt, 10e18, swapper, "");
        assertEq(received, 10e18, "allocator deallocate received");
        assertEq(asset.balanceOf(address(box)), assetBefore + 10e18, "asset back to Box (allocator)");

        vm.prank(stranger);
        (, received) = box.deallocate(pt, 10e18, swapper, "");
        assertEq(received, 10e18, "stranger deallocate received");
        assertEq(asset.balanceOf(address(box)), assetBefore + 20e18, "asset back to Box (stranger)");
        assertEq(pt.balanceOf(address(box)), 30e18, "pt sold");
        assertTrue(box.isFunding(module), "module still attached");
    }

    // ========== BRICK SCENARIO (VAL-AAVE3-004) ==========

    function testUnlistedBoxTokenCannotBeAddedToFundingAave() public {
        vm.startPrank(curator);
        box.addFundingInstant(module);
        box.increaseTimelock(box.addFundingCollateral.selector, 1 days);
        box.increaseTimelock(box.addFundingDebt.selector, 1 days);
        box.submit(abi.encodeCall(box.addFundingCollateral, (module, IERC20(address(pt)))));
        box.submit(abi.encodeCall(box.addFundingDebt, (module, IERC20(address(pt)))));
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        box.addFundingCollateral(module, pt);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        box.addFundingDebt(module, pt);

        assertEq(module.collateralTokensLength(), 0, "no collateral token");
        assertEq(module.debtTokensLength(), 0, "no debt token");
        assertEq(box.totalAssets(), 100e18, "totalAssets does not revert");

        vm.prank(curator);
        box.removeFunding(module);
        assertFalse(box.isFunding(module), "module removed");
    }

    // ========== BOX NAV (VAL-AAVE3-005) ==========

    function testTotalAssetsWithRegisteredListedTokens() public {
        vm.startPrank(curator);
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, "");
        box.addFundingCollateralInstant(module, listed);
        box.addFundingDebtInstant(module, asset);
        vm.stopPrank();
        assertEq(box.totalAssets(), 100e18, "registered tokens, no position");
        assertEq(module.nav(box), 0, "module nav 0 with no position");

        vm.startPrank(allocator);
        box.allocate(listed, 50e18, swapper, "");
        box.pledge(module, "", listed, 50e18);
        box.borrow(module, "", asset, 20e18);
        vm.stopPrank();

        assertEq(module.nav(box), 30e18, "50 collateral - 20 debt");
        assertEq(box.totalAssets(), asset.balanceOf(address(box)) + module.nav(box), "totalAssets = idle + module nav");
        assertEq(box.totalAssets(), 100e18, "borrowing does not move totalAssets");
    }

    // ========== WINDDOWN DEALLOCATE (VAL-AAVE3-006) ==========

    function testWinddownDeallocateWithEmptyFundingAave() public {
        _attach(false);
        _winddownDeallocateUnlistedToken();
    }

    function testWinddownDeallocateWithOpenFundingAavePosition() public {
        _attach(true);
        _winddownDeallocateUnlistedToken();

        // The Aave position can still be closed by anyone.
        vm.prank(stranger);
        box.repay(module, "", asset, type(uint256).max);
        assertEq(module.debtBalance("", asset), 0, "debt closed");
        vm.prank(stranger);
        box.depledge(module, "", listed, type(uint256).max);
        assertEq(module.collateralBalance("", listed), 0, "collateral withdrawn");
        assertEq(listed.balanceOf(address(box)), 20e18, "collateral back to Box");
    }
}
