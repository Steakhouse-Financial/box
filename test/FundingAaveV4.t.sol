// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Box} from "../src/Box.sol";
import {FundingAaveV4} from "../src/FundingAaveV4.sol";
import {FundingAaveV4Factory} from "../src/factories/FundingAaveV4Factory.sol";
import {IAaveV4Spoke} from "../src/interfaces/aave-v4/IAaveV4Spoke.sol";
import {IFunding, IOracleCallback} from "../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MockAaveV4Spoke} from "./mocks/MockAaveV4Spoke.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockOracleProvider} from "./mocks/MockOracleProvider.sol";
import {ReentrantHookToken} from "./mocks/ReentrantHookToken.sol";

/// @dev Shared fixture: a mock Spoke with 5 reserves and a module owned by a mock oracle provider (Box stand-in).
abstract contract FundingAaveV4Fixture is Test {
    bytes internal constant EMPTY = "";

    uint256 internal constant COLL_A = 0; // 18 dec, CF 80%, not borrowable
    uint256 internal constant DEBT_B = 1; // 18 dec, CF 0, borrowable
    uint256 internal constant TOK_C = 2; // 6 dec, CF 75%, borrowable
    uint256 internal constant OUTSIDE_D = 3; // 18 dec, CF 80%, borrowable, never in the module list
    uint256 internal constant DUP_A = 4; // same underlying as COLL_A

    MockAaveV4Spoke internal spoke;
    ERC20MockDecimals internal collA;
    ERC20MockDecimals internal debtB;
    ERC20MockDecimals internal tokC;
    ERC20MockDecimals internal outsideD;
    ERC20MockDecimals internal stranger;

    MockOracleProvider internal provider; // module owner; asset = debtB
    MockOracle internal collAOracle;
    MockOracle internal tokCOracle;
    address internal owner;

    FundingAaveV4 internal module;

    function setUp() public virtual {
        spoke = new MockAaveV4Spoke();
        collA = new ERC20MockDecimals(18);
        debtB = new ERC20MockDecimals(18);
        tokC = new ERC20MockDecimals(6);
        outsideD = new ERC20MockDecimals(18);
        stranger = new ERC20MockDecimals(18);

        assertEq(spoke.addReserve(address(collA), 18, 8000, false), COLL_A);
        assertEq(spoke.addReserve(address(debtB), 18, 0, true), DEBT_B);
        assertEq(spoke.addReserve(address(tokC), 6, 7500, true), TOK_C);
        assertEq(spoke.addReserve(address(outsideD), 18, 8000, true), OUTSIDE_D);
        assertEq(spoke.addReserve(address(collA), 18, 8000, true), DUP_A);

        // Spoke liquidity
        debtB.mint(address(spoke), 1_000_000e18);
        tokC.mint(address(spoke), 1_000_000e6);

        provider = new MockOracleProvider(address(debtB));
        collAOracle = new MockOracle(1e36);
        tokCOracle = new MockOracle(1e48);
        provider.setOracle(collA, collAOracle);
        provider.setOracle(tokC, tokCOracle);
        owner = address(provider);

        module = _deploy(0.8e18);
    }

    function _ids() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        ids[0] = COLL_A;
        ids[1] = DEBT_B;
        ids[2] = TOK_C;
    }

    function _deploy(uint256 lltvCap) internal returns (FundingAaveV4) {
        return new FundingAaveV4(owner, address(spoke), _ids(), lltvCap);
    }

    function _register(FundingAaveV4 m) internal {
        vm.startPrank(owner);
        m.addFacility(EMPTY);
        m.addCollateralToken(collA);
        m.addDebtToken(debtB);
        vm.stopPrank();
    }

    function _pledge(FundingAaveV4 m, ERC20MockDecimals token, uint256 amount) internal {
        token.mint(address(m), amount);
        vm.prank(owner);
        m.pledge(EMPTY, token, amount);
    }

    function _borrow(FundingAaveV4 m, ERC20MockDecimals token, uint256 amount) internal {
        vm.prank(owner);
        m.borrow(EMPTY, token, amount);
    }

    /// @dev Mimics Box: transfers `amount` to the module, then calls repay.
    function _repay(FundingAaveV4 m, ERC20MockDecimals token, uint256 amount) internal {
        token.mint(address(m), amount);
        vm.prank(owner);
        m.repay(EMPTY, token, amount);
    }

    function _hf(FundingAaveV4 m) internal view returns (uint256) {
        return spoke.getUserAccountData(address(m)).healthFactor;
    }
}

