// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../src/Box.sol";
import {FundingMidnight, OfferFill} from "../src/FundingMidnight.sol";
import {FundingMidnightFactory} from "../src/factories/FundingMidnightFactory.sol";
import {IFunding, IOracleCallback} from "../src/interfaces/IFunding.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {CollateralParams, IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IRatifier} from "../src/interfaces/midnight/IRatifier.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {IdLib} from "../src/libraries/midnight/IdLib.sol";
import {MidnightMathLib} from "../src/libraries/midnight/MidnightMathLib.sol";
import {TickLib} from "../src/libraries/midnight/TickLib.sol";
import {BoxLib} from "../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "./mocks/ERC20MockDecimals.sol";
import {MIDNIGHT_CALLBACK_SUCCESS, MockMidnight} from "./mocks/MockMidnight.sol";
import {MockMidnightRatifier} from "./mocks/MockMidnightRatifier.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockOracleProvider} from "./mocks/MockOracleProvider.sol";

/// @dev Oracle that can be switched to revert (Midnight market oracles are part of the market id, so the same
///      instance must be used for the whole test).
contract SwitchOracle is IOracle {
    error OracleReverted();

    uint256 internal _price;
    bool public reverts;

    constructor(uint256 price_) {
        _price = price_;
    }

    function price() external view returns (uint256) {
        require(!reverts, OracleReverted());
        return _price;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function setReverts(bool newReverts) external {
        reverts = newReverts;
    }
}

/// @dev Ratifier accepting only the ratifier data "ok", to exercise invalid ratifier data.
contract DataRatifier is IRatifier {
    error BadRatifierData();

    function isRatified(Offer memory, bytes memory ratifierData, address) external pure returns (bytes32) {
        require(keccak256(ratifierData) == keccak256("ok"), BadRatifierData());
        return MIDNIGHT_CALLBACK_SUCCESS;
    }
}

struct WrappedFacility {
    Market market;
    uint256 collateralIndex;
    uint256 maxBorrowApr;
}

/// @dev Fixture: the module attached to a real Box (asset USDC) on a mock Midnight, at the timestamp and maturity of
///      the worked example in the Midnight library notes (Base cbBTC/USDC 2026-12-25 market, 6-decimal USDC).
abstract contract FundingMidnightFixture is Test {
    using BoxLib for Box;

    uint256 internal constant T1 = 1790212611;
    uint256 internal constant M = 1798210800;
    uint256 internal constant M2 = 1793372400;
    uint256 internal constant CBBTC_PRICE = 842515000000000000000000000000000000000; // 84,251.5 USDC per cbBTC
    uint256 internal constant WETH_PRICE = 2_500e6 * 1e18; // 2,500 USDC per WETH (18 decimals)
    uint256 internal constant MAX_APR = 0.08e18;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant LLTV_CAP = 0.9e18;
    uint256 internal constant TICK = 4212; // price 0.9850729
    uint256 internal constant HIGH_TICK = 4300; // price 0.9903233
    uint256 internal constant FD2_TICK = 4400; // price 0.9941007, 5.92% a year on the 2026-10-30 market at T1

    MockMidnight internal midnight;
    MockMidnightRatifier internal ratifier;
    ERC20MockDecimals internal usdc;
    ERC20MockDecimals internal cbBtc;
    ERC20MockDecimals internal weth;
    ERC20MockDecimals internal stranger;
    SwitchOracle internal cbBtcMidnightOracle;
    SwitchOracle internal wethMidnightOracle;
    MockOracle internal boxCbBtcOracle;

    Box internal box;
    FundingMidnight internal module;

    address internal boxOwner = makeAddr("boxOwner");
    address internal curator = makeAddr("curator");
    address internal guardian = makeAddr("guardian");
    address internal allocator = makeAddr("allocator");
    address internal anyone = makeAddr("anyone");
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");

    bytes internal fd;
    bytes internal fd2; // another maturity of the same tokens, not registered by default
    bytes32 internal id;
    bytes32 internal id2;

    function setUp() public virtual {
        vm.warp(T1);
        midnight = new MockMidnight();
        ratifier = new MockMidnightRatifier();
        usdc = new ERC20MockDecimals(6);
        cbBtc = new ERC20MockDecimals(8);
        weth = new ERC20MockDecimals(18);
        stranger = new ERC20MockDecimals(18);
        cbBtcMidnightOracle = new SwitchOracle(CBBTC_PRICE);
        wethMidnightOracle = new SwitchOracle(WETH_PRICE);
        boxCbBtcOracle = new MockOracle(CBBTC_PRICE);

        Market memory m = _market(M);
        fd = _fd(m, 0, MAX_APR);
        id = midnight.touchMarket(m);
        Market memory m2 = _market(M2);
        fd2 = _fd(m2, 0, MAX_APR);
        id2 = midnight.touchMarket(m2);

        _setUpLender(lender);
        _setUpLender(lender2);

        box = new Box(address(usdc), boxOwner, curator, "Box", "BOX", 0.01 ether, 7 days, 10 days, 1 days);
        module = new FundingMidnightFactory().createFundingMidnight(address(box), address(midnight), LLTV_CAP);

        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.addTokenInstant(cbBtc, boxCbBtcOracle);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, cbBtc);
        box.addFundingDebtInstant(module, usdc);
        box.addFundingFacilityInstant(module, fd);
        vm.stopPrank();

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(box), 1_000_000e6);
        box.deposit(1_000_000e6, address(this));
        cbBtc.mint(address(box), 10e8);
    }

    // ========== BUILDERS ==========

    function _setUpLender(address who) internal {
        usdc.mint(who, 10_000_000e6);
        vm.startPrank(who);
        usdc.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ratifier), true, who);
        vm.stopPrank();
    }

    function _market(uint256 maturity) internal view returns (Market memory m) {
        m.chainId = block.chainid;
        m.midnight = address(midnight);
        m.loanToken = address(usdc);
        m.collateralParams = new CollateralParams[](1);
        m.collateralParams[0] = CollateralParams(address(cbBtc), LLTV, 0.3e18, address(cbBtcMidnightOracle));
        m.maturity = maturity;
        m.rcfThreshold = 3000e6;
    }

    /// @dev cbBTC and WETH collateral, sorted by address. Returns the index of cbBTC.
    function _market2(uint256 maturity) internal view returns (Market memory m, uint256 cbBtcIndex) {
        m = _market(maturity);
        CollateralParams memory a = CollateralParams(address(cbBtc), LLTV, 0.3e18, address(cbBtcMidnightOracle));
        CollateralParams memory b = CollateralParams(address(weth), 0.8e18, 0.3e18, address(wethMidnightOracle));
        m.collateralParams = new CollateralParams[](2);
        if (address(cbBtc) < address(weth)) {
            (m.collateralParams[0], m.collateralParams[1]) = (a, b);
        } else {
            (m.collateralParams[0], m.collateralParams[1]) = (b, a);
            cbBtcIndex = 1;
        }
    }

    function _fd(Market memory m, uint256 collateralIndex, uint256 maxApr) internal pure returns (bytes memory) {
        return abi.encode(m, collateralIndex, maxApr);
    }

    function _bidIn(Market memory m, address maker, uint256 tick, bytes32 group) internal returns (Offer memory o) {
        o.market = m;
        o.buy = true;
        o.maker = maker;
        o.start = block.timestamp;
        o.expiry = M + 30 days;
        o.tick = tick;
        o.group = group;
        o.ratifier = address(ratifier);
        o.maxAssets = 5_000_000e6;
        o.continuousFeeCap = type(uint256).max;
        ratifier.setOfferRatified(o, true);
    }

    function _bid(address maker, uint256 tick, bytes32 group) internal returns (Offer memory) {
        return _bidIn(_market(M), maker, tick, group);
    }

    function _fill(Offer memory o) internal pure returns (OfferFill memory) {
        return OfferFill(o, "", type(uint256).max);
    }

    function _fills(OfferFill memory a) internal pure returns (OfferFill[] memory f) {
        f = new OfferFill[](1);
        f[0] = a;
    }

    function _fills(OfferFill memory a, OfferFill memory b) internal pure returns (OfferFill[] memory f) {
        f = new OfferFill[](2);
        (f[0], f[1]) = (a, b);
    }

    function _fills(OfferFill memory a, OfferFill memory b, OfferFill memory c) internal pure returns (OfferFill[] memory f) {
        f = new OfferFill[](3);
        (f[0], f[1], f[2]) = (a, b, c);
    }

    // ========== ACTIONS ==========

    function _stage(bytes memory facilityData, OfferFill[] memory fills) internal {
        vm.prank(allocator);
        module.stageBorrow(facilityData, fills, block.timestamp + 1 hours);
    }

    function _pledge(bytes memory facilityData, uint256 amount) internal {
        vm.prank(allocator);
        box.pledge(module, facilityData, cbBtc, amount);
    }

    function _borrow(bytes memory facilityData, uint256 amount) internal {
        vm.prank(allocator);
        box.borrow(module, facilityData, usdc, amount);
    }

    function _repay(bytes memory facilityData, uint256 amount) internal {
        vm.prank(allocator);
        box.repay(module, facilityData, usdc, amount);
    }

    function _depledge(bytes memory facilityData, uint256 amount) internal {
        vm.prank(allocator);
        box.depledge(module, facilityData, cbBtc, amount);
    }

    /// @dev Stages one fresh bid at `tick` and borrows `amount` through the Box. Returns (proceeds at Box, units).
    function _stageAndBorrow(bytes memory facilityData, uint256 tick, uint256 amount) internal returns (uint256, uint256) {
        (Market memory m, , ) = abi.decode(facilityData, (Market, uint256, uint256));
        bytes32 group = keccak256(abi.encode(facilityData, block.timestamp, amount, tick));
        _stage(facilityData, _fills(_fill(_bidIn(m, lender, tick, group))));
        bytes32 marketId_ = IdLib.toId(m);
        uint256 boxBefore = usdc.balanceOf(address(box));
        uint256 debtBefore = midnight.debt(marketId_, address(module));
        _borrow(facilityData, amount);
        return (usdc.balanceOf(address(box)) - boxBefore, midnight.debt(marketId_, address(module)) - debtBefore);
    }

    /// @dev Pledges 5 cbBTC and borrows `amount` at TICK on the main facility
    function _open(uint256 amount) internal returns (uint256 proceeds, uint256 units) {
        _pledge(fd, 5e8);
        return _stageAndBorrow(fd, TICK, amount);
    }

    function _freshModule() internal returns (FundingMidnight m) {
        m = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.startPrank(address(box));
        m.addCollateralToken(cbBtc);
        m.addDebtToken(usdc);
        vm.stopPrank();
    }

    function _debt() internal view returns (uint256) {
        return midnight.debt(id, address(module));
    }

    function _coll() internal view returns (uint256) {
        return midnight.collateral(id, address(module), 0);
    }

    function _nav() internal view returns (uint256) {
        return module.nav(IOracleCallback(address(box)));
    }

    function _maxLtv() internal pure returns (uint256) {
        return (LLTV * LLTV_CAP) / 1e18;
    }
}

