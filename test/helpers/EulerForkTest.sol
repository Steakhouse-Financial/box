// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Box} from "../../src/Box.sol";
import {FundingEuler} from "../../src/FundingEuler.sol";
import {FundingEulerFactory} from "../../src/factories/FundingEulerFactory.sol";
import {IEVault} from "../../src/interfaces/euler/IEVault.sol";
import {IPriceOracle} from "../../src/interfaces/euler/IPriceOracle.sol";
import {IOracleCallback} from "../../src/interfaces/IFunding.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {BoxLib} from "../../src/periphery/BoxLib.sol";
import {EulerAddresses} from "./EulerAddresses.sol";

/// @notice EVC views used only by tests
interface IEVCTest {
    function getControllers(address account) external view returns (address[] memory);

    function getCollaterals(address account) external view returns (address[] memory);

    function getAccountOwner(address account) external view returns (address);
}

/**
 * @title Shared helpers for fork tests against a real Euler v2 deployment
 * @dev Concrete tests fork in `setUp`, then set `evc` and create `factory`. Expected values are recomputed here from
 *      the vault views, the Euler router and the Box oracles, independently of the module's own math.
 */
abstract contract EulerForkTest is Test, EulerAddresses {
    using BoxLib for Box;

    bytes4 internal constant E_ACCOUNT_LIQUIDITY = bytes4(keccak256("E_AccountLiquidity()"));
    bytes4 internal constant EVC_NOT_AUTHORIZED = bytes4(keccak256("EVC_NotAuthorized()"));
    /// @dev PriceOracle_TooStale(uint256 staleness, uint256 maxStaleness)
    bytes4 internal constant PRICE_ORACLE_TOO_STALE = bytes4(keccak256("PriceOracle_TooStale(uint256,uint256)"));

    address internal owner = address(0x1);
    address internal curator = address(0x2);
    address internal guardian = address(0x3);
    address internal allocator = address(0x4);
    address internal anyone = makeAddr("anyone");

    address internal evc;
    FundingEulerFactory internal factory;

    /// @dev Box with the allocator, guardian and this contract as feeder; `oracle` is registered for `token`
    function _newBox(IERC20 asset, IERC20 token, IOracle oracle, uint256 shutdownWarmup) internal returns (Box box) {
        box = new Box(address(asset), owner, curator, "Box Euler", "BOXEULER", 0.01 ether, 7 days, 10 days, shutdownWarmup);
        vm.startPrank(curator);
        box.setGuardianInstant(guardian);
        box.setIsAllocator(allocator, true);
        box.addFeederInstant(address(this));
        box.addTokenInstant(token, oracle);
        vm.stopPrank();
    }

    /// @dev New module attached to `box`, with one facility and its two tokens registered (tokens first, as
    ///      addFacility requires)
    function _newModule(
        Box box,
        uint256 ltvCap,
        address collateralVault,
        address borrowVault
    ) internal returns (FundingEuler module, bytes memory facilityData) {
        module = factory.createFundingEuler(address(box), evc, ltvCap);
        facilityData = abi.encode(collateralVault, borrowVault);
        vm.startPrank(curator);
        box.addFundingInstant(module);
        box.addFundingCollateralInstant(module, IERC20(IEVault(collateralVault).asset()));
        box.addFundingDebtInstant(module, IERC20(IEVault(borrowVault).asset()));
        box.addFundingFacilityInstant(module, facilityData);
        vm.stopPrank();
    }

    function _deposit(Box box, uint256 amount) internal {
        IERC20 asset = IERC20(box.asset());
        deal(address(asset), address(this), amount);
        asset.approve(address(box), amount);
        box.deposit(amount, address(this));
    }

    /// @dev Euler borrow capacity of the facility sub-account, in debt-token units: its collateral value weighted by
    ///      LTVBorrow, priced by the borrow vault's router
    function _capacity(FundingEuler module, bytes memory facilityData) internal view returns (uint256) {
        (address collateralVault, address borrowVault) = abi.decode(facilityData, (address, address));
        IPriceOracle oracle = IPriceOracle(IEVault(borrowVault).oracle());
        address unitOfAccount = IEVault(borrowVault).unitOfAccount();
        uint256 shares = IEVault(collateralVault).balanceOf(module.subAccount(facilityData));
        uint256 weighted = (oracle.getQuote(shares, collateralVault, unitOfAccount) * IEVault(borrowVault).LTVBorrow(collateralVault)) /
            1e4;
        address debtToken = IEVault(borrowVault).asset();
        uint256 unit = 10 ** IERC20Metadata(debtToken).decimals();
        return (weighted * unit) / oracle.getQuote(unit, debtToken, unitOfAccount);
    }

    /// @dev Guard cap: LTVBorrow (1e4 scale) x ltvCap, rounded down
    function _guardCap(FundingEuler module, bytes memory facilityData) internal view returns (uint256) {
        (address collateralVault, address borrowVault) = abi.decode(facilityData, (address, address));
        return (uint256(IEVault(borrowVault).LTVBorrow(collateralVault)) * 1e14 * module.ltvCap()) / 1e18;
    }

    /// @dev LTVBorrow scaled to 1e18
    function _borrowLtv(bytes memory facilityData) internal view returns (uint256) {
        (address collateralVault, address borrowVault) = abi.decode(facilityData, (address, address));
        return uint256(IEVault(borrowVault).LTVBorrow(collateralVault)) * 1e14;
    }

    function _shares(FundingEuler module, bytes memory facilityData) internal view returns (uint256) {
        (address collateralVault, ) = abi.decode(facilityData, (address, address));
        return IEVault(collateralVault).balanceOf(module.subAccount(facilityData));
    }

    /// @dev Raw Euler debt of the facility sub-account
    function _debt(FundingEuler module, bytes memory facilityData) internal view returns (uint256) {
        (, address borrowVault) = abi.decode(facilityData, (address, address));
        return IEVault(borrowVault).debtOf(module.subAccount(facilityData));
    }

    /// @dev Value of a facility in the Box asset with the Box oracles: collateral down, debt up, floored at 0
    function _expectedFacilityNav(Box box, FundingEuler module, bytes memory facilityData) internal view returns (uint256) {
        (address collateralVault, address borrowVault) = abi.decode(facilityData, (address, address));
        address account = module.subAccount(facilityData);
        uint256 shares = IEVault(collateralVault).balanceOf(account);
        if (shares == 0) return 0;
        uint256 collateralValue = _boxValue(
            box,
            IEVault(collateralVault).asset(),
            IEVault(collateralVault).convertToAssets(shares),
            Math.Rounding.Floor
        );
        uint256 debtValue = _boxValue(box, IEVault(borrowVault).asset(), IEVault(borrowVault).debtOf(account), Math.Rounding.Ceil);
        return collateralValue > debtValue ? collateralValue - debtValue : 0;
    }

    function _expectedNav(Box box, FundingEuler module) internal view returns (uint256 nav) {
        uint256 length = module.facilitiesLength();
        for (uint256 i = 0; i < length; i++) {
            nav += _expectedFacilityNav(box, module, module.facilities(i));
        }
    }

    function _boxValue(Box box, address token, uint256 amount, Math.Rounding rounding) internal view returns (uint256) {
        if (token == box.asset()) return amount;
        return Math.mulDiv(amount, IOracleCallback(address(box)).oracles(IERC20(token)).price(), 1e36, rounding);
    }

    /// @dev Collateral amount whose withdrawal moves the facility ltv from `currentLtv` to about `targetLtv` (ltv scales
    ///      with 1 / collateral)
    function _depledgeFor(uint256 collateral, uint256 currentLtv, uint256 targetLtv) internal pure returns (uint256) {
        return collateral - Math.mulDiv(collateral, currentLtv, targetLtv);
    }

    function _controllers(FundingEuler module, bytes memory facilityData) internal view returns (address[] memory) {
        return IEVCTest(evc).getControllers(module.subAccount(facilityData));
    }

    function _collaterals(FundingEuler module, bytes memory facilityData) internal view returns (address[] memory) {
        return IEVCTest(evc).getCollaterals(module.subAccount(facilityData));
    }
}