contract FundingAaveV4Test is FundingAaveV4Fixture {
    /////////////////////////////
    /// CONSTRUCTOR
    /////////////////////////////

    function testConstructorStoresConfig() public view {
        assertEq(module.owner(), owner);
        assertEq(address(module.spoke()), address(spoke));
        assertEq(module.lltvCap(), 0.8e18);
        assertEq(module.minHealthFactor(), 1.25e18);

        uint256[] memory ids = module.reserveIdsArray();
        assertEq(ids.length, 3);
        assertEq(ids[0], COLL_A);
        assertEq(ids[1], DEBT_B);
        assertEq(ids[2], TOK_C);

        (bool listed, uint256 id) = module.reserveIdOf(collA);
        assertTrue(listed);
        assertEq(id, COLL_A);
        (listed, id) = module.reserveIdOf(debtB);
        assertTrue(listed);
        assertEq(id, DEBT_B);
        (listed, id) = module.reserveIdOf(tokC);
        assertTrue(listed);
        assertEq(id, TOK_C);
        (listed, id) = module.reserveIdOf(outsideD);
        assertFalse(listed);
        assertEq(id, 0);

        assertEq(module.facilitiesLength(), 0);
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
    }

    function testConstructorAcceptsFullLltvCap() public {
        FundingAaveV4 m = _deploy(1e18);
        assertEq(m.lltvCap(), 1e18);
        assertEq(m.minHealthFactor(), 1e18);
    }

    function testConstructorMinHealthFactorRoundsUp() public {
        FundingAaveV4 m = _deploy(0.95e18);
        // 1e36 / 0.95e18 = 1052631578947368421.05...
        assertEq(m.minHealthFactor(), 1052631578947368422);
    }

    function testConstructorBindsTokensToTheirReserve() public {
        // Tokens are routed to the reserve id of the constructor list (not the first reserve of the underlying)
        uint256[] memory ids = new uint256[](2);
        ids[0] = DUP_A; // collA through its second reserve
        ids[1] = DEBT_B;
        FundingAaveV4 m = new FundingAaveV4(owner, address(spoke), ids, 0.8e18);
        (bool listed, uint256 id) = m.reserveIdOf(collA);
        assertTrue(listed);
        assertEq(id, DUP_A);

        _register(m);
        _pledge(m, collA, 10e18);
        assertEq(spoke.getUserSuppliedAssets(DUP_A, address(m)), 10e18, "supplied on the configured reserve");
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(m)), 0, "nothing on the other reserve");
    }

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingAaveV4(address(0), address(spoke), _ids(), 0.8e18);
    }

    function testConstructorRejectsZeroSpoke() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingAaveV4(owner, address(0), _ids(), 0.8e18);
    }

    function testConstructorRejectsZeroLltvCap() public {
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), _ids(), 0);
    }

    function testConstructorRejectsLltvCapAboveOne() public {
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), _ids(), 1e18 + 1);
    }

    function testConstructorRejectsUnknownReserveId() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = COLL_A;
        ids[1] = spoke.getReserveCount(); // not listed
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), ids, 0.8e18);
    }

    function testConstructorRejectsRepeatedReserveId() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = COLL_A;
        ids[1] = DEBT_B;
        ids[2] = DEBT_B;
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), ids, 0.8e18);
    }

    function testConstructorRejectsDuplicateUnderlying() public {
        // COLL_A and DUP_A are two reserves of the same underlying (like USDC reserves 4 and 7 on the Bluechip Spoke)
        assertEq(spoke.getReserve(COLL_A).underlying, spoke.getReserve(DUP_A).underlying);
        uint256[] memory ids = new uint256[](3);
        ids[0] = COLL_A;
        ids[1] = DEBT_B;
        ids[2] = DUP_A;
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), ids, 0.8e18);
    }

    function testConstructorRejectsEmptyReserveList() public {
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingAaveV4(owner, address(spoke), new uint256[](0), 0.8e18);
    }

    /////////////////////////////
    /// ACCESS CONTROL
    /////////////////////////////

    function _ownerGatedCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(FundingAaveV4.addFacility, (EMPTY));
        calls[1] = abi.encodeCall(FundingAaveV4.removeFacility, (EMPTY));
        calls[2] = abi.encodeCall(FundingAaveV4.addCollateralToken, (IERC20(address(collA))));
        calls[3] = abi.encodeCall(FundingAaveV4.addDebtToken, (IERC20(address(debtB))));
        calls[4] = abi.encodeCall(FundingAaveV4.removeCollateralToken, (IERC20(address(collA))));
        calls[5] = abi.encodeCall(FundingAaveV4.removeDebtToken, (IERC20(address(debtB))));
        calls[6] = abi.encodeCall(FundingAaveV4.pledge, (EMPTY, IERC20(address(collA)), 1e18));
        calls[7] = abi.encodeCall(FundingAaveV4.depledge, (EMPTY, IERC20(address(collA)), 1e18));
        calls[8] = abi.encodeCall(FundingAaveV4.borrow, (EMPTY, IERC20(address(debtB)), 1e18));
        calls[9] = abi.encodeCall(FundingAaveV4.repay, (EMPTY, IERC20(address(debtB)), 1e18));
        calls[10] = abi.encodeCall(module.skim, (IERC20(address(collA))));
    }

    function _assertAllOwnerGatedRevert(address caller) internal {
        vm.assume(caller != owner);
        bytes[] memory calls = _ownerGatedCalls();
        bytes memory expected = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(module).call(calls[i]);
            assertFalse(ok, "direct call must revert");
            assertEq(ret, expected, "direct call must revert OnlyOwner");

            bytes[] memory inner = new bytes[](1);
            inner[0] = calls[i];
            vm.prank(caller);
            (ok, ret) = address(module).call(abi.encodeCall(module.multicall, (inner)));
            assertFalse(ok, "multicall must revert");
            assertEq(ret, expected, "multicall must revert OnlyOwner");
        }
    }

    function testOnlyOwnerCanCallGatedFunctions() public {
        // Open a position so that every call would otherwise have something to act on
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 10e18);
        collA.mint(address(module), 1e18);

        _assertAllOwnerGatedRevert(address(0xBAD));
        _assertAllOwnerGatedRevert(address(spoke));
        _assertAllOwnerGatedRevert(address(0xA110C)); // a Box allocator
        _assertAllOwnerGatedRevert(address(this));
    }

    function testFuzzOnlyOwnerCanCallGatedFunctions(address caller) public {
        _assertAllOwnerGatedRevert(caller);
    }

    /////////////////////////////
    /// FACILITY
    /////////////////////////////

    function testAddFacilityOnlyEmpty() public {
        vm.startPrank(owner);
        module.addFacility(EMPTY);
        assertEq(module.facilitiesLength(), 1);
        assertTrue(module.isFacility(EMPTY));
        assertEq(module.facilities(0), EMPTY);
        vm.expectRevert();
        module.facilities(1);

        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(EMPTY);

        bytes[] memory bad = new bytes[](4);
        bad[0] = hex"00";
        bad[1] = abi.encode(uint256(0));
        bad[2] = abi.encode(address(spoke));
        bad[3] = abi.encode(COLL_A, DEBT_B);
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(ErrorsLib.InvalidValue.selector);
            module.addFacility(bad[i]);
            assertEq(module.facilitiesLength(), 1);
            assertFalse(module.isFacility(bad[i]));
        }

        module.removeFacility(EMPTY);
        assertEq(module.facilitiesLength(), 0);
        assertFalse(module.isFacility(EMPTY));
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeFacility(EMPTY);
        vm.stopPrank();
    }

    /////////////////////////////
    /// ACTION VALIDATION
    /////////////////////////////

    function testActionsRejectUnregisteredFacility() public {
        // Tokens registered but no facility yet
        vm.startPrank(owner);
        module.addCollateralToken(collA);
        module.addDebtToken(debtB);
        vm.stopPrank();
        collA.mint(address(module), 10e18);
        debtB.mint(address(module), 10e18);

        bytes[] memory fds = new bytes[](3);
        fds[0] = EMPTY;
        fds[1] = hex"00";
        fds[2] = abi.encode(uint256(1));

        uint256 actionsBefore = spoke.actionCount();
        // Before addFacility: every encoding, "" included, is rejected
        for (uint256 i; i < fds.length; i++) {
            _assertActionsNotWhitelisted(fds[i]);
        }
        // After addFacility(""): non-empty encodings are still rejected
        vm.prank(owner);
        module.addFacility(EMPTY);
        for (uint256 i = 1; i < fds.length; i++) {
            _assertActionsNotWhitelisted(fds[i]);
        }
        assertEq(spoke.actionCount(), actionsBefore, "no Spoke action");
        assertEq(spoke.getUserSuppliedShares(COLL_A, address(module)), 0);
        assertEq(spoke.getUserTotalDebt(DEBT_B, address(module)), 0);
    }

    function _assertActionsNotWhitelisted(bytes memory fd) internal {
        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.pledge(fd, collA, 1e18);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.depledge(fd, collA, 1e18);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.borrow(fd, debtB, 1e18);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.repay(fd, debtB, 1e18);
        vm.stopPrank();
    }

    function testActionsRejectTokensNotRegisteredInTheirRole() public {
        _register(module);
        vm.prank(owner);
        module.addDebtToken(tokC); // configured reserve registered only as debt
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 10e18);
        uint256 actionsBefore = spoke.actionCount();

        IERC20[4] memory notCollateral = [
            IERC20(address(debtB)),
            IERC20(address(tokC)),
            IERC20(address(outsideD)),
            IERC20(address(stranger))
        ];
        IERC20[4] memory notDebt = [IERC20(address(collA)), IERC20(address(outsideD)), IERC20(address(stranger)), IERC20(address(0))];

        vm.startPrank(owner);
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.pledge(EMPTY, notCollateral[i], 1e6);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.depledge(EMPTY, notCollateral[i], 1e6);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.borrow(EMPTY, notDebt[i], 1e6);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.repay(EMPTY, notDebt[i], 1e6);
        }
        vm.stopPrank();

        assertEq(spoke.actionCount(), actionsBefore, "no Spoke action");
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), 100e18);
        assertEq(spoke.getUserTotalDebt(DEBT_B, address(module)), 10e18);
        assertEq(spoke.getUserSuppliedShares(DEBT_B, address(module)), 0);
        assertEq(spoke.getUserTotalDebt(TOK_C, address(module)), 0);
    }

    /////////////////////////////
    /// TOKEN REGISTRATION
    /////////////////////////////

    function testAddCollateralTokenValidation() public {
        vm.startPrank(owner);
        // Listed on the Spoke but not in the module reserve list
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addCollateralToken(outsideD);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addCollateralToken(stranger);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addCollateralToken(IERC20(address(0)));
        // Configured reserve with collateral factor 0
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.addCollateralToken(debtB);
        assertEq(module.collateralTokensLength(), 0);

        module.addCollateralToken(collA);
        assertEq(module.collateralTokensLength(), 1);
        assertTrue(module.isCollateralToken(collA));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addCollateralToken(collA);
        vm.stopPrank();

        // The latest dynamic config is the one that counts
        spoke.addDynamicReserveConfig(TOK_C, 0);
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.addCollateralToken(tokC);
        spoke.addDynamicReserveConfig(TOK_C, 7000);
        vm.prank(owner);
        module.addCollateralToken(tokC);
        assertEq(module.collateralTokensLength(), 2);

        vm.prank(address(0xBAD));
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addCollateralToken(collA);
    }

    function testAddDebtTokenValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addDebtToken(outsideD);
        vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
        module.addDebtToken(stranger);
        // Configured but not borrowable
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.addDebtToken(collA);
        assertEq(module.debtTokensLength(), 0);

        module.addDebtToken(debtB);
        assertEq(module.debtTokensLength(), 1);
        assertTrue(module.isDebtToken(debtB));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addDebtToken(debtB);
        vm.stopPrank();

        spoke.setBorrowable(TOK_C, false);
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.addDebtToken(tokC);
        assertEq(module.debtTokensLength(), 1);

        vm.prank(address(0xBAD));
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.addDebtToken(debtB);
    }

    /////////////////////////////
    /// PLEDGE
    /////////////////////////////

    function testPledgeSuppliesAndEnablesCollateral() public {
        _register(module);
        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(COLL_A, address(module));
        assertFalse(usingAsCollateral);

        _pledge(module, collA, 100e18);
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), 100e18);
        (usingAsCollateral, ) = spoke.getUserReserveStatus(COLL_A, address(module));
        assertTrue(usingAsCollateral);
        assertEq(collA.balanceOf(address(module)), 0);
        assertEq(collA.allowance(address(module), address(spoke)), 0);
        assertEq(module.collateralBalance(EMPTY, collA), 100e18);

        // Second pledge with a supply share price above 1: supplied assets rise by the amount, rounded down
        spoke.setSupplyIndex(COLL_A, 1.1e27 + 7);
        uint256 before = spoke.getUserSuppliedAssets(COLL_A, address(module));
        _pledge(module, collA, 33e18 + 1);
        uint256 afterPledge = spoke.getUserSuppliedAssets(COLL_A, address(module));
        assertApproxEqAbs(afterPledge, before + 33e18 + 1, 1, "supplied rises by the amount within 1 wei");
        assertLe(afterPledge, before + 33e18 + 1, "rounded down");
        (usingAsCollateral, ) = spoke.getUserReserveStatus(COLL_A, address(module));
        assertTrue(usingAsCollateral);
        assertEq(collA.balanceOf(address(module)), 0);
        assertEq(collA.allowance(address(module), address(spoke)), 0);
    }

    /////////////////////////////
    /// DEPLEDGE / BORROW DELIVERY
    /////////////////////////////

    function testDepledgeDeliversExactAmountToOwner() public {
        _register(module);
        spoke.setSupplyIndex(COLL_A, 1.1e27 + 7);
        _pledge(module, collA, 100e18);
        uint256 supplied = spoke.getUserSuppliedAssets(COLL_A, address(module));

        uint256 ownerBefore = collA.balanceOf(owner);
        vm.prank(owner);
        module.depledge(EMPTY, collA, 30e18 + 3);
        assertEq(collA.balanceOf(owner), ownerBefore + 30e18 + 3, "owner receives exactly the amount");
        assertApproxEqAbs(spoke.getUserSuppliedAssets(COLL_A, address(module)), supplied - 30e18 - 3, 1, "supplied drops by amount");
        assertEq(collA.balanceOf(address(module)), 0);

        // Full remaining balance, as Box resolves type(uint256).max
        uint256 rest = module.collateralBalance(EMPTY, collA);
        vm.prank(owner);
        module.depledge(EMPTY, collA, rest);
        assertEq(collA.balanceOf(owner), ownerBefore + 30e18 + 3 + rest);
        assertEq(spoke.getUserSuppliedShares(COLL_A, address(module)), 0, "no dust shares");
        assertEq(collA.balanceOf(address(module)), 0);
    }

    function testDepledgeAboveSuppliedReverts() public {
        _register(module);
        _pledge(module, collA, 100e18);
        // Idle tokens in the module must not be used to cover a capped withdrawal
        collA.mint(address(module), 50e18);
        uint256 ownerBefore = collA.balanceOf(owner);

        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.depledge(EMPTY, collA, 100e18 + 1);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.depledge(EMPTY, collA, type(uint256).max);
        vm.stopPrank();

        assertEq(collA.balanceOf(owner), ownerBefore);
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), 100e18);
        assertEq(collA.balanceOf(address(module)), 50e18);
    }

    function testBorrowDeliversExactAmountToOwner() public {
        _register(module);
        _pledge(module, collA, 100e18);
        spoke.setDrawnIndex(DEBT_B, 1.3e27 + 1);

        uint256 z = 10e18 + 3;
        uint256 ownerBefore = debtB.balanceOf(owner);
        _borrow(module, debtB, z);
        assertEq(debtB.balanceOf(owner), ownerBefore + z, "owner receives exactly the amount");
        uint256 debt = module.debtBalance(EMPTY, debtB);
        assertTrue(debt == z || debt == z + 1, "debt is the amount rounded up");
        assertEq(debtB.balanceOf(address(module)), 0);
    }

    function testBorrowMaxReverts() public {
        _register(module);
        _pledge(module, collA, 100e18);
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        module.borrow(EMPTY, debtB, type(uint256).max);
        assertEq(spoke.getUserTotalDebt(DEBT_B, address(module)), 0);
    }

    /////////////////////////////
    /// REPAY
    /////////////////////////////

    function testPartialRepayWithPremium() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        spoke.setPremiumDebt(DEBT_B, address(module), 3e18 + 7);
        uint256 d = module.debtBalance(EMPTY, debtB);
        assertEq(d, 43e18 + 7);

        uint256 ownerBefore = debtB.balanceOf(owner);
        _repay(module, debtB, 10e18);
        assertApproxEqAbs(module.debtBalance(EMPTY, debtB), d - 10e18, 1, "debt drops by the amount");
        (, uint256 premium) = spoke.getUserDebt(DEBT_B, address(module));
        assertEq(premium, 0, "premium paid first");
        assertEq(debtB.balanceOf(address(module)), 0);
        assertEq(debtB.balanceOf(owner), ownerBefore, "nothing refunded");
    }

    function testOverRepayRefundsSurplus() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        spoke.setPremiumDebt(DEBT_B, address(module), 1e18 + 1);
        uint256 d = module.debtBalance(EMPTY, debtB);

        uint256 ownerBefore = debtB.balanceOf(owner);
        _repay(module, debtB, d + 5e18);
        assertEq(module.debtBalance(EMPTY, debtB), 0);
        assertEq(debtB.balanceOf(owner), ownerBefore + 5e18, "surplus refunded");
        assertEq(debtB.balanceOf(address(module)), 0);
    }

    function testRepayWithoutDebtRefundsEverything() public {
        _register(module);
        uint256 ownerBefore = debtB.balanceOf(owner);
        _repay(module, debtB, 7e18);
        assertEq(debtB.balanceOf(owner), ownerBefore + 7e18);
        assertEq(debtB.balanceOf(address(module)), 0);
    }

    function testRepayExactDebtBalanceClosesPremium() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        spoke.setDrawnIndex(DEBT_B, 1.05e27 + 123);
        spoke.setPremiumDebt(DEBT_B, address(module), 2e18 + 1);

        uint256 d = module.debtBalance(EMPTY, debtB);
        assertGt(d, 42e18);
        uint256 ownerBefore = debtB.balanceOf(owner);
        _repay(module, debtB, d);

        (uint256 drawn, uint256 premium) = spoke.getUserDebt(DEBT_B, address(module));
        assertEq(drawn, 0);
        assertEq(premium, 0);
        IAaveV4Spoke.UserPosition memory p = spoke.getUserPosition(DEBT_B, address(module));
        assertEq(p.drawnShares, 0);
        assertEq(p.premiumShares, 0);
        (, bool borrowing) = spoke.getUserReserveStatus(DEBT_B, address(module));
        assertFalse(borrowing);
        assertEq(module.debtBalance(EMPTY, debtB), 0);
        assertEq(debtB.balanceOf(address(module)), 0);
        assertEq(debtB.balanceOf(owner), ownerBefore, "exact amount consumed");
    }

    /////////////////////////////
    /// BALANCE VIEWS
    /////////////////////////////

    function testViewsReturnZeroForUnknownTokens() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        spoke.setPremiumDebt(DEBT_B, address(module), 1e18);
        // Debt on reserves whose token is not registered as debt (configured or not) is not reported
        spoke.setPremiumDebt(TOK_C, address(module), 1e6);
        spoke.setPremiumDebt(OUTSIDE_D, address(module), 1e18);
        assertGt(module.debtBalance(debtB), 0);

        address[6] memory unknownCollateral = [
            address(debtB), // registered only as debt
            address(tokC), // configured, not registered
            address(outsideD),
            address(stranger),
            address(0),
            address(0xdead)
        ];
        address[6] memory unknownDebt = [address(collA), address(tokC), address(outsideD), address(stranger), address(0), address(0xdead)];
        for (uint256 i; i < 6; i++) {
            assertEq(module.collateralBalance(IERC20(unknownCollateral[i])), 0);
            assertEq(module.collateralBalance(EMPTY, IERC20(unknownCollateral[i])), 0);
            assertEq(module.debtBalance(IERC20(unknownDebt[i])), 0);
            assertEq(module.debtBalance(EMPTY, IERC20(unknownDebt[i])), 0);
        }
    }

    function testViewsReturnZeroForNonEmptyFacilityData() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        assertGt(module.ltv(EMPTY), 0);

        bytes[] memory fds = new bytes[](3);
        fds[0] = hex"00";
        fds[1] = abi.encode(uint256(1));
        fds[2] = abi.encode(uint256(0));
        for (uint256 i; i < fds.length; i++) {
            assertEq(module.collateralBalance(fds[i], collA), 0);
            assertEq(module.debtBalance(fds[i], debtB), 0);
            assertEq(module.ltv(fds[i]), 0);
        }
    }

    function testBalanceViewsTrackSpoke() public {
        _register(module);
        vm.prank(owner);
        module.addCollateralToken(tokC);
        spoke.setSupplyIndex(COLL_A, 1.123456789e27);
        _pledge(module, collA, 100e18 + 1);
        _pledge(module, tokC, 50e6 + 1);
        _borrow(module, debtB, 40e18 + 1);

        _assertViewsMatchSpoke();

        // Accrual and premium with no module transaction
        spoke.setDrawnIndex(DEBT_B, 1.0777777e27 + 3);
        spoke.setPremiumDebt(DEBT_B, address(module), 0.5e18 + 9);
        spoke.setSupplyIndex(COLL_A, 1.2e27 + 11);
        _assertViewsMatchSpoke();
        assertGt(module.debtBalance(EMPTY, debtB), 40e18 + 1);
    }

    function _assertViewsMatchSpoke() internal view {
        uint256 suppliedA = spoke.getUserSuppliedAssets(COLL_A, address(module));
        uint256 suppliedC = spoke.getUserSuppliedAssets(TOK_C, address(module));
        uint256 debt = spoke.getUserTotalDebt(DEBT_B, address(module));
        assertEq(module.collateralBalance(EMPTY, collA), suppliedA);
        assertEq(module.collateralBalance(collA), suppliedA);
        assertEq(module.collateralBalance(EMPTY, tokC), suppliedC);
        assertEq(module.collateralBalance(tokC), suppliedC);
        assertEq(module.debtBalance(EMPTY, debtB), debt);
        assertEq(module.debtBalance(debtB), debt);
    }

    /////////////////////////////
    /// NAV
    /////////////////////////////

    uint256 internal constant PRICE_A = 1_234_567_890_123_456_789_012_345_678_901_234_567; // ~1.23e36
    uint256 internal constant PRICE_C = 987_654_321_987_654_321_987_654_321_987_654_321_987; // ~0.99e48 (6 dec)
    uint256 internal constant PRICE_B = 1_111_111_111_111_111_111_111_111_111_111_111_111; // ~1.11e36

    function _navFixture() internal {
        _register(module);
        vm.prank(owner);
        module.addCollateralToken(tokC);
        _pledge(module, collA, 100e18 + 7);
        _pledge(module, tokC, 50e6 + 3);
        _borrow(module, debtB, 40e18 + 1);
        spoke.setPremiumDebt(DEBT_B, address(module), 13);
        collAOracle.setPrice(PRICE_A);
        tokCOracle.setPrice(PRICE_C);
    }

    function testNavUsesBoxOraclesWithDebtAsAsset() public {
        _navFixture();
        uint256 balA = module.collateralBalance(collA);
        uint256 balC = module.collateralBalance(tokC);
        uint256 debt = module.debtBalance(debtB);
        assertGt(mulmod(balA, PRICE_A, 1e36), 0, "inexact");
        assertGt(mulmod(balC, PRICE_C, 1e36), 0, "inexact");

        // debtB is the provider asset: valued 1:1, oracles(debtB) would revert
        uint256 expected = Math.mulDiv(balA, PRICE_A, 1e36) + Math.mulDiv(balC, PRICE_C, 1e36) - debt;
        assertEq(module.nav(provider), expected);
    }

    function testNavUsesBoxOraclesWithCollateralAsAsset() public {
        _navFixture();
        MockOracleProvider providerC = new MockOracleProvider(address(tokC));
        providerC.setOracle(collA, collAOracle);
        providerC.setOracle(debtB, new MockOracle(PRICE_B));

        uint256 balA = module.collateralBalance(collA);
        uint256 balC = module.collateralBalance(tokC);
        uint256 debt = module.debtBalance(debtB);
        assertGt(mulmod(debt, PRICE_B, 1e36), 0, "inexact");

        uint256 expected = Math.mulDiv(balA, PRICE_A, 1e36) + balC - Math.mulDiv(debt, PRICE_B, 1e36, Math.Rounding.Ceil);
        assertEq(module.nav(IOracleCallback(address(providerC))), expected);
        // Rounding the debt down would give a higher nav
        assertEq(Math.mulDiv(debt, PRICE_B, 1e36, Math.Rounding.Ceil), Math.mulDiv(debt, PRICE_B, 1e36) + 1);
    }

    function testNavExcludesIdleBalances() public {
        _navFixture();
        uint256 navBefore = module.nav(provider);
        collA.mint(address(module), 11e18);
        tokC.mint(address(module), 3e6);
        debtB.mint(address(module), 5e18);
        outsideD.mint(address(module), 1e18);
        assertEq(module.nav(provider), navBefore);
    }

    function testNavFlooredAtZero() public {
        _navFixture();
        collAOracle.setPrice(1);
        tokCOracle.setPrice(1);
        assertEq(module.nav(provider), 0);

        collAOracle.setPrice(0);
        tokCOracle.setPrice(0);
        assertEq(module.nav(provider), 0);
    }

    function testNavZeroWithoutPositions() public {
        _register(module);
        assertEq(module.nav(provider), 0);
    }

    function testNavAndViewsIndependentOfAccountData() public {
        _navFixture();
        uint256 navBefore = module.nav(provider);
        uint256 balA = module.collateralBalance(collA);
        uint256 debt = module.debtBalance(debtB);

        spoke.setAccountDataReverts(true);
        vm.expectRevert(MockAaveV4Spoke.AccountDataUnavailable.selector);
        module.ltv(EMPTY);

        assertEq(module.nav(provider), navBefore);
        assertEq(module.collateralBalance(collA), balA);
        assertEq(module.collateralBalance(EMPTY, collA), balA);
        assertEq(module.debtBalance(debtB), debt);
        assertEq(module.debtBalance(EMPTY, debtB), debt);

        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(EMPTY);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(collA);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(debtB);
        vm.stopPrank();
    }

    function testNavWorksWhenReservePausedOrHalted() public {
        _navFixture();
        uint256 navBefore = module.nav(provider);
        spoke.setPaused(COLL_A, true);
        spoke.setHalted(DEBT_B, true);
        spoke.setFrozen(TOK_C, true);
        assertEq(module.nav(provider), navBefore);
    }

    /////////////////////////////
    /// SKIM
    /////////////////////////////

    function testSkimIdleTokensKeepsNav() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        uint256 navBefore = module.nav(provider);
        uint256 supplied = spoke.getUserSuppliedAssets(COLL_A, address(module));
        uint256 debt = spoke.getUserTotalDebt(DEBT_B, address(module));

        collA.mint(address(module), 5e18);
        uint256 ownerBefore = collA.balanceOf(owner);
        vm.prank(owner);
        module.skim(collA);
        assertEq(collA.balanceOf(owner), ownerBefore + 5e18);
        assertEq(collA.balanceOf(address(module)), 0);

        stranger.mint(address(module), 7e18);
        vm.prank(owner);
        module.skim(stranger);
        assertEq(stranger.balanceOf(owner), 7e18);

        assertEq(module.nav(provider), navBefore);
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), supplied);
        assertEq(spoke.getUserTotalDebt(DEBT_B, address(module)), debt);
    }

    /////////////////////////////
    /// LTV
    /////////////////////////////

    function testLtvZeroWithoutDebt() public {
        _register(module);
        assertEq(module.ltv(EMPTY), 0);
        _pledge(module, collA, 100e18);
        assertGt(spoke.getUserAccountData(address(module)).totalCollateralValue, 0);
        assertEq(module.ltv(EMPTY), 0);
    }

    function testLtvRoundsUp() public {
        // debt 2e28 value (+1 wei ray), collateral 3e28 value: 0.6666...e18
        spoke.setAccountDataOverride(0.8e18, 3e28, 2e28 * 1e27 + 1);
        assertEq(module.ltv(EMPTY), 666666666666666667);

        spoke.setAccountDataOverride(0.8e18, 3, 2e27);
        assertEq(module.ltv(EMPTY), 666666666666666667);
    }

    function testLtvMaxWhenDebtWithoutCollateralValue() public {
        spoke.setAccountDataOverride(0, 0, 1);
        assertEq(module.ltv(EMPTY), type(uint256).max);

        // Also from real positions: collateral factor cut to 0 on the bound key
        spoke.clearAccountDataOverride();
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        spoke.setCollateralFactor(COLL_A, 0, 0);
        assertEq(spoke.getUserAccountData(address(module)).totalCollateralValue, 0);
        assertEq(module.ltv(EMPTY), type(uint256).max);
    }

    function testLtvUsesSpokePricingNotBoxOracles() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);
        uint256 ltvBefore = module.ltv(EMPTY);
        assertEq(ltvBefore, 0.4e18);

        collAOracle.setPrice(0.5e36);
        assertEq(module.ltv(EMPTY), ltvBefore, "Box oracle does not move ltv");

        spoke.setPrice(COLL_A, 0.5e8);
        assertEq(module.ltv(EMPTY), 0.8e18, "Spoke price moves ltv");
    }

    /////////////////////////////
    /// GUARD AFTER BORROW
    /////////////////////////////

    // With 100e18 collA pledged (CF 80%, price 1) and B wei of debtB (price 1): HF = 8e37 / B.

    function testBorrowGuardExactCap() public {
        // lltvCap 0.8 => min HF 1.25e18 => max debt 64e18
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 64e18);
        assertEq(_hf(module), 1.25e18, "exactly at the cap");
        assertEq(module.ltv(EMPTY), 0.64e18);
    }

    function testBorrowGuardOneWeiAboveCapReverts() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 64e18 - 1);
        assertGe(_hf(module), 1.25e18, "inside the cap");

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.borrow(EMPTY, debtB, 2);
        assertEq(module.debtBalance(EMPTY, debtB), 64e18 - 1, "no extra debt");

        FundingAaveV4 m2 = _deploy(0.8e18);
        _register(m2);
        _pledge(m2, collA, 100e18);
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        m2.borrow(EMPTY, debtB, 64e18 + 1);
        assertEq(m2.debtBalance(EMPTY, debtB), 0, "no debt left");
        assertEq(debtB.balanceOf(owner), 64e18 - 1, "only the first borrow was delivered");
    }

    function testBorrowGuardRoundsAgainstThePosition() public {
        // lltvCap 0.95: 1e36 / 0.95e18 = 1052631578947368421.05 => min HF 1052631578947368422
        FundingAaveV4 m = _deploy(0.95e18);
        uint256 minHf = m.minHealthFactor();
        assertEq(minHf, 1052631578947368422);
        _register(m);
        _pledge(m, collA, 100e18);

        // Largest debt keeping HF >= minHf
        uint256 bMax = 8e37 / minHf;
        // One wei more gives HF = floor(1e36 / c): inside the cap with rounded-down math, outside with exact math
        assertEq(uint256(8e37) / (bMax + 1), minHf - 1, "HF of bMax + 1 is floor(1e36 / c)");
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        m.borrow(EMPTY, debtB, bMax + 1);
        assertEq(m.debtBalance(EMPTY, debtB), 0, "no debt left");

        _borrow(m, debtB, bMax);
        assertEq(_hf(m), minHf, "accepted HF is exactly the minimum");
        assertEq(m.debtBalance(EMPTY, debtB), bMax);
    }

    function testBorrowGuardWithAccountDataOverride() public {
        // Account data consistent with HF = avgCF * collateral * 1e27 / debtRay; debt 9e44 ray, avgCF 0.9e18
        FundingAaveV4 m = _deploy(0.95e18);
        uint256 minHf = m.minHealthFactor();
        _register(m);
        _pledge(m, collA, 100e18);

        spoke.setAccountDataOverride(0.9e18, minHf - 1, 9e44);
        assertEq(_hf(m), minHf - 1);
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        m.borrow(EMPTY, debtB, 1e18);

        spoke.setAccountDataOverride(0.9e18, minHf, 9e44);
        assertEq(_hf(m), minHf);
        _borrow(m, debtB, 1e18);

        spoke.setAccountDataOverride(0.9e18, minHf + 1, 9e44);
        assertEq(_hf(m), minHf + 1);
        _borrow(m, debtB, 1e18);
        assertEq(m.debtBalance(EMPTY, debtB), 2e18);
    }

    function testBorrowFullLltvCapAllowsHealthFactorOne() public {
        FundingAaveV4 m = _deploy(1e18);
        _register(m);
        _pledge(m, collA, 100e18);
        _borrow(m, debtB, 80e18);
        assertEq(_hf(m), 1e18, "HF exactly 1.0");

        // The Spoke's own limit applies beyond that
        vm.prank(owner);
        vm.expectRevert(MockAaveV4Spoke.HealthFactorBelowThreshold.selector);
        m.borrow(EMPTY, debtB, 1);
    }

    /////////////////////////////
    /// GUARD AFTER DEPLEDGE
    /////////////////////////////

    // 100e18 collA, 60e18 debt, cap 0.8: HF = (100e18 - X) / 75 => X <= 6.25e18

    function testDepledgeGuard() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 60e18);

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.depledge(EMPTY, collA, 6.25e18 + 1);
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), 100e18, "supplied unchanged");

        vm.prank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.depledge(EMPTY, collA, 10e18);
        assertEq(spoke.getUserSuppliedAssets(COLL_A, address(module)), 100e18, "supplied unchanged");

        uint256 ownerBefore = collA.balanceOf(owner);
        vm.prank(owner);
        module.depledge(EMPTY, collA, 6.25e18);
        assertEq(_hf(module), 1.25e18, "exactly at the cap");
        assertEq(collA.balanceOf(owner), ownerBefore + 6.25e18);
    }

    function testDepledgeFullSupplyWithoutDebt() public {
        _register(module);
        _pledge(module, collA, 100e18);
        vm.prank(owner);
        module.depledge(EMPTY, collA, 100e18);
        assertEq(collA.balanceOf(owner), 100e18);
        assertEq(spoke.getUserSuppliedShares(COLL_A, address(module)), 0);
    }

    /////////////////////////////
    /// GUARD NEVER BLOCKS PLEDGE / REPAY
    /////////////////////////////

    function testPledgeAndRepayNotBlockedOutsideCapAfterPriceDrop() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 60e18);
        spoke.setPrice(COLL_A, 0.9e8);
        uint256 hf = _hf(module);
        assertEq(hf, 1.2e18);
        assertTrue(hf >= 1e18 && hf < module.minHealthFactor(), "outside the cap, not liquidatable");

        _pledge(module, collA, 1e18);
        assertEq(module.collateralBalance(EMPTY, collA), 101e18);
        _repay(module, debtB, 1e18);
        assertEq(module.debtBalance(EMPTY, debtB), 59e18);
        assertLt(_hf(module), module.minHealthFactor(), "still outside the cap");

        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.borrow(EMPTY, debtB, 1);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.depledge(EMPTY, collA, 1);
        vm.stopPrank();
    }

    function testPledgeAndRepayNotBlockedAfterCollateralFactorCut() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 60e18);
        uint256 hfBefore = _hf(module);
        spoke.addDynamicReserveConfig(COLL_A, 7000);
        assertEq(_hf(module), hfBefore, "stale key keeps the view HF");

        _pledge(module, collA, 1e18);
        _repay(module, debtB, 1e18);
        assertEq(module.debtBalance(EMPTY, debtB), 59e18);

        // Risk-increasing actions rebind to CF 70%: HF = 0.7 * 101 / 59 ~ 1.198 < 1.25
        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.borrow(EMPTY, debtB, 1);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        module.depledge(EMPTY, collA, 1);
        vm.stopPrank();
    }

    /////////////////////////////
    /// REMOVAL
    /////////////////////////////

    function _assertFacilityBlocked(FundingAaveV4 m) internal {
        vm.prank(owner);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        m.removeFacility(EMPTY);
    }

    function testRemoveFacilityBlockedByOneWeiSupply() public {
        _register(module);
        _pledge(module, collA, 1);
        _assertFacilityBlocked(module);
        vm.prank(owner);
        module.depledge(EMPTY, collA, 1);
        vm.prank(owner);
        module.removeFacility(EMPTY);
        assertEq(module.facilitiesLength(), 0);
    }

    function testRemoveFacilityBlockedByOneWeiDebt() public {
        _register(module);
        spoke.setPremiumDebt(DEBT_B, address(module), 1);
        assertEq(spoke.getUserSuppliedShares(COLL_A, address(module)), 0);
        _assertFacilityBlocked(module);
        _repay(module, debtB, 1);
        vm.prank(owner);
        module.removeFacility(EMPTY);
    }

    function testRemoveFacilityBlockedByDebtOnUnregisteredConfiguredReserve() public {
        // Debt on a configured reserve whose token is not registered in the module
        _register(module);
        spoke.setPremiumDebt(TOK_C, address(module), 1);
        assertEq(module.debtBalance(tokC), 0);
        _assertFacilityBlocked(module);
    }

    function testRemoveFacilityBlockedBySupplyWithZeroCollateralFactor() public {
        _register(module);
        _pledge(module, collA, 10e18);
        spoke.setCollateralFactor(COLL_A, 0, 0);
        assertEq(spoke.getUserAccountData(address(module)).totalCollateralValue, 0, "account data sees no collateral");
        _assertFacilityBlocked(module);
    }

    function testRemoveFacilityBlockedBySupplyNotEnabledAsCollateral() public {
        _register(module);
        _pledge(module, collA, 10e18);
        spoke.forceUsingAsCollateral(COLL_A, address(module), false);
        assertEq(spoke.getUserAccountData(address(module)).totalCollateralValue, 0, "account data sees no collateral");
        _assertFacilityBlocked(module);
    }

    function testRemoveTokensRequireZeroBalance() public {
        _register(module);
        _pledge(module, collA, 10e18);
        _borrow(module, debtB, 1e18);

        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(collA);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(debtB);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeCollateralToken(tokC);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeDebtToken(stranger);
        vm.stopPrank();

        _repay(module, debtB, module.debtBalance(EMPTY, debtB));
        vm.startPrank(owner);
        module.removeDebtToken(debtB);
        assertFalse(module.isDebtToken(debtB));
        module.depledge(EMPTY, collA, module.collateralBalance(EMPTY, collA));
        module.removeCollateralToken(collA);
        assertFalse(module.isCollateralToken(collA));
        module.removeFacility(EMPTY);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeCollateralToken(collA);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeDebtToken(debtB);
        vm.stopPrank();
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
    }

    /////////////////////////////
    /// PROTOCOL FLAGS
    /////////////////////////////

    function testPausedReserveBlocksWhatTheSpokeBlocks() public {
        _register(module);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 10e18);

        spoke.setPaused(DEBT_B, true);
        debtB.mint(address(module), 1e18);
        vm.startPrank(owner);
        vm.expectRevert(MockAaveV4Spoke.ReservePaused.selector);
        module.repay(EMPTY, debtB, 1e18);
        vm.expectRevert(MockAaveV4Spoke.ReservePaused.selector);
        module.borrow(EMPTY, debtB, 1e18);
        vm.stopPrank();

        spoke.setPaused(DEBT_B, false);
        spoke.setFrozen(DEBT_B, true);
        vm.prank(owner);
        module.repay(EMPTY, debtB, 1e18);
        assertEq(module.debtBalance(EMPTY, debtB), 9e18, "repay works when frozen");
    }

    /// @dev Governance can zero the latest collateral factor or clear `borrowable` after the token was registered. The
    ///      registration stays valid: pledge, repay, depledge and removal still work and nav keeps valuing the collateral.
    function testReserveConfigChangesAfterRegistration() public {
        _register(module);
        vm.prank(owner);
        module.addCollateralToken(tokC);
        _pledge(module, collA, 100e18);
        _borrow(module, debtB, 40e18);

        spoke.addDynamicReserveConfig(TOK_C, 0);
        spoke.setBorrowable(DEBT_B, false);

        // Refused for new registrations, kept for existing ones
        FundingAaveV4 fresh = _deploy(0.8e18);
        vm.startPrank(owner);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        fresh.addCollateralToken(tokC);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        fresh.addDebtToken(debtB);
        vm.stopPrank();
        assertTrue(module.isCollateralToken(tokC));
        assertTrue(module.isDebtToken(debtB));

        // The first pledge enables tokC on its zero collateral factor key: ignored by the Spoke, valued by the Box oracle
        uint256 navBefore = module.nav(provider);
        uint256 ltvBefore = module.ltv(EMPTY);
        uint256 hfBefore = _hf(module);
        _pledge(module, tokC, 50e6);
        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(TOK_C, address(module));
        assertTrue(usingAsCollateral, "enabled");
        assertEq(module.collateralBalance(EMPTY, tokC), 50e6);
        assertEq(module.nav(provider), navBefore + 50e18, "valued by the Box oracle (1e48 for 6 decimals)");
        assertEq(module.ltv(EMPTY), ltvBefore, "no collateral value at the Spoke");
        assertEq(_hf(module), hfBefore);

        vm.prank(owner);
        vm.expectRevert(MockAaveV4Spoke.ReserveNotBorrowable.selector);
        module.borrow(EMPTY, debtB, 1e18);

        _repay(module, debtB, module.debtBalance(EMPTY, debtB));
        vm.startPrank(owner);
        module.depledge(EMPTY, tokC, 50e6);
        module.depledge(EMPTY, collA, module.collateralBalance(EMPTY, collA));
        module.removeCollateralToken(tokC);
        module.removeCollateralToken(collA);
        module.removeDebtToken(debtB);
        module.removeFacility(EMPTY);
        vm.stopPrank();
        assertEq(tokC.balanceOf(owner), 50e6);
        assertEq(collA.balanceOf(owner), 100e18);
        assertEq(module.facilitiesLength(), 0);
    }

    /////////////////////////////
    /// NAV: DECIMALS AND EXTREME PRICES
    /////////////////////////////

    uint256 internal constant PRICE_BTC_6 = 1_000_012_345_678_901_234_567_890_123_456_789_012_345; // ~100,001 per 8-dec token
    uint256 internal constant PRICE_A_6 = 3_000_123_456_789_012_345_678_901_234; // ~3,000 per 18-dec token
    uint256 internal constant PRICE_B_6 = 1_000_111_222_333_444_555_666_777; // ~1 per 18-dec token

    /// @dev 6-decimal Box asset, 8- and 18-decimal collateral, 18- and 6-decimal debt (the latter being the asset)
    function testNavMixedDecimalsAndExtremePrices() public {
        ERC20MockDecimals btc = new ERC20MockDecimals(8);
        uint256 btcId = spoke.addReserve(address(btc), 8, 7000, false);
        spoke.setPrice(btcId, 100_000e8);
        spoke.setPrice(COLL_A, 3_000e8);
        uint256[] memory ids = new uint256[](4);
        ids[0] = COLL_A;
        ids[1] = DEBT_B;
        ids[2] = TOK_C;
        ids[3] = btcId;
        FundingAaveV4 m = new FundingAaveV4(owner, address(spoke), ids, 0.8e18);
        vm.startPrank(owner);
        m.addFacility(EMPTY);
        m.addCollateralToken(btc);
        m.addCollateralToken(collA);
        m.addDebtToken(debtB);
        m.addDebtToken(tokC);
        vm.stopPrank();
        _pledge(m, btc, 2e8 + 3);
        _pledge(m, collA, 10e18 + 1);
        _borrow(m, debtB, 1_000e18 + 5);
        _borrow(m, tokC, 5_000e6 + 1);

        MockOracleProvider p6 = new MockOracleProvider(address(tokC));
        MockOracle btcOracle = new MockOracle(PRICE_BTC_6);
        MockOracle debtOracle = new MockOracle(PRICE_B_6);
        p6.setOracle(btc, btcOracle);
        p6.setOracle(collA, new MockOracle(PRICE_A_6));
        p6.setOracle(debtB, debtOracle);

        uint256 balBtc = m.collateralBalance(btc);
        uint256 balA = m.collateralBalance(collA);
        uint256 debt18 = m.debtBalance(debtB);
        uint256 debt6 = m.debtBalance(tokC);
        uint256 collateralValue = Math.mulDiv(balBtc, PRICE_BTC_6, 1e36) + Math.mulDiv(balA, PRICE_A_6, 1e36);
        uint256 expected = collateralValue - Math.mulDiv(debt18, PRICE_B_6, 1e36, Math.Rounding.Ceil) - debt6;
        assertEq(m.nav(p6), expected);
        assertApproxEqRel(expected, 224_000e6, 0.001e18, "200k + 30k - 1k - 5k in 6-decimal units");

        // A zero debt price values that debt at 0 without reverting
        debtOracle.setPrice(0);
        assertEq(m.nav(p6), collateralValue - debt6);

        // balance * price exceeds 2^256 but the value fits: no overflow thanks to the 512-bit mulDiv
        btcOracle.setPrice(1e70);
        assertGt(balBtc, type(uint256).max / 1e70);
        assertEq(m.nav(p6), Math.mulDiv(balBtc, 1e70, 1e36) + Math.mulDiv(balA, PRICE_A_6, 1e36) - debt6);
    }
}

