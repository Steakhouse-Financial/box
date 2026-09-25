// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingAave, IPool} from "../../src/FundingAave.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding} from "../../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockAaveV3BalanceToken, MockAaveV3Pool} from "../mocks/MockAaveV3Pool.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @dev Stateless fuzzing of FundingAave (Aave v3) on the mock pool, driven through a real Box.
/// The fixture Box holds three reserves listed on the pool: its asset, `coll` and `other` (both Box tokens with oracles).
contract FundingAaveFuzzTest is Test {
    using BoxLib for IBox;

    uint256 internal constant ORACLE_PRECISION = 1e36;
    /// @dev Amount bounds in whole units of the token
    uint256 internal constant MAX_UNITS = 1e12;
    /// @dev Pool prices have 8 decimals (Aave base currency); up to 10,000 base units per whole token
    uint256 internal constant MAX_POOL_PRICE = 1e12;
    uint256 internal constant FIXTURE_ASSET_POOL_PRICE = 1e8;
    uint256 internal constant FIXTURE_COLL_POOL_PRICE = 2e8;
    uint256 internal constant FIXTURE_OTHER_POOL_PRICE = 1e8;
    /// @dev Leaves the pool's own max LTV (80% of a liquidation threshold of 85%) as the binding limit
    uint256 internal constant LLTV_CAP = 0.95e18;

    address internal owner = address(0x1);
    address internal allocator = address(0x2);
    address internal curator = address(0x3);
    address internal guardian = address(0x4);

    MockAaveV3Pool internal pool;
    ERC20MockDecimals internal asset;
    ERC20MockDecimals internal coll;
    ERC20MockDecimals internal other;
    MockOracle internal collOracle;
    MockOracle internal otherOracle;
    IBox internal box;
    FundingAave internal module;

    function setUp() public {
        _deploy(18, 18, 6, FIXTURE_ASSET_POOL_PRICE, FIXTURE_COLL_POOL_PRICE, FIXTURE_OTHER_POOL_PRICE);
        _registerCollateral(coll);
        _registerDebt(asset);
    }

    /////////////////////////////
    /// SETUP HELPERS
    /////////////////////////////

    function _decimals(uint256 seed) internal pure returns (uint8) {
        uint8[3] memory options = [uint8(6), 8, 18];
        return options[seed % 3];
    }

    /// @dev Box oracle price at which one whole token is worth one whole asset unit
    function _parityPrice(uint8 tokenDecimals) internal view returns (uint256) {
        return (ORACLE_PRECISION * 10 ** asset.decimals()) / 10 ** tokenDecimals;
    }

    /// @dev Odd, so it is never a round number, anywhere from 1 wei to 10,000x parity
    function _nonRoundPrice(uint256 seed, uint8 tokenDecimals) internal view returns (uint256) {
        return bound(seed, 1, 1e4 * _parityPrice(tokenDecimals)) | 1;
    }

    /// @dev Fresh pool, tokens, Box (with allocator, guardian and both tokens) and a FundingAave attached to the Box
    /// with the facility "" registered and no token registered yet.
    function _deploy(
        uint8 assetDecimals,
        uint8 collDecimals,
        uint8 otherDecimals,
        uint256 assetPoolPrice,
        uint256 collPoolPrice,
        uint256 otherPoolPrice
    ) internal {
        pool = new MockAaveV3Pool();
        asset = new ERC20MockDecimals(assetDecimals);
        coll = new ERC20MockDecimals(collDecimals);
        other = new ERC20MockDecimals(otherDecimals);
        pool.listReserve(address(asset), assetPoolPrice);
        pool.listReserve(address(coll), collPoolPrice);
        pool.listReserve(address(other), otherPoolPrice);

        collOracle = new MockOracle(_parityPrice(collDecimals));
        otherOracle = new MockOracle(_parityPrice(otherDecimals));

        box = IBox(address(new Box(address(asset), owner, curator, "Box Aave Fuzz", "BOXAF", 0.01 ether, 7 days, 10 days, 7 days)));
        module = new FundingAave(address(box), IPool(address(pool)), 0, LLTV_CAP);

        vm.startPrank(curator);
        box.setIsAllocator(allocator, true);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(coll, collOracle);
        box.addTokenInstant(other, otherOracle);
        box.addFundingInstant(module);
        box.addFundingFacilityInstant(module, "");
        vm.stopPrank();
    }

    function _registerCollateral(IERC20 token) internal {
        vm.prank(curator);
        box.addFundingCollateralInstant(module, token);
    }

    function _registerDebt(IERC20 token) internal {
        vm.prank(curator);
        box.addFundingDebtInstant(module, token);
    }

    /// @dev Largest borrow the mock pool accepts: floor(collateral * collPrice / collUnit) is the collateral base, the
    /// debt base ceil(borrow * debtPrice / debtUnit) may reach floor(collateralBase * MAX_LTV_BPS / 1e4).
    function _borrowLimit(
        uint256 collateral,
        uint256 collPrice,
        uint256 collUnit,
        uint256 debtPrice,
        uint256 debtUnit
    ) internal view returns (uint256) {
        uint256 maxDebtBase = (((collateral * collPrice) / collUnit) * pool.MAX_LTV_BPS()) / 1e4;
        return (maxDebtBase * debtUnit) / debtPrice;
    }

    /// @dev Smallest collateral whose borrow limit is at least 1 wei of debt
    function _minCollateral(uint256 collPrice, uint256 collUnit, uint256 debtPrice, uint256 debtUnit) internal view returns (uint256) {
        uint256 collateralBaseNeeded = Math.ceilDiv(Math.ceilDiv(debtPrice, debtUnit) * 1e4, pool.MAX_LTV_BPS());
        return Math.mulDiv(collateralBaseNeeded, collUnit, collPrice, Math.Rounding.Ceil);
    }

    /// @dev Live fixture position through the Box: `coll` pledged, the asset borrowed, then interest accrued on the mock.
    /// The Box is funded with the interest so it can repay in full.
    function _openPosition(uint256 c, uint256 b, uint256 interest) internal returns (uint256, uint256, uint256) {
        uint256 minCollateral = _minCollateral(FIXTURE_COLL_POOL_PRICE, 1e18, FIXTURE_ASSET_POOL_PRICE, 1e18);
        c = bound(c, minCollateral, MAX_UNITS * 1e18);
        b = bound(b, 1, _borrowLimit(c, FIXTURE_COLL_POOL_PRICE, 1e18, FIXTURE_ASSET_POOL_PRICE, 1e18));
        interest = bound(interest, 0, MAX_UNITS * 1e18);

        coll.mint(address(box), c);
        asset.mint(address(pool), b);
        vm.startPrank(allocator);
        box.pledge(module, "", coll, c);
        box.borrow(module, "", asset, b);
        vm.stopPrank();
        if (interest > 0) pool.accrueDebt(address(module), address(asset), interest);
        asset.mint(address(box), interest);
        return (c, b, interest);
    }

    function _aToken(IERC20 token) internal view returns (address aToken) {
        (, , , , , , , , aToken, , , , , , ) = pool.getReserveData(address(token));
    }

    function _assertModuleHoldsNothing(IERC20 debtToken, string memory when) internal view {
        assertEq(coll.balanceOf(address(module)), 0, string.concat("module holds no collateral token ", when));
        assertEq(debtToken.balanceOf(address(module)), 0, string.concat("module holds no debt token ", when));
    }

    /////////////////////////////
    /// ROUND TRIP THROUGH THE BOX
    /////////////////////////////

    struct RoundTrip {
        uint256 collDecimalsSeed;
        uint256 debtDecimalsSeed;
        bool debtIsAsset;
        uint256 collPoolPrice;
        uint256 debtPoolPrice;
        uint256 collateral;
        uint256 borrowed;
        uint256 interest;
        uint256 elapsed;
    }

    function testFuzz_RoundTripClosesCleanly(RoundTrip memory rt) public {
        uint8 collDecimals = _decimals(rt.collDecimalsSeed);
        uint8 debtDecimals = _decimals(rt.debtDecimalsSeed);
        uint256 collPrice = bound(rt.collPoolPrice, 1, MAX_POOL_PRICE);
        uint256 debtPrice = bound(rt.debtPoolPrice, 1, MAX_POOL_PRICE);
        // The debt token is either the Box asset or a Box token
        if (rt.debtIsAsset) _deploy(debtDecimals, collDecimals, 18, debtPrice, collPrice, 1e8);
        else _deploy(18, collDecimals, debtDecimals, 1e8, collPrice, debtPrice);
        ERC20MockDecimals debtToken = rt.debtIsAsset ? asset : other;
        _registerCollateral(coll);
        _registerDebt(debtToken);

        uint256 collUnit = 10 ** collDecimals;
        uint256 debtUnit = 10 ** debtDecimals;
        uint256 minCollateral = _minCollateral(collPrice, collUnit, debtPrice, debtUnit);
        uint256 c = bound(rt.collateral, minCollateral, Math.max(minCollateral, MAX_UNITS * collUnit));
        uint256 limit = _borrowLimit(c, collPrice, collUnit, debtPrice, debtUnit);
        assertGe(limit, 1, "collateral supports at least 1 wei of debt");
        uint256 b = bound(rt.borrowed, 1, limit);
        uint256 interest = bound(rt.interest, 0, MAX_UNITS * debtUnit);

        coll.mint(address(box), c);
        // Enough liquidity for limit + 1, so the probe below can only fail on the pool's LTV check
        debtToken.mint(address(pool), limit + 1);
        uint256 boxDebtStart = debtToken.balanceOf(address(box));

        vm.prank(allocator);
        box.pledge(module, "", coll, c);
        assertEq(coll.balanceOf(address(box)), 0, "Box sent the collateral");
        assertEq(module.collateralBalance("", coll), c, "collateral supplied");
        _assertModuleHoldsNothing(debtToken, "after pledge");

        vm.prank(allocator);
        vm.expectRevert(bytes("COLLATERAL_CANNOT_COVER_NEW_BORROW"));
        box.borrow(module, "", debtToken, limit + 1);

        vm.prank(allocator);
        box.borrow(module, "", debtToken, b);
        assertEq(debtToken.balanceOf(address(box)), boxDebtStart + b, "Box receives exactly the borrowed amount");
        assertEq(module.debtBalance("", debtToken), b, "debt recorded");
        _assertModuleHoldsNothing(debtToken, "after borrow");

        if (interest > 0) pool.accrueDebt(address(module), address(debtToken), interest);
        debtToken.mint(address(box), interest);
        vm.warp(block.timestamp + bound(rt.elapsed, 0, 365 days));
        assertEq(module.debtBalance("", debtToken), b + interest, "debt includes interest");

        vm.prank(allocator);
        box.repay(module, "", debtToken, type(uint256).max);
        assertEq(module.debtBalance("", debtToken), 0, "debt closed by repay(max)");
        _assertModuleHoldsNothing(debtToken, "after repay");
        uint256 netDebtCost = boxDebtStart + interest - debtToken.balanceOf(address(box));
        // The mock accrues no hidden interest, so the cost is exact (the allowed bound is interest + 1 wei per action)
        assertEq(netDebtCost, interest, "net debt cost equals the accrued interest");

        vm.prank(allocator);
        box.depledge(module, "", coll, type(uint256).max);
        assertEq(module.collateralBalance("", coll), 0, "collateral withdrawn by depledge(max)");
        assertEq(coll.balanceOf(address(box)), c, "Box collateral back exactly");
        _assertModuleHoldsNothing(debtToken, "after depledge");

        vm.startPrank(curator);
        box.removeFundingFacility(module, "");
        box.removeFundingCollateral(module, coll);
        box.removeFundingDebt(module, debtToken);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(module.isFacility(""), "facility removed");
        assertFalse(box.isFunding(module), "module removed");
    }

    /////////////////////////////
    /// NAV ROUNDING
    /////////////////////////////

    struct NavCase {
        uint256 assetDecimalsSeed;
        uint256 collDecimalsSeed;
        uint256 otherDecimalsSeed;
        uint256 collPriceSeed;
        uint256 otherPriceSeed;
        uint256[3] collateral; // Box asset, coll, other
        uint256[3] debt; // Box asset, coll, other
        uint256[3] idle; // Box asset, coll, other
    }

    /// @dev Reference (one recourse unit: the Aave account):
    ///   nav = max(0, Σ floor(collateral_i × price_i / 1e36) − Σ ceil(debt_i × price_i / 1e36))
    /// with price_i the Box oracle price and the Box asset valued 1:1 (price 1e36, the Box has no oracle for it).
    function testFuzz_NavMatchesAccountLevelReference(NavCase memory nc) public {
        _deploy(_decimals(nc.assetDecimalsSeed), _decimals(nc.collDecimalsSeed), _decimals(nc.otherDecimalsSeed), 1e8, 1e8, 1e8);
        ERC20MockDecimals[3] memory tokens = [asset, coll, other];
        uint256[3] memory prices = [
            ORACLE_PRECISION,
            _nonRoundPrice(nc.collPriceSeed, coll.decimals()),
            _nonRoundPrice(nc.otherPriceSeed, other.decimals())
        ];
        collOracle.setPrice(prices[1]);
        otherOracle.setPrice(prices[2]);

        uint256 collValue;
        uint256 debtValue;
        uint256 collExact; // Σ collateral × price, unrounded (scaled by 1e36)
        uint256 debtExact; // Σ debt × price, unrounded (scaled by 1e36)
        for (uint256 i; i < 3; i++) {
            _registerCollateral(tokens[i]);
            _registerDebt(tokens[i]);
            uint256 unit = 10 ** tokens[i].decimals();
            uint256 c = bound(nc.collateral[i], 0, MAX_UNITS * unit);
            uint256 d = bound(nc.debt[i], 0, MAX_UNITS * unit);
            if (c > 0) {
                tokens[i].mint(address(box), c);
                vm.prank(allocator);
                box.pledge(module, "", tokens[i], c);
            }
            // Debt is minted on the mock like accrued interest, so any size (including an underwater account) is reachable
            if (d > 0) pool.accrueDebt(address(module), address(tokens[i]), d);

            collValue += Math.mulDiv(c, prices[i], ORACLE_PRECISION);
            debtValue += Math.mulDiv(d, prices[i], ORACLE_PRECISION, Math.Rounding.Ceil);
            collExact += c * prices[i];
            debtExact += d * prices[i];
        }
        uint256 expected = collValue > debtValue ? collValue - debtValue : 0;

        (bool ok, bytes memory ret) = address(module).staticcall(abi.encodeCall(IFunding.nav, (box)));
        assertTrue(ok, "nav never reverts");
        uint256 nav = abi.decode(ret, (uint256));
        assertEq(nav, expected, "nav = max(0, sum floor(coll * price / 1e36) - sum ceil(debt * price / 1e36))");
        if (collExact > debtExact) assertLe(nav * ORACLE_PRECISION, collExact - debtExact, "nav <= exact equity");
        else assertEq(nav, 0, "no equity, nav floored at 0");
        assertEq(box.totalAssets(), nav, "Box totalAssets = module nav (the Box holds nothing else)");

        // Idle balances held by the module are excluded
        for (uint256 i; i < 3; i++) {
            tokens[i].mint(address(module), bound(nc.idle[i], 0, MAX_UNITS * 10 ** tokens[i].decimals()));
        }
        assertEq(module.nav(box), expected, "idle module balances are excluded");
        assertEq(box.totalAssets(), nav, "totalAssets unchanged by idle module balances");
    }

    /////////////////////////////
    /// ONLY "" IS A FACILITY
    /////////////////////////////

    function testFuzz_OnlyEmptyFacilityDataIsAccepted(bytes memory fd, uint256 c, uint256 b, uint256 interest, uint256 amount) public {
        if (fd.length == 0) fd = hex"00";

        FundingAave fresh = new FundingAave(address(box), IPool(address(pool)), 0, LLTV_CAP);
        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        fresh.addFacility(fd);
        assertEq(fresh.facilitiesLength(), 0, "nothing registered");
        fresh.addFacility("");
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        fresh.addFacility(fd);
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        fresh.addFacility("");
        vm.stopPrank();
        assertTrue(fresh.isFacility(""), "empty facility registered");
        assertFalse(fresh.isFacility(fd), "non-empty bytes are not a facility");
        assertEq(fresh.facilitiesLength(), 1, "one facility");

        // Fixture module: "" registered, no position yet
        assertFalse(module.isFacility(fd), "non-empty bytes are not a facility (fixture)");
        vm.prank(curator);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.removeFundingFacility(module, fd);

        (c, b, interest) = _openPosition(c, b, interest);
        amount = bound(amount, 1, MAX_UNITS * 1e18);
        coll.mint(address(box), amount);

        vm.startPrank(allocator);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.pledge(module, fd, coll, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.borrow(module, fd, asset, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.repay(module, fd, asset, type(uint256).max);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        box.depledge(module, fd, coll, type(uint256).max);
        vm.stopPrank();

        // Direct owner calls with the tokens already at the module
        coll.mint(address(module), amount);
        asset.mint(address(module), amount);
        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.pledge(fd, coll, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.depledge(fd, coll, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.borrow(fd, asset, amount);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.repay(fd, asset, amount);
        // The used-position check comes first
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fd);
        vm.stopPrank();

        assertEq(module.collateralBalance("", coll), c, "position collateral unchanged");
        assertEq(module.debtBalance("", asset), b + interest, "position debt unchanged");
        assertEq(module.facilitiesLength(), 1, "still one facility");
    }

    /////////////////////////////
    /// ONLY THE OWNER
    /////////////////////////////

    function _ownerGatedCalls(bytes memory fd, IERC20 token, uint256 amount) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(IFunding.addFacility, (fd));
        calls[1] = abi.encodeCall(IFunding.removeFacility, (fd));
        calls[2] = abi.encodeCall(IFunding.addCollateralToken, (token));
        calls[3] = abi.encodeCall(IFunding.addDebtToken, (token));
        calls[4] = abi.encodeCall(IFunding.removeCollateralToken, (token));
        calls[5] = abi.encodeCall(IFunding.removeDebtToken, (token));
        calls[6] = abi.encodeCall(IFunding.skim, (token));
        calls[7] = abi.encodeCall(IFunding.pledge, (fd, token, amount));
        calls[8] = abi.encodeCall(IFunding.depledge, (fd, token, amount));
        calls[9] = abi.encodeCall(IFunding.borrow, (fd, token, amount));
        calls[10] = abi.encodeCall(IFunding.repay, (fd, token, amount));
    }

    function _nonOwner(address caller) internal view returns (address) {
        if (caller == address(box) || caller == address(vm)) return address(uint160(caller) ^ 1);
        return caller;
    }

    function _assertOnlyOwner(address caller, bytes memory data, uint256 index) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(module).call(data);
        assertFalse(ok, string.concat("owner-gated call succeeded, index ", vm.toString(index)));
        assertEq(ret, abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector), string.concat("OnlyOwner, index ", vm.toString(index)));
    }

    /// @dev A live position and a skimmable balance, so every call would change state if the owner check were missing
    function _prepareOwnerGatedState() internal {
        _openPosition(100e18, 50e18, 1e18);
        coll.mint(address(module), 1e18);
    }

    function _assertOwnerGatedStateUnchanged() internal view {
        assertEq(module.facilitiesLength(), 1, "facilities unchanged");
        assertEq(module.collateralTokensLength(), 1, "collateral tokens unchanged");
        assertEq(module.debtTokensLength(), 1, "debt tokens unchanged");
        assertEq(module.collateralBalance(coll), 100e18, "collateral unchanged");
        assertEq(module.debtBalance(asset), 51e18, "debt unchanged");
        assertEq(coll.balanceOf(address(module)), 1e18, "skimmable balance unchanged");
    }

    function testFuzz_NonOwnerCannotCallOwnerGatedFunctions(address caller, bytes memory fd, address token, uint256 amount) public {
        caller = _nonOwner(caller);
        _prepareOwnerGatedState();

        bytes[] memory calls = _ownerGatedCalls(fd, IERC20(token), amount);
        for (uint256 i; i < calls.length; i++) {
            _assertOnlyOwner(caller, calls[i], i);
        }
        _assertOwnerGatedStateUnchanged();
    }

    function testFuzz_NonOwnerMulticallReverts(address caller, uint256 index, bytes memory fd, address token, uint256 amount) public {
        caller = _nonOwner(caller);
        _prepareOwnerGatedState();

        bytes[] memory batch = new bytes[](2);
        batch[0] = abi.encodeCall(IFunding.isFacility, (fd));
        batch[1] = _ownerGatedCalls(fd, IERC20(token), amount)[bound(index, 0, 10)];
        vm.prank(caller);
        vm.expectRevert(ErrorsLib.OnlyOwner.selector);
        module.multicall(batch);
        _assertOwnerGatedStateUnchanged();
    }

    function testFuzz_BoxRolesCannotCallModuleDirectly(bytes memory fd, address token, uint256 amount) public {
        _prepareOwnerGatedState();
        assertTrue(box.isAllocator(allocator), "allocator registered");
        assertEq(box.curator(), curator, "curator");
        assertEq(box.guardian(), guardian, "guardian");
        assertEq(box.owner(), owner, "Box owner");
        assertEq(module.owner(), address(box), "module owned by the Box");

        address[4] memory roles = [allocator, curator, guardian, owner];
        bytes[] memory calls = _ownerGatedCalls(fd, IERC20(token), amount);
        for (uint256 r; r < roles.length; r++) {
            for (uint256 i; i < calls.length; i++) {
                _assertOnlyOwner(roles[r], calls[i], i);
            }
        }
        _assertOwnerGatedStateUnchanged();
    }

    /////////////////////////////
    /// UNLISTED TOKENS READ AS 0
    /////////////////////////////

    function _assertViewsZero(IERC20 token, bytes memory fd, string memory label) internal view {
        assertEq(module.debtBalance(token), 0, string.concat("debtBalance(token) ", label));
        assertEq(module.collateralBalance(token), 0, string.concat("collateralBalance(token) ", label));
        assertEq(module.debtBalance(fd, token), 0, string.concat("debtBalance(fd, token) ", label));
        assertEq(module.collateralBalance(fd, token), 0, string.concat("collateralBalance(fd, token) ", label));
        assertEq(module.debtBalance("", token), 0, string.concat("debtBalance(empty fd, token) ", label));
        assertEq(module.collateralBalance("", token), 0, string.concat("collateralBalance(empty fd, token) ", label));
    }

    function testFuzz_UnlistedTokenViewsReturnZeroWithLivePosition(
        uint256 c,
        uint256 b,
        uint256 interest,
        uint256 donation,
        address t,
        bytes memory fd
    ) public {
        (c, b, interest) = _openPosition(c, b, interest);
        // `other` is a listed reserve the module never registered; a donated aToken balance is still read live
        donation = bound(donation, 0, MAX_UNITS * 1e6);
        MockAaveV3BalanceToken otherAToken = MockAaveV3BalanceToken(_aToken(other));
        vm.prank(address(pool));
        otherAToken.mint(address(module), donation);

        ERC20MockDecimals unlisted = new ERC20MockDecimals(18);
        unlisted.mint(address(module), 1e18);
        address eoa = makeAddr("eoa");
        assertEq(eoa.code.length, 0, "eoa has no code");
        (bool hasBalanceOf, ) = address(collOracle).staticcall(abi.encodeCall(IERC20.balanceOf, (address(module))));
        assertFalse(hasBalanceOf, "the oracle has no balanceOf");

        _assertViewsZero(IERC20(address(0)), fd, "address(0)");
        _assertViewsZero(IERC20(eoa), fd, "EOA");
        _assertViewsZero(IERC20(address(collOracle)), fd, "contract without balanceOf");
        _assertViewsZero(unlisted, fd, "unlisted ERC20");

        // Any fuzzed address: listed reserves read live balances, every other address reads 0
        uint256 expectedCollateral = t == address(coll) ? c : (t == address(other) ? donation : 0);
        uint256 expectedDebt = t == address(asset) ? b + interest : 0;
        assertEq(module.collateralBalance(IERC20(t)), expectedCollateral, "collateralBalance(t)");
        assertEq(module.collateralBalance(fd, IERC20(t)), expectedCollateral, "collateralBalance(fd, t)");
        assertEq(module.debtBalance(IERC20(t)), expectedDebt, "debtBalance(t)");
        assertEq(module.debtBalance(fd, IERC20(t)), expectedDebt, "debtBalance(fd, t)");

        // Listed reserves keep returning live balances with any facility data
        assertEq(module.collateralBalance(fd, coll), c, "live collateral");
        assertEq(module.collateralBalance(coll), c, "live collateral (token only)");
        assertEq(module.debtBalance(fd, asset), b + interest, "live debt");
        assertEq(module.debtBalance(asset), b + interest, "live debt (token only)");
        assertEq(module.collateralBalance(fd, other), donation, "listed unregistered reserve, live aToken balance");
        assertEq(module.debtBalance(fd, coll), 0, "listed reserve without debt");
        assertEq(module.collateralBalance(fd, asset), 0, "listed reserve without supply");
    }
}
