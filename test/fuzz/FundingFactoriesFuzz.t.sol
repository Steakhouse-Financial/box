// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingAave, IPool} from "../../src/FundingAave.sol";
import {FundingAaveV4} from "../../src/FundingAaveV4.sol";
import {FundingMorpho} from "../../src/FundingMorpho.sol";
import {FundingAaveFactory} from "../../src/factories/FundingAaveFactory.sol";
import {FundingAaveV4Factory} from "../../src/factories/FundingAaveV4Factory.sol";
import {FundingMorphoFactory} from "../../src/factories/FundingMorphoFactory.sol";
import {IBox} from "../../src/interfaces/IBox.sol";
import {IFunding} from "../../src/interfaces/IFunding.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {ERC20MockDecimals} from "../mocks/ERC20MockDecimals.sol";
import {MockAaveV3Pool} from "../mocks/MockAaveV3Pool.sol";
import {MockAaveV4Spoke} from "../mocks/MockAaveV4Spoke.sol";

/// @dev Stateless fuzzing of the three funding module factories against a local Morpho Blue and the protocol mocks.
contract FundingFactoriesFuzzTest is Test {
    using BoxLib for IBox;

    event CreateFundingMorpho(address indexed owner, address indexed morpho, uint256 lltvCap, FundingMorpho fundingMorpho);
    event CreateFundingAave(address indexed owner, address indexed pool, uint8 indexed eMode, uint256 lltvCap, FundingAave fundingAave);
    event CreateFundingAaveV4(
        address indexed owner,
        address indexed spoke,
        uint256[] reserveIds,
        uint256 lltvCap,
        FundingAaveV4 fundingAaveV4
    );

    uint256 internal constant WAD = 1e18;
    /// @dev Spoke reserves 0..5 have non-zero underlyings (1/2 and 3/5 share one), reserve 6 has a zero underlying
    uint256 internal constant VALID_RESERVES = 6;
    uint256 internal constant ZERO_UNDERLYING_RESERVE = 6;

    FundingMorphoFactory internal morphoFactory;
    FundingAaveFactory internal aaveFactory;
    FundingAaveV4Factory internal aaveV4Factory;

    Morpho internal morpho;
    MockAaveV3Pool internal aavePool;
    MockAaveV4Spoke internal spoke;
    /// @dev Underlying of each spoke reserve, indexed by reserve id
    address[] internal reserveUnderlyings;

    function setUp() public {
        morphoFactory = new FundingMorphoFactory();
        aaveFactory = new FundingAaveFactory();
        aaveV4Factory = new FundingAaveV4Factory();

        morpho = new Morpho(address(this));
        aavePool = new MockAaveV3Pool();

        spoke = new MockAaveV4Spoke();
        address a = address(new ERC20MockDecimals(18));
        address b = address(new ERC20MockDecimals(6));
        address c = address(new ERC20MockDecimals(8));
        address d = address(new ERC20MockDecimals(18));
        _addReserve(a, 18, 8000, true);
        _addReserve(b, 6, 0, true);
        _addReserve(b, 6, 0, true);
        _addReserve(c, 8, 7500, false);
        _addReserve(d, 18, 8000, true);
        _addReserve(c, 8, 7000, true);
        _addReserve(address(0), 18, 0, false);
    }

    /////////////////////////////
    /// HELPERS
    /////////////////////////////

    function _addReserve(address underlying, uint8 decimals, uint16 collateralFactor, bool borrowable) internal {
        uint256 reserveId = spoke.addReserve(underlying, decimals, collateralFactor, borrowable);
        assertEq(reserveId, reserveUnderlyings.length, "reserve ids are sequential");
        reserveUnderlyings.push(underlying);
    }

    function _nonZero(address account) internal pure returns (address) {
        return account == address(0) ? address(0xB0C5) : account;
    }

    function _nextAddress(address factory) internal view returns (address) {
        return vm.computeCreateAddress(factory, vm.getNonce(factory));
    }

    function _assertNothingDeployed(address factory, address predicted, uint256 nonceBefore, bool registered) internal view {
        assertFalse(registered, "no registry entry for the predicted address");
        assertEq(vm.getNonce(factory), nonceBefore, "factory deployed nothing");
        assertEq(predicted.code.length, 0, "no code at the predicted address");
    }

    function _assertEmpty(IFunding module) internal view {
        assertEq(module.facilitiesLength(), 0, "no facility");
        assertEq(module.collateralTokensLength(), 0, "no collateral token");
        assertEq(module.debtTokensLength(), 0, "no debt token");
    }

    /// @dev Distinct-underlying subset of reserves 0..5 in a seed-dependent order (never empty)
    function _validReserveIds(uint256 seed) internal view returns (uint256[] memory ids) {
        uint256[] memory order = new uint256[](VALID_RESERVES);
        for (uint256 i; i < VALID_RESERVES; i++) order[i] = i;
        for (uint256 i = VALID_RESERVES - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        uint256[] memory picked = new uint256[](VALID_RESERVES);
        uint256 n;
        for (uint256 k; k < VALID_RESERVES; k++) {
            bool include = (seed >> k) & 1 == 1 || (k == VALID_RESERVES - 1 && n == 0);
            if (include && !_hasUnderlying(picked, n, reserveUnderlyings[order[k]])) picked[n++] = order[k];
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) ids[i] = picked[i];
    }

    function _hasUnderlying(uint256[] memory ids, uint256 length, address underlying) internal view returns (bool) {
        for (uint256 i; i < length; i++) {
            if (reserveUnderlyings[ids[i]] == underlying) return true;
        }
        return false;
    }

    function _insert(uint256[] memory ids, uint256 value, uint256 position) internal pure returns (uint256[] memory out) {
        position = bound(position, 0, ids.length);
        out = new uint256[](ids.length + 1);
        for (uint256 i; i < out.length; i++) {
            if (i < position) out[i] = ids[i];
            else if (i == position) out[i] = value;
            else out[i] = ids[i - 1];
        }
    }

    /// @dev A reserve (possibly `reserveId` itself) whose underlying is the one of `reserveId`
    function _sameUnderlying(uint256 reserveId, uint256 seed) internal view returns (uint256) {
        uint256[] memory candidates = new uint256[](VALID_RESERVES);
        uint256 n;
        for (uint256 r; r < VALID_RESERVES; r++) {
            if (reserveUnderlyings[r] == reserveUnderlyings[reserveId]) candidates[n++] = r;
        }
        return candidates[seed % n];
    }

    /////////////////////////////
    /// FUNDING MORPHO FACTORY
    /////////////////////////////

    function _assertMorphoModule(FundingMorpho module, address owner_, address morpho_, uint256 cap) internal view {
        assertEq(module.owner(), owner_, "owner");
        assertEq(address(module.morpho()), morpho_, "morpho");
        assertEq(module.lltvCap(), cap, "lltvCap");
        _assertEmpty(module);
        assertTrue(morphoFactory.isFundingMorpho(address(module)), "registered");
    }

    function testFuzz_MorphoFactoryDeploysAndRegisters(address owner_, address morpho_, bool localMorpho, uint256 cap) public {
        owner_ = _nonZero(owner_);
        // The constructor does not call Morpho, so any non-zero address is accepted and stored
        morpho_ = localMorpho ? address(morpho) : _nonZero(morpho_);
        cap = bound(cap, 1, WAD);

        address predicted = _nextAddress(address(morphoFactory));
        vm.expectEmit(true, true, true, true, address(morphoFactory));
        emit CreateFundingMorpho(owner_, morpho_, cap, FundingMorpho(payable(predicted)));
        FundingMorpho module = morphoFactory.createFundingMorpho(owner_, morpho_, cap);
        assertEq(address(module), predicted, "deployed at the predicted address");
        _assertMorphoModule(module, owner_, morpho_, cap);

        predicted = _nextAddress(address(morphoFactory));
        vm.expectEmit(true, true, true, true, address(morphoFactory));
        emit CreateFundingMorpho(owner_, morpho_, cap, FundingMorpho(payable(predicted)));
        FundingMorpho second = morphoFactory.createFundingMorpho(owner_, morpho_, cap);
        assertEq(address(second), predicted, "second deployed at the next address");
        assertTrue(address(second) != address(module), "distinct modules");
        _assertMorphoModule(second, owner_, morpho_, cap);
        assertTrue(morphoFactory.isFundingMorpho(address(module)), "first still registered");
    }

    function testFuzz_MorphoFactoryRejectsInvalidParams(address owner_, uint256 cap, uint256 badCap) public {
        owner_ = _nonZero(owner_);
        cap = bound(cap, 1, WAD);
        badCap = bound(badCap, WAD + 1, type(uint256).max);
        address predicted = _nextAddress(address(morphoFactory));
        uint256 nonceBefore = vm.getNonce(address(morphoFactory));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        morphoFactory.createFundingMorpho(address(0), address(morpho), cap);
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        morphoFactory.createFundingMorpho(owner_, address(0), cap);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        morphoFactory.createFundingMorpho(owner_, address(morpho), 0);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        morphoFactory.createFundingMorpho(owner_, address(morpho), badCap);

        _assertNothingDeployed(address(morphoFactory), predicted, nonceBefore, morphoFactory.isFundingMorpho(predicted));
    }

    /////////////////////////////
    /// FUNDING AAVE (V3) FACTORY
    /////////////////////////////

    function _assertAaveModule(FundingAave module, address owner_, uint8 eMode, uint256 cap) internal view {
        assertEq(module.owner(), owner_, "owner");
        assertEq(address(module.pool()), address(aavePool), "pool");
        assertEq(module.eMode(), eMode, "eMode");
        assertEq(module.rateMode(), 2, "variable rate mode");
        assertEq(module.lltvCap(), cap, "lltvCap");
        assertEq(module.minHealthFactor(), Math.ceilDiv(WAD * WAD, cap), "minHealthFactor = ceil(1e36 / lltvCap)");
        assertEq(aavePool.getUserEMode(address(module)), eMode, "e-mode set on the pool by the constructor");
        _assertEmpty(module);
        assertTrue(aaveFactory.isFundingAave(address(module)), "registered");
    }

    function testFuzz_AaveFactoryDeploysAndRegisters(address owner_, uint8 eMode, uint256 cap) public {
        owner_ = _nonZero(owner_);
        cap = bound(cap, 1, WAD - 1);

        address predicted = _nextAddress(address(aaveFactory));
        vm.expectEmit(true, true, true, true, address(aaveFactory));
        emit CreateFundingAave(owner_, address(aavePool), eMode, cap, FundingAave(payable(predicted)));
        FundingAave module = aaveFactory.createFundingAave(owner_, IPool(address(aavePool)), eMode, cap);
        assertEq(address(module), predicted, "deployed at the predicted address");
        _assertAaveModule(module, owner_, eMode, cap);

        predicted = _nextAddress(address(aaveFactory));
        vm.expectEmit(true, true, true, true, address(aaveFactory));
        emit CreateFundingAave(owner_, address(aavePool), eMode, cap, FundingAave(payable(predicted)));
        FundingAave second = aaveFactory.createFundingAave(owner_, IPool(address(aavePool)), eMode, cap);
        assertEq(address(second), predicted, "second deployed at the next address");
        assertTrue(address(second) != address(module), "distinct modules");
        _assertAaveModule(second, owner_, eMode, cap);
        assertTrue(aaveFactory.isFundingAave(address(module)), "first still registered");
    }

    function testFuzz_AaveFactoryRejectsInvalidParams(address owner_, uint8 eMode, uint256 cap, uint256 badCap) public {
        owner_ = _nonZero(owner_);
        cap = bound(cap, 1, WAD - 1);
        badCap = bound(badCap, WAD + 1, type(uint256).max);
        address predicted = _nextAddress(address(aaveFactory));
        uint256 nonceBefore = vm.getNonce(address(aaveFactory));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        aaveFactory.createFundingAave(address(0), IPool(address(aavePool)), eMode, cap);
        // No explicit pool check: the constructor's getUserEMode call to a codeless pool reverts without data
        vm.expectRevert();
        aaveFactory.createFundingAave(owner_, IPool(address(0)), eMode, cap);
        address codeless = makeAddr("codeless pool");
        assertEq(codeless.code.length, 0, "codeless");
        vm.expectRevert();
        aaveFactory.createFundingAave(owner_, IPool(codeless), eMode, cap);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveFactory.createFundingAave(owner_, IPool(address(aavePool)), eMode, 0);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveFactory.createFundingAave(owner_, IPool(address(aavePool)), eMode, WAD);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveFactory.createFundingAave(owner_, IPool(address(aavePool)), eMode, badCap);

        _assertNothingDeployed(address(aaveFactory), predicted, nonceBefore, aaveFactory.isFundingAave(predicted));
    }

    /////////////////////////////
    /// FUNDING AAVE V4 FACTORY
    /////////////////////////////

    function _assertAaveV4Module(FundingAaveV4 module, address owner_, uint256[] memory ids, uint256 cap) internal view {
        assertEq(module.owner(), owner_, "owner");
        assertEq(address(module.spoke()), address(spoke), "spoke");
        assertEq(module.lltvCap(), cap, "lltvCap");
        assertEq(module.minHealthFactor(), Math.ceilDiv(WAD * WAD, cap), "minHealthFactor = ceil(1e36 / lltvCap)");
        assertEq(module.reserveIdsArray(), ids, "reserve ids in constructor order");
        for (uint256 r; r < VALID_RESERVES; r++) {
            (bool expectedListed, uint256 expectedId) = (false, 0);
            for (uint256 i; i < ids.length; i++) {
                if (reserveUnderlyings[ids[i]] == reserveUnderlyings[r]) (expectedListed, expectedId) = (true, ids[i]);
            }
            (bool listed, uint256 reserveId) = module.reserveIdOf(IERC20(reserveUnderlyings[r]));
            assertEq(listed, expectedListed, "token listed iff one of its reserves was configured");
            assertEq(reserveId, expectedId, "token maps to the configured reserve");
        }
        (bool zeroListed, ) = module.reserveIdOf(IERC20(address(0)));
        assertFalse(zeroListed, "address(0) not listed");
        _assertEmpty(module);
        assertTrue(aaveV4Factory.isFundingAaveV4(address(module)), "registered");
    }

    function testFuzz_AaveV4FactoryDeploysAndRegisters(address owner_, uint256 seed, uint256 cap) public {
        owner_ = _nonZero(owner_);
        cap = bound(cap, 1, WAD - 1);
        uint256[] memory ids = _validReserveIds(seed);

        address predicted = _nextAddress(address(aaveV4Factory));
        vm.expectEmit(true, true, true, true, address(aaveV4Factory));
        emit CreateFundingAaveV4(owner_, address(spoke), ids, cap, FundingAaveV4(payable(predicted)));
        FundingAaveV4 module = aaveV4Factory.createFundingAaveV4(owner_, address(spoke), ids, cap);
        assertEq(address(module), predicted, "deployed at the predicted address");
        _assertAaveV4Module(module, owner_, ids, cap);

        predicted = _nextAddress(address(aaveV4Factory));
        vm.expectEmit(true, true, true, true, address(aaveV4Factory));
        emit CreateFundingAaveV4(owner_, address(spoke), ids, cap, FundingAaveV4(payable(predicted)));
        FundingAaveV4 second = aaveV4Factory.createFundingAaveV4(owner_, address(spoke), ids, cap);
        assertEq(address(second), predicted, "second deployed at the next address");
        assertTrue(address(second) != address(module), "distinct modules");
        _assertAaveV4Module(second, owner_, ids, cap);
        assertTrue(aaveV4Factory.isFundingAaveV4(address(module)), "first still registered");
    }

    function testFuzz_AaveV4FactoryRejectsInvalidParams(
        address owner_,
        uint256 seed,
        uint256 cap,
        uint256 badCap,
        uint256 unknownId,
        uint256 position
    ) public {
        owner_ = _nonZero(owner_);
        cap = bound(cap, 1, WAD - 1);
        badCap = bound(badCap, WAD + 1, type(uint256).max);
        uint256[] memory ids = _validReserveIds(seed);
        unknownId = bound(unknownId, spoke.getReserveCount(), type(uint256).max);
        uint256 duplicate = _sameUnderlying(ids[seed % ids.length], seed >> 128);
        address predicted = _nextAddress(address(aaveV4Factory));
        uint256 nonceBefore = vm.getNonce(address(aaveV4Factory));

        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        aaveV4Factory.createFundingAaveV4(address(0), address(spoke), ids, cap);
        vm.expectRevert(ErrorsLib.InvalidAddress.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(0), ids, cap);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), ids, 0);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), ids, WAD);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), ids, badCap);
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), new uint256[](0), cap);
        // Unknown reserve id (>= reserve count)
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), _insert(ids, unknownId, position), cap);
        // Reserve whose underlying is address(0)
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), _insert(ids, ZERO_UNDERLYING_RESERVE, position), cap);
        // Repeated reserve id, or another reserve with an underlying already configured
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        aaveV4Factory.createFundingAaveV4(owner_, address(spoke), _insert(ids, duplicate, position), cap);

        _assertNothingDeployed(address(aaveV4Factory), predicted, nonceBefore, aaveV4Factory.isFundingAaveV4(predicted));
    }

    /////////////////////////////
    /// MODULES OWNED BY A BOX
    /////////////////////////////

    function testFuzz_ModulesOwnedByABoxCanBeAdded(uint256 cap, uint8 eMode, uint256 seed, address stranger) public {
        cap = bound(cap, 1, WAD - 1);
        address curator = address(0x3);
        ERC20MockDecimals boxAsset = new ERC20MockDecimals(18);
        IBox box = IBox(
            address(new Box(address(boxAsset), address(0x1), curator, "Box Factories Fuzz", "BOXFF", 0.01 ether, 7 days, 10 days, 7 days))
        );

        IFunding[3] memory modules = [
            IFunding(morphoFactory.createFundingMorpho(address(box), address(morpho), cap)),
            IFunding(aaveFactory.createFundingAave(address(box), IPool(address(aavePool)), eMode, cap)),
            IFunding(aaveV4Factory.createFundingAaveV4(address(box), address(spoke), _validReserveIds(seed), cap))
        ];

        vm.startPrank(curator);
        for (uint256 i; i < modules.length; i++) {
            box.addFundingInstant(modules[i]);
        }
        vm.stopPrank();
        for (uint256 i; i < modules.length; i++) {
            assertTrue(box.isFunding(modules[i]), string.concat("module added, index ", vm.toString(i)));
        }
        assertEq(box.fundingsLength(), 3, "three modules attached");

        // The Box refuses a module owned by anyone else
        stranger = _nonZero(stranger);
        if (stranger == address(box)) stranger = address(uint160(stranger) ^ 1);
        IFunding foreign = IFunding(morphoFactory.createFundingMorpho(stranger, address(morpho), cap));
        vm.startPrank(curator);
        box.submit(abi.encodeCall(IBox.addFunding, (foreign)));
        vm.expectRevert(ErrorsLib.InvalidValue.selector);
        box.addFunding(foreign);
        vm.stopPrank();
        assertFalse(box.isFunding(foreign), "foreign module not added");
    }
}