/// @dev The module driven by a real Box: token flows, repay max / depledge max resolution, winddown and removal.
contract FundingAaveV4BoxTest is FundingAaveV4Fixture {
    using BoxLib for Box;

    address internal boxOwner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);
    address internal anyone = address(0x5);

    Box internal box;
    FundingAaveV4 internal m;
    MockOracle internal boxCollOracle;

    function setUp() public override {
        super.setUp();
        box = new Box(address(debtB), boxOwner, curator, "Box B", "BOXB", 0.01 ether, 7 days, 10 days, 1 days);
        boxCollOracle = new MockOracle(1e36);

        FundingAaveV4Factory factory = new FundingAaveV4Factory();
        m = factory.createFundingAaveV4(address(box), address(spoke), _ids(), 0.9e18);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(collA, boxCollOracle);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addFundingInstant(m);
        box.addFundingFacilityInstant(m, EMPTY);
        box.addFundingCollateralInstant(m, collA);
        box.addFundingDebtInstant(m, debtB);
        vm.stopPrank();

        debtB.mint(address(this), 1_000e18);
        debtB.approve(address(box), 1_000e18);
        box.deposit(1_000e18, address(this));
        collA.mint(address(box), 500e18);
    }

    function _open() internal {
        vm.startPrank(allocator);
        box.pledge(m, EMPTY, collA, 500e18);
        box.borrow(m, EMPTY, debtB, 300e18);
        vm.stopPrank();
    }

    function testBoxPledgeBorrowIsNavNeutral() public {
        uint256 totalAssetsBefore = box.totalAssets();
        assertEq(totalAssetsBefore, 1_500e18);
        _open();
        assertEq(box.totalAssets(), totalAssetsBefore);
        assertEq(debtB.balanceOf(address(box)), 1_300e18);
        assertEq(collA.balanceOf(address(box)), 0);
        assertEq(m.collateralBalance(EMPTY, collA), 500e18);
        assertEq(m.debtBalance(EMPTY, debtB), 300e18);
        assertEq(collA.balanceOf(address(m)), 0);
        assertEq(debtB.balanceOf(address(m)), 0);
    }

    function testBoxFullUnwindWithPremiumAndRemoval() public {
        _open();
        uint256 totalAssetsBefore = box.totalAssets();
        spoke.setDrawnIndex(DEBT_B, 1.02e27 + 17);
        spoke.setPremiumDebt(DEBT_B, address(m), 1e18 + 3);
        uint256 debt = m.debtBalance(EMPTY, debtB);
        assertGt(debt, 307e18);
        assertEq(box.totalAssets(), totalAssetsBefore - (debt - 300e18), "nav drops by the accrued debt");

        vm.startPrank(curator);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingFacility(m, EMPTY);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingCollateral(m, collA);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        box.removeFundingDebt(m, debtB);
        vm.stopPrank();

        vm.prank(allocator);
        box.repay(m, EMPTY, debtB, type(uint256).max);
        assertEq(spoke.getUserTotalDebt(DEBT_B, address(m)), 0, "debt closed");
        IAaveV4Spoke.UserPosition memory p = spoke.getUserPosition(DEBT_B, address(m));
        assertEq(p.drawnShares, 0);
        assertEq(p.premiumShares, 0);
        assertEq(debtB.balanceOf(address(m)), 0);
        assertEq(debtB.balanceOf(address(box)), 1_300e18 - debt);

        vm.prank(allocator);
        box.depledge(m, EMPTY, collA, type(uint256).max);
        assertEq(spoke.getUserSuppliedShares(COLL_A, address(m)), 0);
        assertEq(collA.balanceOf(address(box)), 500e18);
        assertEq(collA.balanceOf(address(m)), 0);

        vm.startPrank(curator);
        box.removeFundingFacility(m, EMPTY);
        box.removeFundingCollateral(m, collA);
        box.removeFundingDebt(m, debtB);
        box.removeFunding(m);
        vm.stopPrank();
        assertFalse(box.isFunding(m));
    }

    function testBoxWinddownAnyoneRepaysAndDepledgesWithGuard() public {
        _open();
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown());

        // cap 0.9 => min HF 1.111..; 100e18 out leaves HF = 0.8 * 400 / 300 = 1.0667: above 1, below the cap
        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(m, EMPTY, collA, 100e18);
        assertEq(m.collateralBalance(EMPTY, collA), 500e18);

        vm.prank(anyone);
        box.repay(m, EMPTY, debtB, type(uint256).max);
        assertEq(m.debtBalance(EMPTY, debtB), 0);

        vm.prank(anyone);
        box.depledge(m, EMPTY, collA, type(uint256).max);
        assertEq(collA.balanceOf(address(box)), 500e18);
        assertEq(m.collateralBalance(EMPTY, collA), 0);
        assertEq(box.totalAssets(), 1_500e18);
    }

    function testBoxWinddownStallsWhileDebtReservePausedThenCompletes() public {
        _open();
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        uint256 totalAssetsBefore = box.totalAssets();

        // Paused debt reserve: the Spoke blocks repay, nav and views still work, an in-cap depledge still works
        spoke.setPaused(DEBT_B, true);
        vm.prank(anyone);
        vm.expectRevert(MockAaveV4Spoke.ReservePaused.selector);
        box.repay(m, EMPTY, debtB, type(uint256).max);
        assertEq(box.totalAssets(), totalAssetsBefore);
        assertEq(m.debtBalance(debtB), 300e18);
        // HF after = 0.8 * 490 / 300 = 1.3067 >= 1.111
        vm.prank(anyone);
        box.depledge(m, EMPTY, collA, 10e18);
        assertEq(collA.balanceOf(address(box)), 10e18);

        // Frozen reserves do not block the winddown
        spoke.setPaused(DEBT_B, false);
        spoke.setFrozen(DEBT_B, true);
        spoke.setFrozen(COLL_A, true);
        vm.startPrank(anyone);
        box.repay(m, EMPTY, debtB, type(uint256).max);
        box.depledge(m, EMPTY, collA, type(uint256).max);
        vm.stopPrank();
        assertEq(m.debtBalance(debtB), 0);
        assertEq(m.collateralBalance(collA), 0);

        // Without debt a repay is a no-op that never reaches the (paused) Spoke reserve
        spoke.setPaused(DEBT_B, true);
        uint256 actions = spoke.actionCount();
        vm.prank(anyone);
        box.repay(m, EMPTY, debtB, type(uint256).max);
        assertEq(spoke.actionCount(), actions, "no Spoke call");
        assertEq(collA.balanceOf(address(box)), 500e18);
        assertEq(box.totalAssets(), totalAssetsBefore);
    }

    /// @dev A token whose transfer hook calls back cannot re-enter a Box action (Box lock) nor the module (owner only)
    function testActionsCannotBeReenteredThroughTokenHooks() public {
        ReentrantHookToken hook = new ReentrantHookToken();
        uint256[] memory ids = new uint256[](2);
        ids[0] = spoke.addReserve(address(hook), 18, 8000, false);
        ids[1] = DEBT_B;
        FundingAaveV4 hm = new FundingAaveV4(address(box), address(spoke), ids, 0.9e18);

        vm.startPrank(curator);
        box.addTokenInstant(hook, new MockOracle(1e36));
        box.addFundingInstant(hm);
        box.addFundingFacilityInstant(hm, EMPTY);
        box.addFundingCollateralInstant(hm, hook);
        box.addFundingDebtInstant(hm, debtB);
        // The hook gets the allocator role, so only the reentrancy protection can stop it
        box.setIsAllocator(address(hook), true);
        vm.stopPrank();

        hook.mint(address(box), 100e18);
        vm.startPrank(allocator);
        box.pledge(hm, EMPTY, hook, 90e18);
        box.borrow(hm, EMPTY, debtB, 10e18);
        vm.stopPrank();

        // Re-entering Box.borrow while the Spoke sends collateral to the module during a depledge
        hook.arm(address(hm), address(box), abi.encodeCall(Box.borrow, (IFunding(address(hm)), EMPTY, IERC20(address(debtB)), 1e18)));
        vm.prank(allocator);
        box.depledge(hm, EMPTY, hook, 10e18);
        assertTrue(hook.reentryAttempted());
        assertFalse(hook.reentrySucceeded());
        assertEq(bytes4(hook.reentryReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        // Calling the module directly while the Box sends it collateral during a pledge
        hook.arm(address(hm), address(hm), abi.encodeCall(FundingAaveV4.borrow, (EMPTY, IERC20(address(debtB)), 1e18)));
        vm.prank(allocator);
        box.pledge(hm, EMPTY, hook, 20e18);
        assertTrue(hook.reentryAttempted());
        assertFalse(hook.reentrySucceeded());
        assertEq(bytes4(hook.reentryReturnData()), ErrorsLib.OnlyOwner.selector);

        assertEq(hm.debtBalance(EMPTY, debtB), 10e18, "no extra debt");
        assertEq(hm.collateralBalance(EMPTY, hook), 100e18);
        assertEq(hook.balanceOf(address(box)), 0);
        assertEq(hook.balanceOf(address(hm)), 0);
        assertEq(debtB.balanceOf(address(hm)), 0);
    }

    function testBoxWinddownDebtBalanceOfUnknownTokens() public {
        _open();
        assertEq(m.debtBalance(stranger), 0);
        assertEq(m.debtBalance(IERC20(address(0xdead))), 0);
        assertEq(m.collateralBalance(stranger), 0);
    }
}