contract FundingMidnightTest is FundingMidnightFixture {
    using BoxLib for Box;

    // ========== VAL-MID-001: constructor ==========

    function testConstructorRejectsZeroOwner() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingMidnight(address(0), address(midnight), LLTV_CAP);
    }

    function testConstructorRejectsZeroMidnight() public {
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        new FundingMidnight(address(box), address(0), LLTV_CAP);
    }

    function testConstructorRejectsLltvCapOutOfRange() public {
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingMidnight(address(box), address(midnight), 0);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        new FundingMidnight(address(box), address(midnight), 1e18 + 1);
    }

    function testConstructorStoresArguments() public {
        FundingMidnight m = new FundingMidnight(address(box), address(midnight), 1e18);
        assertEq(m.owner(), address(box));
        assertEq(address(m.midnight()), address(midnight));
        assertEq(m.lltvCap(), 1e18);
        assertEq(m.facilitiesLength(), 0);
        assertEq(m.collateralTokensLength(), 0);
        assertEq(m.debtTokensLength(), 0);
    }

    // ========== VAL-MID-003: canonical facilityData ==========

    function testCanonicalFacilityDataRegisters() public {
        FundingMidnight m = _freshModule();
        Market memory mk = _market(M);
        assertEq(m.encodeFacilityData(mk, 0, MAX_APR), fd);
        vm.prank(address(box));
        m.addFacility(fd);
        assertTrue(m.isFacility(fd));
        assertEq(m.facilitiesLength(), 1);
        assertEq(m.facilities(0), fd);
        assertEq(m.facilityOfMarket(id), keccak256(fd));
        assertEq(m.marketId(fd), id);
    }

    function decodeExternal(bytes calldata data) external pure returns (Market memory, uint256, uint256) {
        return abi.decode(data, (Market, uint256, uint256));
    }

    function _assertRejected(FundingMidnight m, bytes memory data, bytes4 selector) internal {
        uint256 lengthBefore = m.facilitiesLength();
        vm.prank(address(box));
        if (selector == bytes4(0)) vm.expectRevert();
        else vm.expectRevert(selector);
        m.addFacility(data);
        assertEq(m.facilitiesLength(), lengthBefore, "nothing registered");
        assertFalse(m.isFacility(data));
    }

    function testNonCanonicalFacilityDataRejected() public {
        FundingMidnight m = _freshModule();

        // Trailing zero word
        _assertRejected(m, bytes.concat(fd, bytes32(0)), ErrorsLib.InvalidFacilityData.selector);

        // Market offset 0x80 instead of 0x60 (one padding word before the market): decodes to the same values
        bytes memory marketOffset = bytes.concat(bytes32(uint256(0x80)), _slice(fd, 32, 96), bytes32(0), _slice(fd, 96, fd.length));
        (Market memory d1, uint256 i1, uint256 a1) = this.decodeExternal(marketOffset);
        assertEq(IdLib.toId(d1), id);
        assertEq(i1, 0);
        assertEq(a1, MAX_APR);
        _assertRejected(m, marketOffset, ErrorsLib.InvalidFacilityData.selector);

        // collateralParams offset 0x120 instead of 0x100 inside the market: also decodes to the same values
        // Layout: [0,96) head, [96,352) market head (8 words, the 4th is the array offset), [352,..) array
        assertEq(uint256(bytes32(_slice(fd, 192, 224))), 0x100);
        bytes memory arrayOffset = bytes.concat(
            _slice(fd, 0, 192),
            bytes32(uint256(0x120)),
            _slice(fd, 224, 352),
            bytes32(0),
            _slice(fd, 352, fd.length)
        );
        (Market memory d2, , ) = this.decodeExternal(arrayOffset);
        assertEq(IdLib.toId(d2), id);
        _assertRejected(m, arrayOffset, ErrorsLib.InvalidFacilityData.selector);

        // Struct-wrapped encoding
        _assertRejected(m, abi.encode(WrappedFacility(_market(M), 0, MAX_APR)), bytes4(0));

        // Dirty high-order bits in the `midnight` address word (bytes [128,160))
        bytes memory dirty = bytes.concat(
            _slice(fd, 0, 128),
            bytes32(uint256(uint160(address(midnight))) | (1 << 200)),
            _slice(fd, 160, fd.length)
        );
        _assertRejected(m, dirty, bytes4(0));

        // Garbage
        _assertRejected(m, hex"00", bytes4(0));
        _assertRejected(m, "", bytes4(0));

        // The canonical bytes still register
        vm.prank(address(box));
        m.addFacility(fd);
        assertEq(m.facilitiesLength(), 1);
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = data[i];
    }

    // ========== VAL-MID-004: facility parameters ==========

    function testInvalidFacilityParametersRejected() public {
        FundingMidnight m = _freshModule();
        Market memory mk;

        mk = _market(M);
        mk.midnight = address(new MockMidnight());
        _assertRejected(m, _fd(mk, 0, MAX_APR), ErrorsLib.InvalidValue.selector);

        mk = _market(M);
        mk.chainId = block.chainid + 1;
        _assertRejected(m, _fd(mk, 0, MAX_APR), ErrorsLib.InvalidValue.selector);

        // Market never created on Midnight: rejected, and the module does not create it
        mk = _market(M + 1 days);
        bytes32 missing = IdLib.toId(mk);
        assertEq(midnight.tickSpacing(missing), 0);
        _assertRejected(m, _fd(mk, 0, MAX_APR), ErrorsLib.InvalidValue.selector);
        assertEq(midnight.tickSpacing(missing), 0, "market untouched");

        _assertRejected(m, _fd(_market(M), 1, MAX_APR), ErrorsLib.InvalidValue.selector);

        // Maturity now or in the past (markets created so only the maturity check can fail)
        mk = _market(block.timestamp);
        midnight.touchMarket(mk);
        _assertRejected(m, _fd(mk, 0, MAX_APR), ErrorsLib.InvalidValue.selector);
        mk = _market(block.timestamp - 1);
        midnight.touchMarket(mk);
        _assertRejected(m, _fd(mk, 0, MAX_APR), ErrorsLib.InvalidValue.selector);

        _assertRejected(m, _fd(_market(M), 0, 0), ErrorsLib.InvalidValue.selector);
        _assertRejected(m, _fd(_market(M), 0, 1e18 + 1), ErrorsLib.InvalidValue.selector);

        // Corrected facility registers
        vm.prank(address(box));
        m.addFacility(fd);
        assertTrue(m.isFacility(fd));
    }

    function testMaxBorrowAprOfOneIsAccepted() public {
        FundingMidnight m = _freshModule();
        bytes memory data = _fd(_market(M), 0, 1e18);
        vm.prank(address(box));
        m.addFacility(data);
        assertTrue(m.isFacility(data));
    }

    // ========== VAL-MID-005: facility tokens ==========

    function testFacilityTokensMustBeRegistered() public {
        (Market memory mk, uint256 cbIdx) = _market2(M);
        midnight.touchMarket(mk);
        bytes memory data = _fd(mk, cbIdx, MAX_APR);

        FundingMidnight onlyDebt = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.prank(address(box));
        onlyDebt.addDebtToken(usdc);
        _assertRejected(onlyDebt, data, ErrorsLib.TokenNotWhitelisted.selector);

        FundingMidnight onlyColl = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.prank(address(box));
        onlyColl.addCollateralToken(cbBtc);
        _assertRejected(onlyColl, data, ErrorsLib.TokenNotWhitelisted.selector);

        // The collateral registered is the one of the other index
        FundingMidnight otherIdx = new FundingMidnight(address(box), address(midnight), LLTV_CAP);
        vm.startPrank(address(box));
        otherIdx.addDebtToken(usdc);
        otherIdx.addCollateralToken(weth);
        vm.stopPrank();
        _assertRejected(otherIdx, data, ErrorsLib.TokenNotWhitelisted.selector);

        vm.startPrank(address(box));
        otherIdx.addCollateralToken(cbBtc);
        otherIdx.addFacility(data);
        vm.stopPrank();
        assertTrue(otherIdx.isFacility(data));
    }

    // ========== VAL-MID-006: one facility per market ==========

    function testOneFacilityPerMarket() public {
        // Same market, different maxBorrowApr
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(_fd(_market(M), 0, 0.1e18));

        // Same market, different collateral index
        (Market memory mk, uint256 cbIdx) = _market2(M);
        midnight.touchMarket(mk);
        vm.startPrank(address(box));
        module.addCollateralToken(weth);
        module.addFacility(_fd(mk, cbIdx, MAX_APR));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(_fd(mk, 1 - cbIdx, MAX_APR));
        vm.expectRevert(ErrorsLib.AlreadyWhitelisted.selector);
        module.addFacility(_fd(mk, 1 - cbIdx, 0.5e18));

        // Another maturity (another market id) is accepted
        module.addFacility(fd2);
        assertEq(module.facilitiesLength(), 3);

        // After removing the empty facility, the market can be used again
        module.removeFacility(fd);
        bytes memory again = _fd(_market(M), 0, 0.1e18);
        module.addFacility(again);
        vm.stopPrank();
        assertEq(module.facilityOfMarket(id), keccak256(again));
        assertEq(module.facilitiesLength(), 3);
    }

    // ========== VAL-MID-007: owner-only ==========

    function _ownerGatedCalls() internal view returns (bytes[] memory calls) {
        IERC20 c = IERC20(address(cbBtc));
        IERC20 d = IERC20(address(usdc));
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(FundingMidnight.addFacility, (fd2));
        calls[1] = abi.encodeCall(FundingMidnight.removeFacility, (fd));
        calls[2] = abi.encodeCall(IFunding.addCollateralToken, (IERC20(address(weth))));
        calls[3] = abi.encodeCall(IFunding.addDebtToken, (IERC20(address(weth))));
        calls[4] = abi.encodeCall(FundingMidnight.removeCollateralToken, (c));
        calls[5] = abi.encodeCall(FundingMidnight.removeDebtToken, (d));
        calls[6] = abi.encodeCall(FundingMidnight.pledge, (fd, c, 1e8));
        calls[7] = abi.encodeCall(FundingMidnight.depledge, (fd, c, 1e8));
        calls[8] = abi.encodeCall(FundingMidnight.borrow, (fd, d, 1_000e6));
        calls[9] = abi.encodeCall(FundingMidnight.repay, (fd, d, 1_000e6));
        calls[10] = abi.encodeWithSignature("skim(address)", address(usdc));
    }

    function testOnlyOwnerCanCallGatedFunctions() public {
        _open(10_000e6);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "spare"))));
        usdc.mint(address(module), 5_000e6);
        cbBtc.mint(address(module), 1e8);

        uint256 takes = midnight.takeCount();
        uint256 debtBefore = _debt();
        uint256 collBefore = _coll();
        address[3] memory callers = [allocator, curator, anyone];
        bytes[] memory calls = _ownerGatedCalls();
        bytes memory expected = abi.encodeWithSelector(ErrorsLib.OnlyOwner.selector);
        for (uint256 j; j < callers.length; j++) {
            for (uint256 i; i < calls.length; i++) {
                vm.prank(callers[j]);
                (bool ok, bytes memory ret) = address(module).call(calls[i]);
                assertFalse(ok);
                assertEq(ret, expected);
            }
        }
        assertEq(midnight.takeCount(), takes);
        assertEq(_debt(), debtBefore);
        assertEq(_coll(), collBefore);
        assertEq(module.facilitiesLength(), 1);
        assertEq(module.collateralTokensLength(), 1);
        assertEq(module.debtTokensLength(), 1);
        assertEq(usdc.balanceOf(address(module)), 5_000e6);
        assertEq(cbBtc.balanceOf(address(module)), 1e8);
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertGt(validUntil, 0, "staging untouched");
    }

    // ========== VAL-MID-008: stageBorrow ==========

    function testStageBorrowAccessAndValidation() public {
        OfferFill[] memory fills = _fills(_fill(_bid(lender, TICK, "a")));
        address[3] memory callers = [curator, guardian, anyone];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(ErrorsLib.OnlyAllocators.selector);
            module.stageBorrow(fd, fills, block.timestamp + 1);
        }

        vm.startPrank(allocator);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.stageBorrow(fd2, fills, block.timestamp + 1);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        module.stageBorrow(fd, fills, block.timestamp - 1);
        vm.stopPrank();

        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        assertEq(validUntil, 0);
        assertEq(staged.length, 0);
        (validUntil, ) = module.stagedBorrow(fd2);
        assertEq(validUntil, 0);

        vm.prank(allocator);
        module.stageBorrow(fd, fills, block.timestamp);
        (validUntil, staged) = module.stagedBorrow(fd);
        assertEq(validUntil, block.timestamp);
        assertEq(staged.length, 1);
        assertEq(keccak256(abi.encode(staged)), keccak256(abi.encode(fills)));
    }

    function testRestageReplacesPreviousFills() public {
        _pledge(fd, 5e8);
        Offer memory a = _bid(lender, TICK, "a");
        Offer memory b = _bid(lender2, TICK, "b");
        _stage(fd, _fills(_fill(a)));
        _stage(fd, _fills(_fill(b)));

        uint256 lenderBefore = usdc.balanceOf(lender);
        _borrow(fd, 10_000e6);
        assertEq(midnight.consumed(lender, "a"), 0, "lender A untouched");
        assertEq(usdc.balanceOf(lender), lenderBefore);
        assertGt(midnight.consumed(lender2, "b"), 0, "lender B taken");
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, TickLib.tickToPrice(TICK)));
    }

    // ========== VAL-MID-009: action tokens ==========

    function testActionTokensMustMatchFacility() public {
        // Another facility borrowing WETH against cbBTC makes WETH a registered module token
        Market memory wethMarket = _market(M);
        wethMarket.loanToken = address(weth);
        midnight.touchMarket(wethMarket);
        vm.startPrank(address(box));
        module.addDebtToken(weth);
        module.addFacility(_fd(wethMarket, 0, MAX_APR));
        vm.stopPrank();

        _open(10_000e6);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "spare"))));
        usdc.mint(address(module), 1_000e6);
        cbBtc.mint(address(module), 1e8);
        weth.mint(address(module), 1e18);

        uint256 takes = midnight.takeCount();
        uint256 debtBefore = _debt();
        uint256 collBefore = _coll();

        vm.startPrank(address(box));
        IERC20[3] memory notCollateral = [IERC20(address(usdc)), IERC20(address(weth)), IERC20(address(stranger))];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.pledge(fd, notCollateral[i], 1e6);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.depledge(fd, notCollateral[i], 1e6);
        }
        IERC20[3] memory notDebt = [IERC20(address(cbBtc)), IERC20(address(weth)), IERC20(address(stranger))];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.borrow(fd, notDebt[i], 1e6);
            vm.expectRevert(ErrorsLib.TokenNotWhitelisted.selector);
            module.repay(fd, notDebt[i], 1e6);
        }

        // Unregistered facilityData
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.pledge(fd2, cbBtc, 1e6);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.depledge(fd2, cbBtc, 1e6);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.borrow(fd2, usdc, 1e6);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.repay(fd2, usdc, 1e6);
        vm.stopPrank();

        assertEq(midnight.takeCount(), takes);
        assertEq(_debt(), debtBefore);
        assertEq(_coll(), collBefore);
        assertEq(midnight.collateral(id2, address(module), 0), 0);
        assertEq(usdc.balanceOf(address(module)), 1_000e6);
        assertEq(cbBtc.balanceOf(address(module)), 1e8);
        assertEq(weth.balanceOf(address(module)), 1e18);
    }

    // ========== VAL-MID-010: pledge ==========

    function testPledgeSuppliesExactlyTheCollateral() public {
        _pledge(fd, 2e8);
        assertEq(_coll(), 2e8);
        assertEq(cbBtc.balanceOf(address(module)), 0);
        assertEq(cbBtc.allowance(address(module), address(midnight)), 0);
        assertEq(module.collateralBalance(fd, cbBtc), 2e8);
        assertEq(module.collateralBalance(cbBtc), 2e8);
        assertEq(cbBtc.balanceOf(address(box)), 8e8);

        _pledge(fd, 1e8);
        assertEq(_coll(), 3e8);
        assertEq(module.collateralBalance(cbBtc), 3e8);
    }

    function testPledgeInTwoCollateralMarketUsesOnlyTheFacilityIndex() public {
        (Market memory mk, uint256 cbIdx) = _market2(M);
        bytes32 mkId = midnight.touchMarket(mk);
        FundingMidnight m = _freshModule();
        bytes memory data = _fd(mk, cbIdx, MAX_APR);
        vm.prank(address(box));
        m.addFacility(data);

        cbBtc.mint(address(m), 1e8);
        vm.prank(address(box));
        m.pledge(data, cbBtc, 1e8);
        assertEq(midnight.collateral(mkId, address(m), cbIdx), 1e8);
        assertEq(midnight.collateral(mkId, address(m), 1 - cbIdx), 0, "other index not activated");
        assertEq(m.collateralBalance(data, cbBtc), 1e8);
        assertEq(cbBtc.allowance(address(m), address(midnight)), 0);
    }

    // ========== VAL-MID-011: depledge ==========

    function testDepledgeDeliversToBox() public {
        _pledge(fd, 5e8);
        _depledge(fd, 1e8);
        assertEq(cbBtc.balanceOf(address(box)), 6e8);
        assertEq(cbBtc.balanceOf(address(module)), 0);
        assertEq(_coll(), 4e8);

        _depledge(fd, type(uint256).max);
        assertEq(cbBtc.balanceOf(address(box)), 10e8);
        assertEq(_coll(), 0);
        assertEq(module.collateralBalance(fd, cbBtc), 0);
    }

    function testDepledgeAboveBalanceReverts() public {
        _pledge(fd, 5e8);
        vm.prank(address(box));
        vm.expectRevert(stdError.arithmeticError);
        module.depledge(fd, cbBtc, 5e8 + 1);
        assertEq(_coll(), 5e8);
    }

    function testDepledgeGuard() public {
        _open(100_000e6);
        // Leaving 1.5 cbBTC: ltv 0.803 > 0.774 (guard) while Midnight still sees the position healthy (<= 0.86)
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, fd, cbBtc, 3.5e8);
        assertEq(_coll(), 5e8);

        _depledge(fd, 3e8);
        assertEq(_coll(), 2e8);
        assertLe(module.ltv(fd), _maxLtv());
    }

    function testDepledgeGuardAppliesInWinddown() public {
        _open(100_000e6);
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown());

        vm.prank(anyone);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.depledge(module, fd, cbBtc, 3.5e8);

        vm.prank(anyone);
        box.depledge(module, fd, cbBtc, 3e8);
        assertEq(_coll(), 2e8);
        assertEq(cbBtc.balanceOf(address(box)), 8e8);
    }

    // ========== VAL-MID-012: staging required and consumed ==========

    function testBorrowWithoutStagingReverts() public {
        _pledge(fd, 5e8);
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NoValidStaging.selector);
        box.borrow(module, fd, usdc, 1_000e6);
        assertEq(midnight.takeCount(), 0);
    }

    function testBorrowWithExpiredStagingReverts() public {
        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "a"))));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NoValidStaging.selector);
        box.borrow(module, fd, usdc, 1_000e6);
        assertEq(midnight.takeCount(), 0);
    }

    function testBorrowAtValidUntilWorks() public {
        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "a"))));
        vm.warp(block.timestamp + 1 hours);
        _borrow(fd, 1_000e6);
        assertGt(_debt(), 0);
    }

    function testBorrowConsumesStaging() public {
        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "a")), _fill(_bid(lender, TICK, "b"))));
        _borrow(fd, 1_000e6);
        assertEq(midnight.consumed(lender, "b"), 0, "second fill not needed");
        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        assertEq(validUntil, 0);
        assertEq(staged.length, 0);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NoValidStaging.selector);
        box.borrow(module, fd, usdc, 1_000e6);
    }

    function testStagingIsPerFacility() public {
        vm.prank(curator);
        box.addFundingFacilityInstant(module, fd2);
        _pledge(fd, 5e8);
        _pledge(fd2, 5e8);
        OfferFill[] memory fillsA = _fills(_fill(_bidIn(_market(M2), lender, TICK, "for-b")));
        _stage(fd, fillsA);

        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.NoValidStaging.selector);
        box.borrow(module, fd2, usdc, 1_000e6);
        assertEq(midnight.takeCount(), 0);
        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        assertGt(validUntil, 0, "facility A staging intact");
        assertEq(keccak256(abi.encode(staged)), keccak256(abi.encode(fillsA)));
    }

    // ========== VAL-MID-013: non-bids and other markets are skipped ==========

    function testNonBidsAndOtherMarketsAreSkipped() public {
        // Collateral in the other-maturity market, so Midnight itself would accept a take there: only the module's
        // market check keeps that bid out of this facility's borrow
        vm.prank(curator);
        box.addFundingFacilityInstant(module, fd2);
        _pledge(fd2, 2e8);
        _pledge(fd, 5e8);
        Offer memory sell = _bid(lender, TICK, "sell");
        sell.buy = false;
        ratifier.setOfferRatified(sell, true);
        Offer memory otherMaturity = _bidIn(_market(M2), lender, TICK, "other-maturity");
        (Market memory twoColl, ) = _market2(M);
        midnight.touchMarket(twoColl);
        Offer memory otherCollaterals = _bidIn(twoColl, lender, TICK, "other-collaterals");
        Offer memory valid = _bid(lender2, TICK, "valid");

        OfferFill[] memory fills = new OfferFill[](4);
        fills[0] = _fill(sell);
        fills[1] = _fill(otherMaturity);
        fills[2] = _fill(otherCollaterals);
        fills[3] = _fill(valid);
        _stage(fd, fills);
        _borrow(fd, 10_000e6);

        assertEq(midnight.consumed(lender, "sell"), 0);
        assertEq(midnight.consumed(lender, "other-maturity"), 0);
        assertEq(midnight.consumed(lender, "other-collaterals"), 0);
        assertEq(midnight.debt(id2, address(module)), 0);
        assertEq(midnight.debt(IdLib.toId(twoColl), address(module)), 0);
        assertGt(midnight.consumed(lender2, "valid"), 0);
        assertEq(midnight.takeCount(), 1);
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, TickLib.tickToPrice(TICK)));
    }

    function testOnlyInvalidFillsReverts() public {
        _pledge(fd, 5e8);
        Offer memory sell = _bid(lender, TICK, "sell");
        sell.buy = false;
        _stage(fd, _fills(_fill(sell), _fill(_bidIn(_market(M2), lender, TICK, "other"))));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        box.borrow(module, fd, usdc, 1_000e6);
        assertEq(_debt(), 0);
    }

    // ========== VAL-MID-014: APR floor ==========

    function _pMin() internal view returns (uint256) {
        uint256 ttm = M - block.timestamp;
        return Math.mulDiv(1e36, 1, 1e18 + (MAX_APR * ttm) / 365 days, Math.Rounding.Ceil);
    }

    /// @dev Lowest accessible tick whose price is at or above the floor
    function _floorTick(uint256 floor) internal pure returns (uint256 tick) {
        for (tick = 4000; TickLib.tickToPrice(tick) < floor; tick += 4) {}
    }

    function testAprFloorMatchesLibraryValue() public view {
        assertEq(_pMin(), 980113811502020464);
        assertEq(MidnightMathLib.minSellerPrice(MAX_APR, M - block.timestamp), _pMin());
    }

    function testBidsBelowFloorAreSkipped() public {
        uint256 pMin = _pMin();
        uint256 hi = _floorTick(pMin);
        uint256 lo = hi - 4;
        assertLt(TickLib.tickToPrice(lo), pMin);
        assertGe(TickLib.tickToPrice(hi), pMin);

        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, lo, "lo")), _fill(_bid(lender, hi, "hi"))));
        _borrow(fd, 10_000e6);
        assertEq(midnight.consumed(lender, "lo"), 0, "below floor skipped");
        assertGt(midnight.consumed(lender, "hi"), 0, "at or above floor taken");
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, TickLib.tickToPrice(hi)));
    }

    function testSettlementFeePushesBidBelowFloor() public {
        uint256 pMin = _pMin();
        uint256 hi = _floorTick(pMin);
        uint256 hiPrice = TickLib.tickToPrice(hi);
        _pledge(fd, 5e8);
        uint256 snap = vm.snapshotState();

        // Seller price exactly at the floor: taken
        midnight.setSettlementFee(id, hiPrice - pMin);
        _stage(fd, _fills(_fill(_bid(lender, hi, "hi")), _fill(_bid(lender, HIGH_TICK, "backup"))));
        _borrow(fd, 10_000e6);
        assertGt(midnight.consumed(lender, "hi"), 0);
        assertEq(midnight.consumed(lender, "backup"), 0);
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, pMin));

        // One wei of fee more: skipped, the backup bid is used
        vm.revertToState(snap);
        midnight.setSettlementFee(id, hiPrice - pMin + 1);
        _stage(fd, _fills(_fill(_bid(lender, hi, "hi")), _fill(_bid(lender, HIGH_TICK, "backup"))));
        uint256 boxBefore = usdc.balanceOf(address(box));
        _borrow(fd, 10_000e6);
        assertEq(midnight.consumed(lender, "hi"), 0, "net price below floor skipped");
        assertGt(midnight.consumed(lender, "backup"), 0);
        uint256 backupSellerPrice = TickLib.tickToPrice(HIGH_TICK) - (hiPrice - pMin + 1);
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, backupSellerPrice));
        assertGe(usdc.balanceOf(address(box)) - boxBefore, 10_000e6);
    }

    function testMalformedBidsAreSkipped() public {
        midnight.setSettlementFee(id, 1e15);
        _pledge(fd, 5e8);
        Offer memory tooHigh = _bid(lender, TickLib.MAX_TICK + 4, "too-high");
        Offer memory zero = _bid(lender, 0, "zero");
        Offer memory feeAbovePrice = _bid(lender, 1000, "fee-above-price");
        assertLe(TickLib.tickToPrice(1000), 1e15);
        Offer memory valid = _bid(lender, HIGH_TICK, "valid");

        OfferFill[] memory fills = new OfferFill[](4);
        fills[0] = _fill(tooHigh);
        fills[1] = _fill(zero);
        fills[2] = _fill(feeAbovePrice);
        fills[3] = _fill(valid);
        _stage(fd, fills);
        _borrow(fd, 10_000e6);

        assertEq(midnight.consumed(lender, "too-high"), 0);
        assertEq(midnight.consumed(lender, "zero"), 0);
        assertEq(midnight.consumed(lender, "fee-above-price"), 0);
        assertGt(midnight.consumed(lender, "valid"), 0);
        assertEq(midnight.takeCount(), 1);
    }

    // ========== VAL-MID-015: failing takes are skipped ==========

    function _assertFailingFillSkipped(OfferFill memory bad) internal {
        address maker = bad.offer.maker;
        bytes32 group = bad.offer.group;
        uint256 consumedBefore = midnight.consumed(maker, group);
        uint256 makerBefore = usdc.balanceOf(maker);
        uint256 boxBefore = usdc.balanceOf(address(box));

        _pledge(fd, 5e8);
        _stage(fd, _fills(bad, _fill(_bid(lender2, TICK, "good"))));
        _borrow(fd, 10_000e6);

        assertEq(midnight.consumed(maker, group), consumedBefore, "failing maker untouched");
        assertEq(usdc.balanceOf(maker), makerBefore);
        assertGe(usdc.balanceOf(address(box)) - boxBefore, 10_000e6);
        assertEq(_debt(), MidnightMathLib.unitsForSellerAssets(10_000e6, TickLib.tickToPrice(TICK)));
        assertEq(midnight.takeCount(), 1);
    }

    function testExpiredOfferSkipped() public {
        Offer memory o = _bid(lender, TICK, "expired");
        o.start = block.timestamp - 2 hours;
        o.expiry = block.timestamp - 1;
        ratifier.setOfferRatified(o, true);
        _assertFailingFillSkipped(_fill(o));
    }

    function testUnratifiedOfferSkipped() public {
        Offer memory o = _bid(lender, TICK, "unratified");
        ratifier.setOfferRatified(o, false);
        _assertFailingFillSkipped(_fill(o));
    }

    function testCancelledGroupSkipped() public {
        Offer memory o = _bid(lender, TICK, "cancelled");
        vm.prank(lender);
        midnight.setConsumed("cancelled", type(uint128).max, lender);
        _assertFailingFillSkipped(_fill(o));
    }

    function testInvalidRatifierDataSkipped() public {
        DataRatifier dataRatifier = new DataRatifier();
        vm.prank(lender);
        midnight.setIsAuthorized(address(dataRatifier), true, lender);
        Offer memory o = _bid(lender, TICK, "bad-data");
        o.ratifier = address(dataRatifier);
        _assertFailingFillSkipped(OfferFill(o, "bad", type(uint256).max));
    }

    function testRatifierWrongAnswerSkipped() public {
        MockMidnightRatifier wrong = new MockMidnightRatifier();
        wrong.setAcceptAll(true);
        wrong.setReturnWrongValue(true);
        vm.prank(lender);
        midnight.setIsAuthorized(address(wrong), true, lender);
        Offer memory o = _bid(lender, TICK, "wrong-answer");
        o.ratifier = address(wrong);
        _assertFailingFillSkipped(_fill(o));
    }

    function testMakerWithoutFundsSkipped() public {
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        usdc.approve(address(midnight), type(uint256).max);
        midnight.setIsAuthorized(address(ratifier), true, poor);
        vm.stopPrank();
        _assertFailingFillSkipped(_fill(_bid(poor, TICK, "no-funds")));
    }

    function testMakerWithoutAllowanceSkipped() public {
        address stingy = makeAddr("stingy");
        usdc.mint(stingy, 1_000_000e6);
        vm.prank(stingy);
        midnight.setIsAuthorized(address(ratifier), true, stingy);
        _assertFailingFillSkipped(_fill(_bid(stingy, TICK, "no-allowance")));
    }

    function testRevertingMakerCallbackSkipped() public {
        Offer memory o = _bid(lender, TICK, "forced");
        midnight.setForcedTakeRevert(o, true);
        _assertFailingFillSkipped(_fill(o));
    }

    // ========== VAL-MID-016: delivery ==========

    function testBorrowSendsProceedsStraightToBox() public {
        _pledge(fd, 5e8);
        Offer memory o = _bid(lender, TICK, "a");
        _stage(fd, _fills(_fill(o)));
        uint256 units = MidnightMathLib.unitsForSellerAssets(10_000e6, TickLib.tickToPrice(TICK));
        vm.expectCall(
            address(midnight),
            abi.encodeCall(IMidnight.take, (o, bytes(""), units, address(module), address(box), address(0), bytes("")))
        );
        uint256 boxBefore = usdc.balanceOf(address(box));
        _borrow(fd, 10_000e6);
        uint256 received = usdc.balanceOf(address(box)) - boxBefore;
        assertGe(received, 10_000e6);
        assertLe(received, 10_000e6 + 1);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(_debt(), units);
        assertEq(module.debtBalance(fd, usdc), units);
    }

    function testBorrowRespectsFillCaps() public {
        _pledge(fd, 5e8);
        uint256 price = TickLib.tickToPrice(TICK);
        OfferFill memory skipped = OfferFill(_bid(lender, TICK, "g0"), "", 0);
        OfferFill memory capped = OfferFill(_bid(lender, TICK, "g1"), "", 3_000e6);
        OfferFill memory rest = _fill(_bid(lender, TICK, "g2"));
        OfferFill memory untouched = _fill(_bid(lender, TICK, "g3"));
        OfferFill[] memory fills = new OfferFill[](4);
        (fills[0], fills[1], fills[2], fills[3]) = (skipped, capped, rest, untouched);
        _stage(fd, fills);

        uint256 boxBefore = usdc.balanceOf(address(box));
        _borrow(fd, 10_000e6);

        uint256 firstProceeds = MidnightMathLib.sellerAssetsOf(3_000e6, price);
        uint256 restUnits = MidnightMathLib.unitsForSellerAssets(10_000e6 - firstProceeds, price);
        assertEq(midnight.consumed(lender, "g0"), 0, "maxUnits 0 skipped");
        assertEq(midnight.consumed(lender, "g1"), firstProceeds, "exactly maxUnits sold (buyer assets consumed)");
        assertEq(midnight.consumed(lender, "g2"), MidnightMathLib.sellerAssetsOf(restUnits, price));
        assertEq(midnight.consumed(lender, "g3"), 0, "fills after completion untouched");
        assertEq(_debt(), 3_000e6 + restUnits);
        uint256 received = usdc.balanceOf(address(box)) - boxBefore;
        assertGe(received, 10_000e6);
        assertLe(received, 10_000e6 + 2);
        assertEq(usdc.balanceOf(address(module)), 0);
    }

    function testBorrowCappedByOfferUnitsCapacity() public {
        _pledge(fd, 5e8);
        Offer memory small = _bid(lender, TICK, "small");
        small.maxAssets = 0;
        small.maxUnits = 2_000e6;
        ratifier.setOfferRatified(small, true);
        _stage(fd, _fills(_fill(small), _fill(_bid(lender, TICK, "rest"))));
        _borrow(fd, 10_000e6);
        assertEq(midnight.consumed(lender, "small"), 2_000e6, "offer drained to its unit cap");
        assertGt(midnight.consumed(lender, "rest"), 0);
    }

    function testShortFillReverts() public {
        _pledge(fd, 5e8);
        OfferFill[] memory fills = _fills(OfferFill(_bid(lender, TICK, "a"), "", 1_000e6), OfferFill(_bid(lender, TICK, "b"), "", 1_000e6));
        _stage(fd, fills);
        uint256 boxBefore = usdc.balanceOf(address(box));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InsufficientLiquidity.selector);
        box.borrow(module, fd, usdc, 10_000e6);
        assertEq(_debt(), 0);
        assertEq(usdc.balanceOf(address(box)), boxBefore);
        assertEq(midnight.consumed(lender, "a"), 0);
        (uint256 validUntil, ) = module.stagedBorrow(fd);
        assertGt(validUntil, 0, "revert keeps the staging");
    }

    function testBorrowMaxAmountReverts() public {
        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "a"))));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        box.borrow(module, fd, usdc, type(uint256).max);
        assertEq(midnight.takeCount(), 0);
    }

    // ========== VAL-MID-017: guard after borrow ==========

    function testBorrowGuard() public {
        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "a"))));
        // face ~335k: within Midnight's 0.86 LLTV (362k) but above the 0.774 guard (326k)
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.ExcessiveLTV.selector);
        box.borrow(module, fd, usdc, 330_000e6);
        assertEq(_debt(), 0);

        _borrow(fd, 300_000e6);
        assertLe(module.ltv(fd), _maxLtv());
        assertGt(module.ltv(fd), 0.7e18);
    }

    // ========== VAL-MID-018: repay ==========

    function testPartialRepay() public {
        (, uint256 units) = _open(100_000e6);
        uint256 boxBefore = usdc.balanceOf(address(box));
        _repay(fd, 30_000e6);
        assertEq(_debt(), units - 30_000e6);
        assertEq(usdc.balanceOf(address(box)), boxBefore - 30_000e6);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(usdc.allowance(address(module), address(midnight)), 0);
    }

    function testRepayMaxClosesExactly() public {
        (, uint256 units) = _open(100_000e6);
        uint256 boxBefore = usdc.balanceOf(address(box));
        _repay(fd, type(uint256).max);
        assertEq(_debt(), 0);
        assertEq(usdc.balanceOf(address(box)), boxBefore - units);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(usdc.allowance(address(module), address(midnight)), 0);
        assertEq(module.debtBalance(usdc), 0);
    }

    function testRepayAboveFaceRefundsOwner() public {
        (, uint256 units) = _open(100_000e6);
        usdc.mint(address(module), units + 777);
        uint256 boxBefore = usdc.balanceOf(address(box));
        vm.prank(address(box));
        module.repay(fd, usdc, units + 777);
        assertEq(_debt(), 0);
        assertEq(usdc.balanceOf(address(box)), boxBefore + 777);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(usdc.allowance(address(module), address(midnight)), 0);
    }

    function testRepayWithoutDebtRefundsEverything() public {
        usdc.mint(address(module), 500e6);
        uint256 boxBefore = usdc.balanceOf(address(box));
        vm.prank(address(box));
        module.repay(fd, usdc, 500e6);
        assertEq(usdc.balanceOf(address(box)), boxBefore + 500e6);
        assertEq(usdc.balanceOf(address(module)), 0);
    }

    // ========== VAL-MID-019: staging never affects repay/depledge ==========

    function _repayDepledgeOutcome() internal returns (uint256[4] memory out) {
        _repay(fd, 20_000e6);
        _depledge(fd, 1e8);
        out = [_debt(), _coll(), usdc.balanceOf(address(box)), cbBtc.balanceOf(address(box))];
    }

    function testRepayAndDepledgeIgnoreStaging() public {
        _open(100_000e6);
        uint256 snap = vm.snapshotState();
        uint256[4] memory baseline = _repayDepledgeOutcome();

        for (uint256 state = 1; state <= 3; state++) {
            vm.revertToState(snap);
            if (state == 1) {
                // Stale
                _stage(fd, _fills(_fill(_bid(lender, TICK, "stale"))));
                vm.warp(block.timestamp + 2 hours);
            } else if (state == 2) {
                // Garbage
                Offer memory sell = _bid(lender, TICK, "sell");
                sell.buy = false;
                _stage(
                    fd,
                    _fills(_fill(sell), _fill(_bidIn(_market(M2), lender, TICK, "other")), OfferFill(_bid(lender, 0, "z"), "junk", 1))
                );
            } else {
                // Fresh and unused
                _stage(fd, _fills(_fill(_bid(lender, TICK, "fresh"))));
            }
            (uint256 validUntil, OfferFill[] memory before) = module.stagedBorrow(fd);
            uint256[4] memory out = _repayDepledgeOutcome();
            for (uint256 k; k < 4; k++) assertEq(out[k], baseline[k]);
            (uint256 validUntilAfter, OfferFill[] memory afterFills) = module.stagedBorrow(fd);
            assertEq(validUntilAfter, validUntil, "staging untouched");
            assertEq(keccak256(abi.encode(afterFills)), keccak256(abi.encode(before)));
        }
    }

    function testWinddownCloseByAnyone() public {
        _open(100_000e6);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "left-over"))));
        vm.prank(guardian);
        box.shutdown();
        vm.warp(block.timestamp + box.shutdownWarmup() + 1);
        assertTrue(box.isWinddown());
        assertFalse(box.isAllocator(anyone));

        vm.startPrank(anyone);
        box.repay(module, fd, usdc, type(uint256).max);
        box.depledge(module, fd, cbBtc, type(uint256).max);
        vm.stopPrank();
        assertEq(_debt(), 0);
        assertEq(_coll(), 0);
        assertEq(cbBtc.balanceOf(address(box)), 10e8);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(_nav(), 0);
    }

    // ========== VAL-MID-020: debtBalance is face; aggregation ==========

    function testDebtBalanceIsFaceAndAggregates() public {
        vm.prank(curator);
        box.addFundingFacilityInstant(module, fd2);
        _open(100_000e6);
        _pledge(fd2, 3e8);
        _stageAndBorrow(fd2, FD2_TICK, 40_000e6);
        _assertBalancesMatchMidnight();
        assertGt(module.debtBalance(fd, usdc), module.debtValue(fd), "face, not the accreted value");

        vm.warp(block.timestamp + 10 days);
        _assertBalancesMatchMidnight();

        _repay(fd, 25_000e6);
        _assertBalancesMatchMidnight();

        midnight.reduceDebt(id2, address(module), 5_000e6);
        _assertBalancesMatchMidnight();
    }

    function _assertBalancesMatchMidnight() internal view {
        uint256 face1 = midnight.debt(id, address(module));
        uint256 face2 = midnight.debt(id2, address(module));
        assertEq(module.debtBalance(fd, usdc), face1);
        assertEq(module.debtBalance(fd2, usdc), face2);
        assertEq(module.debtBalance(usdc), face1 + face2);
        uint256 coll1 = midnight.collateral(id, address(module), 0);
        uint256 coll2 = midnight.collateral(id2, address(module), 0);
        assertEq(module.collateralBalance(fd, cbBtc), coll1);
        assertEq(module.collateralBalance(fd2, cbBtc), coll2);
        assertEq(module.collateralBalance(cbBtc), coll1 + coll2);
    }

    // ========== VAL-MID-021: unknown tokens and facilityData ==========

    function testUnknownTokensAndFacilitiesReadZero() public {
        _open(100_000e6);
        vm.prank(address(box));
        module.addCollateralToken(weth);

        assertEq(module.debtBalance(stranger), 0);
        assertEq(module.collateralBalance(stranger), 0);
        assertEq(module.debtBalance(cbBtc), 0);
        assertEq(module.collateralBalance(usdc), 0);
        assertEq(module.collateralBalance(weth), 0);
        assertEq(module.debtBalance(fd, stranger), 0);
        assertEq(module.collateralBalance(fd, stranger), 0);
        assertEq(module.debtBalance(fd, cbBtc), 0);
        assertEq(module.collateralBalance(fd, usdc), 0);
        assertEq(module.collateralBalance(fd, weth), 0);

        bytes memory other = fd2;
        bytes[3] memory unregistered = [other, bytes(hex"00"), bytes(hex"deadbeefcafe0123456789")];
        for (uint256 i; i < 3; i++) {
            assertEq(module.debtBalance(unregistered[i], usdc), 0);
            assertEq(module.collateralBalance(unregistered[i], cbBtc), 0);
            assertEq(module.ltv(unregistered[i]), 0);
            assertEq(module.debtValue(unregistered[i]), 0);
        }
    }

    // ========== VAL-MID-022: ltv ==========

    function testLtvZeroWithoutDebtEvenIfOracleReverts() public {
        assertEq(module.ltv(fd), 0);
        _pledge(fd, 5e8);
        cbBtcMidnightOracle.setReverts(true);
        assertEq(module.ltv(fd), 0);
    }

    function testLtvFormulaAndOracleSource() public {
        _open(100_000e6);
        uint256 face = _debt();
        uint256 expected = Math.mulDiv(face, 1e18, Math.mulDiv(5e8, CBBTC_PRICE, 1e36), Math.Rounding.Ceil);
        assertEq(module.ltv(fd), expected);

        boxCbBtcOracle.setPrice(CBBTC_PRICE / 2);
        assertEq(module.ltv(fd), expected, "Box oracle not used");

        uint256 newPrice = (CBBTC_PRICE * 3) / 4;
        cbBtcMidnightOracle.setPrice(newPrice);
        assertEq(module.ltv(fd), Math.mulDiv(face, 1e18, Math.mulDiv(5e8, newPrice, 1e36), Math.Rounding.Ceil));
    }

    function testLtvMaxWhenCollateralValueZero() public {
        _open(100_000e6);
        cbBtcMidnightOracle.setPrice(0);
        assertEq(module.ltv(fd), type(uint256).max);
    }

    /// @dev Liquidates all the collateral of the main facility while debt remains (price crash)
    function _liquidateAllCollateral() internal {
        cbBtcMidnightOracle.setPrice(CBBTC_PRICE / 10);
        address liquidator = makeAddr("liquidator");
        usdc.mint(liquidator, 1_000_000e6);
        vm.startPrank(liquidator);
        usdc.approve(address(midnight), type(uint256).max);
        midnight.liquidate(_market(M), 0, _coll(), 0, address(module), false, liquidator, address(0), "");
        vm.stopPrank();
        cbBtcMidnightOracle.setPrice(CBBTC_PRICE);
    }

    function testLtvMaxWhenNoCollateral() public {
        _open(100_000e6);
        _liquidateAllCollateral();
        assertEq(_coll(), 0);
        assertGt(_debt(), 0);
        assertEq(module.ltv(fd), type(uint256).max);
    }

    // ========== VAL-MID-023: maturity ==========

    function testMaturityViews() public {
        assertEq(module.maturity(fd), M);
        vm.warp(M - 1);
        assertFalse(module.isMatured(fd));
        vm.warp(M);
        assertTrue(module.isMatured(fd));
        vm.warp(M + 1);
        assertTrue(module.isMatured(fd));
    }

    function testBorrowClosedAtMaturity() public {
        _pledge(fd, 5e8);
        Offer memory o = _bid(lender, TICK, "a");

        vm.warp(M);
        _stage(fd, _fills(_fill(o)));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.FacilityMatured.selector);
        box.borrow(module, fd, usdc, 1_000e6);

        vm.warp(M + 1);
        _stage(fd, _fills(_fill(o)));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.FacilityMatured.selector);
        box.borrow(module, fd, usdc, 1_000e6);
        assertEq(midnight.takeCount(), 0);
        assertEq(_debt(), 0);
    }

    function testMockAllowsBorrowAtMaturityButModuleRefuses() public {
        address other = makeAddr("otherBorrower");
        cbBtc.mint(other, 1e8);
        vm.startPrank(other);
        cbBtc.approve(address(midnight), 1e8);
        midnight.supplyCollateral(_market(M), 0, 1e8, other);
        vm.stopPrank();
        Offer memory o = _bid(lender, TICK, "a");

        vm.warp(M);
        vm.prank(other);
        midnight.take(o, "", 1_000e6, other, other, address(0), "");
        assertEq(midnight.debt(id, other), 1_000e6, "Midnight still allows it at maturity");

        _pledge(fd, 5e8);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "b"))));
        vm.prank(allocator);
        vm.expectRevert(ErrorsLib.FacilityMatured.selector);
        box.borrow(module, fd, usdc, 1_000e6);
    }

    function testBorrowOneSecondBeforeMaturity() public {
        _pledge(fd, 5e8);
        Offer memory o = _bidIn(_market(M), lender, 6744, "par");
        vm.warp(M - 1);
        _stage(fd, _fills(_fill(o)));
        _borrow(fd, 1_000e6);
        assertEq(_debt(), 1_000e6, "par price");
        assertEq(module.debtValue(fd), 1_000e6);
    }

    // ========== VAL-MID-024: nav ==========

    function testNavValuation() public {
        _open(100_000e6);
        uint256 collValue = Math.mulDiv(5e8, CBBTC_PRICE, 1e36);
        assertEq(_nav(), collValue - module.debtValue(fd), "Box asset debt 1:1");

        // Non-asset loan token: debt valued with the Box oracle, rounded up
        MockOracleProvider provider = new MockOracleProvider(address(stranger));
        MockOracle usdcOracle = new MockOracle(1.0003e36 + 7);
        MockOracle collOracle = new MockOracle(CBBTC_PRICE + 13);
        provider.setOracle(usdc, usdcOracle);
        provider.setOracle(cbBtc, collOracle);
        uint256 expected = Math.mulDiv(5e8, CBBTC_PRICE + 13, 1e36) -
            Math.mulDiv(module.debtValue(fd), 1.0003e36 + 7, 1e36, Math.Rounding.Ceil);
        assertEq(module.nav(provider), expected);

        // Midnight oracles are never called
        uint256 navBefore = _nav();
        cbBtcMidnightOracle.setReverts(true);
        assertEq(_nav(), navBefore);
        box.totalAssets();
    }

    function testNavExcludesIdleBalancesAndSkim() public {
        _open(100_000e6);
        uint256 navBefore = _nav();
        uint256 totalBefore = box.totalAssets();
        usdc.mint(address(module), 1_234e6);
        cbBtc.mint(address(module), 1e8);
        assertEq(_nav(), navBefore);

        uint256 boxCbBtc = cbBtc.balanceOf(address(box));
        vm.startPrank(allocator);
        box.skimFunding(module, cbBtc);
        box.skimFunding(module, usdc);
        vm.stopPrank();
        assertEq(cbBtc.balanceOf(address(box)), boxCbBtc + 1e8);
        assertEq(cbBtc.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(_nav(), navBefore);
        assertEq(box.totalAssets(), totalBefore + 1_234e6 + Math.mulDiv(1e8, CBBTC_PRICE, 1e36));
    }

    function testNavFloorsEachFacilityAtZero() public {
        vm.prank(curator);
        box.addFundingFacilityInstant(module, fd2);
        _pledge(fd, 5e8);
        _stageAndBorrow(fd, TICK, 10_000e6);
        _pledge(fd2, 1e8);
        _stageAndBorrow(fd2, FD2_TICK, 60_000e6);

        boxCbBtcOracle.setPrice(CBBTC_PRICE / 2);
        uint256 v1 = Math.mulDiv(5e8, CBBTC_PRICE / 2, 1e36) - module.debtValue(fd);
        assertGt(module.debtValue(fd2), Math.mulDiv(1e8, CBBTC_PRICE / 2, 1e36), "facility 2 underwater");
        assertEq(_nav(), v1, "underwater facility contributes 0");
    }

    // ========== VAL-MID-025: accretion at borrow time ==========

    function testBorrowKeepsNavUnchanged() public {
        uint256 totalBefore = box.totalAssets();
        (uint256 proceeds, uint256 units) = _open(100_000e6);
        uint256 dv = module.debtValue(fd);
        assertGe(dv, proceeds);
        assertLe(dv, proceeds + 2, "at most 2 wei above the proceeds");
        assertLe(dv, units);
        assertApproxEqAbs(box.totalAssets(), totalBefore, 2, "pledge + borrow moves totalAssets by rounding only");
        assertLe(box.totalAssets(), totalBefore);

        vm.warp(block.timestamp + 20 days);
        uint256 dvBefore = module.debtValue(fd);
        (uint256 proceeds2, uint256 units2) = _stageAndBorrow(fd, HIGH_TICK, 50_000e6);
        assertGt(units2, proceeds2);
        assertApproxEqAbs(module.debtValue(fd), dvBefore + proceeds2, 2, "second borrow adds its proceeds, not its units");
        assertGe(module.debtValue(fd), dvBefore + proceeds2);
    }

    // ========== VAL-MID-026: accretion over time ==========

    function testAccretionIsLinearAndReachesFace() public {
        (uint256 proceeds, uint256 units) = _open(100_000e6);
        uint256 half = block.timestamp + (M - block.timestamp) / 2;
        uint256 last = module.debtValue(fd);
        for (uint256 t = block.timestamp + 1 days; t < M; t += 7 days) {
            vm.warp(t);
            uint256 v = module.debtValue(fd);
            assertGe(v, last, "non-decreasing");
            last = v;
        }
        vm.warp(half);
        uint256 term = M - T1;
        assertApproxEqAbs(module.debtValue(fd), units - Math.mulDiv(units - proceeds, M - half, term), 2, "linear schedule");
        // The term is an odd number of seconds: `half` is half a second short of mid-term (discount ~189 wei/s)
        assertApproxEqAbs(module.debtValue(fd), proceeds + (units - proceeds) / 2, (units - proceeds) / term + 2);
        vm.warp(M);
        assertEq(module.debtValue(fd), units);
        vm.warp(M + 365 days);
        assertEq(module.debtValue(fd), units);
        assertEq(_nav(), Math.mulDiv(5e8, CBBTC_PRICE, 1e36) - units);
    }

    /// @dev The worked example of the Midnight library notes (exact integers, 6-decimal USDC)
    function testAccretionWorkedExample() public {
        _pledge(fd, 5e8);
        (uint256 p1, uint256 u1) = _stageAndBorrow(fd, TICK, 100_000e6);
        assertEq(u1, 101_515_329_475);
        assertEq(p1, 100_000_000_000);
        assertEq(module.debtValue(fd), 100_000_000_001);
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, u1);
        assertEq(rate, 189_459_073_172_689_467_578);

        vm.warp(T1 + 30 days);
        assertEq(module.debtValue(fd), 100_491_077_918);
        (uint256 p2, uint256 u2) = _stageAndBorrow(fd, 4240, 50_000e6);
        assertEq(u2, 50_658_935_978);
        assertEq(p2, 50_000_000_000);
        assertEq(module.debtValue(fd), 150_491_077_918);
        (tracked, rate) = module.accretionState(fd);
        assertEq(tracked, 152_174_265_453);
        assertEq(rate, 311_344_559_973_095_446_725);

        // Sum of the two linear schedules
        vm.warp(T1 + 45 days);
        uint256 d1 = Math.mulDiv(u1 - p1, M - block.timestamp, M - T1);
        uint256 d2 = Math.mulDiv(u2 - p2, M - block.timestamp, M - (T1 + 30 days));
        assertApproxEqAbs(module.debtValue(fd), u1 + u2 - d1 - d2, 2);
        assertEq(module.debtValue(fd), 150_894_580_468);

        vm.warp(M);
        assertEq(module.debtValue(fd), u1 + u2);
    }

    // ========== VAL-MID-027: accretion on repay ==========

    function testPartialRepayScalesDebtValue() public {
        _open(100_000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 face = _debt();
        uint256 v = module.debtValue(fd);
        uint256 r = 40_000e6;
        uint256 totalBefore = box.totalAssets();
        _repay(fd, r);
        assertApproxEqAbs(module.debtValue(fd), Math.mulDiv(v, face - r, face), 2);
        uint256 realised = Math.mulDiv(r, face - v, face);
        assertApproxEqAbs(totalBefore - box.totalAssets(), realised, 2, "nav falls by the unamortised discount of r");
        (uint256 tracked, ) = module.accretionState(fd);
        assertEq(tracked, face - r);

        vm.warp(M);
        assertEq(module.debtValue(fd), face - r);
    }

    function testWorkedExamplePartialRepay() public {
        _pledge(fd, 5e8);
        _stageAndBorrow(fd, TICK, 100_000e6);
        vm.warp(T1 + 30 days);
        _stageAndBorrow(fd, 4240, 50_000e6);
        vm.warp(T1 + 45 days);
        uint256 totalBefore = box.totalAssets();
        _repay(fd, 60_000_000_000);
        assertEq(module.debtValue(fd), 91_399_140_808);
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, 92_174_265_453);
        assertEq(rate, 188_586_132_043_273_285_590);
        assertApproxEqAbs(totalBefore - box.totalAssets(), 504_560_340, 2, "realised loss r * D / A");

        // External liquidation of 10,000 USDC of face five days later, then time passes
        vm.warp(T1 + 50 days);
        assertEq(module.debtValue(fd), 91_480_610_017);
        midnight.reduceDebt(id, address(module), 10_000_000_000);
        assertApproxEqAbs(module.debtValue(fd), 81_555_864_801, 1);
        vm.warp(T1 + 60 days);
        assertApproxEqAbs(module.debtValue(fd), 81_701_126_005, 1);
        vm.warp(M);
        assertEq(module.debtValue(fd), 82_174_265_453);
    }

    function testFullRepayResetsAccretion() public {
        _open(100_000e6);
        vm.warp(block.timestamp + 10 days);
        _repay(fd, type(uint256).max);
        assertEq(module.debtValue(fd), 0);
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, 0);
        assertEq(rate, 0);

        (uint256 p2, uint256 u2) = _stageAndBorrow(fd, HIGH_TICK, 20_000e6);
        uint256 dv = module.debtValue(fd);
        assertGe(dv, p2);
        assertLe(dv, p2 + 2, "fresh borrow accretes from its own proceeds");
        vm.warp(M);
        assertEq(module.debtValue(fd), u2);
    }

    // ========== VAL-MID-028: external face reduction ==========

    function testExternalFaceReduction() public {
        _open(100_000e6);
        vm.warp(block.timestamp + 20 days);
        uint256 tracked = _debt();
        uint256 vTracked = module.debtValue(fd);
        uint256 cut = 30_000e6;
        midnight.reduceDebt(id, address(module), cut);
        uint256 face = _debt();
        assertEq(face, tracked - cut);

        uint256 v = module.debtValue(fd);
        assertApproxEqAbs(v, Math.mulDiv(vTracked, face, tracked), 1);
        assertLe(v, face);
        _nav();
        box.totalAssets();
        assertEq(module.debtBalance(fd, usdc), face);

        // A borrow after the cut syncs first: its discount is not scaled by the old face / tracked ratio
        (uint256 p2, uint256 u2) = _stageAndBorrow(fd, HIGH_TICK, 10_000e6);
        (uint256 trackedAfter, ) = module.accretionState(fd);
        assertEq(trackedAfter, face + u2);
        assertApproxEqAbs(module.debtValue(fd), v + p2, 2);

        vm.warp(M);
        assertEq(module.debtValue(fd), face + u2);
    }

    function testRepayAfterFaceReductionClosesExactly() public {
        _open(100_000e6);
        vm.warp(block.timestamp + 20 days);
        midnight.reduceDebt(id, address(module), 30_000e6);
        uint256 face = _debt();

        _repay(fd, 10_000e6);
        (uint256 tracked, ) = module.accretionState(fd);
        assertEq(tracked, face - 10_000e6, "synced before the repay");

        uint256 boxBefore = usdc.balanceOf(address(box));
        _repay(fd, type(uint256).max);
        assertEq(_debt(), 0);
        assertEq(usdc.balanceOf(address(box)), boxBefore - (face - 10_000e6));
        (tracked, ) = module.accretionState(fd);
        assertEq(tracked, 0);
    }

    function testExternalFaceReductionAtMaturity() public {
        _open(100_000e6);
        midnight.reduceDebt(id, address(module), 1_000e6);
        vm.warp(M);
        assertEq(module.debtValue(fd), _debt());
    }

    // ========== VAL-MID-029: nav never reverts ==========

    function testNavNeverReverts() public {
        FundingMidnight empty = _freshModule();
        assertEq(empty.nav(IOracleCallback(address(box))), 0);

        assertEq(_nav(), 0, "registered facility, no position");
        box.totalAssets();

        _open(100_000e6);
        cbBtcMidnightOracle.setReverts(true);
        _nav();
        box.totalAssets();
        cbBtcMidnightOracle.setReverts(false);

        vm.warp(M);
        _nav();
        box.totalAssets();
        vm.warp(M + 10 days);
        assertEq(_nav(), Math.mulDiv(5e8, CBBTC_PRICE, 1e36) - _debt());
        box.totalAssets();
    }

    function testNavWithDebtAndNoCollateral() public {
        _open(100_000e6);
        _liquidateAllCollateral();
        assertEq(_coll(), 0);
        assertGt(_debt(), 0);
        assertEq(_nav(), 0);
        box.totalAssets();
    }

    function testNavWhenFaceCutToZero() public {
        _open(100_000e6);
        midnight.reduceDebt(id, address(module), _debt());
        (uint256 tracked, ) = module.accretionState(fd);
        assertGt(tracked, 0, "tracked state not synced yet");
        assertEq(module.debtValue(fd), 0);
        assertEq(_nav(), Math.mulDiv(5e8, CBBTC_PRICE, 1e36));
        box.totalAssets();

        // The next repay syncs the state to zero
        _repay(fd, type(uint256).max);
        (tracked, ) = module.accretionState(fd);
        assertEq(tracked, 0);
    }

    // ========== VAL-MID-030: removal ==========

    function testRemoveFacilityOnlyWhenEmpty() public {
        _open(100_000e6);
        _stage(fd, _fills(_fill(_bid(lender, TICK, "staged"))));
        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fd);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(cbBtc);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(usdc);
        vm.stopPrank();

        _repay(fd, type(uint256).max);
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fd);

        _depledge(fd, type(uint256).max);

        // Balances are zero but the facility still references the tokens
        vm.startPrank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeCollateralToken(cbBtc);
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeDebtToken(usdc);

        module.removeFacility(fd);
        assertFalse(module.isFacility(fd));
        assertEq(module.facilitiesLength(), 0);
        assertEq(module.facilityOfMarket(id), bytes32(0));
        (uint256 validUntil, OfferFill[] memory staged) = module.stagedBorrow(fd);
        assertEq(validUntil, 0);
        assertEq(staged.length, 0);
        (uint256 tracked, uint256 rate) = module.accretionState(fd);
        assertEq(tracked, 0);
        assertEq(rate, 0);

        module.addFacility(fd);
        (validUntil, ) = module.stagedBorrow(fd);
        assertEq(validUntil, 0, "re-added facility has no staging");
        (tracked, rate) = module.accretionState(fd);
        assertEq(tracked, 0);
        module.removeFacility(fd);

        module.removeCollateralToken(cbBtc);
        module.removeDebtToken(usdc);
        vm.expectRevert(ErrorsLib.NotWhitelisted.selector);
        module.removeFacility(fd);
        vm.stopPrank();
        assertEq(module.collateralTokensLength(), 0);
        assertEq(module.debtTokensLength(), 0);
    }

    function testRemoveFacilityRevertsWithDebtButNoCollateral() public {
        _open(100_000e6);
        _liquidateAllCollateral();
        vm.prank(address(box));
        vm.expectRevert(ErrorsLib.CannotRemove.selector);
        module.removeFacility(fd);
    }

    function testFullLifecycleThroughBoxAndRemoval() public {
        uint256 totalBefore = box.totalAssets();
        _open(100_000e6);
        _repay(fd, type(uint256).max);
        _depledge(fd, type(uint256).max);
        assertEq(_nav(), 0);

        vm.startPrank(curator);
        box.removeFundingFacility(module, fd);
        box.removeFundingCollateral(module, cbBtc);
        box.removeFundingDebt(module, usdc);
        box.removeFunding(module);
        vm.stopPrank();
        assertFalse(box.isFunding(module));
        // Early repay at face realises the whole discount as a loss
        assertEq(box.totalAssets(), totalBefore - (101_515_329_475 - 100_000_000_000));
    }
}
