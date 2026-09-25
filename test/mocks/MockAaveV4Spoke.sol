// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAaveV4Spoke} from "../../src/interfaces/aave-v4/IAaveV4Spoke.sol";

/// @notice Aave v4 Spoke mock for unit tests. Written from the documented Spoke behaviour, not from Aave code.
/// @dev Semantics reproduced:
/// - only `onBehalfOf` may act on its own position (no position managers);
/// - supply pulls exactly `amount`, mints shares rounded down, never enables collateral;
/// - withdraw sends to the caller and silently caps at the supplied assets (so `max` = all);
/// - borrow sends exactly `amount` to the caller, drawn shares rounded up;
/// - repay pulls at most drawn + premium (premium first), full repay clears everything;
/// - zero amounts / empty positions revert `InvalidAmount()`;
/// - paused / frozen / halted / not-borrowable reverts per action like the real Spoke;
/// - borrow, withdraw of an enabled collateral and collateral disabling rebind every dynamic config key of the user
///   and require a health factor >= 1;
/// - account data uses the user's bound keys, counts only enabled collaterals with a non-zero collateral factor and
///   reverts when a price is missing (like the Spoke oracle).
contract MockAaveV4Spoke is IAaveV4Spoke {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;

    error ReserveNotListed();
    error Unauthorized();
    error InvalidAmount();
    error InvalidShares();
    error ReservePaused();
    error ReserveFrozen();
    error ReserveNotBorrowable();
    error SpokeHalted();
    error HealthFactorBelowThreshold();
    error InsufficientLiquidity(uint256 liquidity);
    error InvalidPrice();
    error AccountDataUnavailable();

    struct MockReserve {
        Reserve reserve;
        ReserveConfig config;
        bool halted;
        uint256 price; // 8 decimals
        uint256 supplyIndex; // assets per share, RAY
        uint256 drawnIndex; // debt per drawn share, RAY
    }

    struct Position {
        uint256 suppliedShares;
        uint256 drawnShares;
        uint256 premiumDebt;
        bool usingAsCollateral;
        uint32 boundKey;
    }

    MockReserve[] internal reserves;
    mapping(uint256 reserveId => mapping(uint32 key => DynamicReserveConfig)) internal dynamicConfigs;
    mapping(uint256 reserveId => mapping(address user => Position)) internal positions;

    /// @notice Number of state-changing user actions executed (supply, withdraw, borrow, repay, setUsingAsCollateral)
    uint256 public actionCount;

    bool public accountDataReverts;
    bool public accountDataOverridden;
    uint256 internal overrideAvgCollateralFactor;
    uint256 internal overrideTotalCollateralValue;
    uint256 internal overrideTotalDebtValueRay;

    // ========== TEST KNOBS ==========

    function addReserve(address underlying, uint8 decimals, uint16 collateralFactor, bool borrowable) external returns (uint256 reserveId) {
        reserveId = reserves.length;
        reserves.push(
            MockReserve({
                reserve: Reserve({
                    underlying: underlying,
                    hub: address(this),
                    assetId: reserveId.toUint16(),
                    decimals: decimals,
                    collateralRisk: 0,
                    flags: 0,
                    dynamicConfigKey: 0
                }),
                config: ReserveConfig({
                    collateralRisk: 0,
                    paused: false,
                    frozen: false,
                    borrowable: borrowable,
                    receiveSharesEnabled: true
                }),
                halted: false,
                price: 1e8,
                supplyIndex: RAY,
                drawnIndex: RAY
            })
        );
        dynamicConfigs[reserveId][0] = DynamicReserveConfig({
            collateralFactor: collateralFactor,
            maxLiquidationBonus: 10_500,
            liquidationFee: 0
        });
    }

    /// @notice Adds a new latest dynamic config (governance collateral factor change). Existing positions keep their key.
    function addDynamicReserveConfig(uint256 reserveId, uint16 collateralFactor) external returns (uint32 key) {
        MockReserve storage r = _reserve(reserveId);
        key = r.reserve.dynamicConfigKey + 1;
        r.reserve.dynamicConfigKey = key;
        dynamicConfigs[reserveId][key] = DynamicReserveConfig({
            collateralFactor: collateralFactor,
            maxLiquidationBonus: 10_500,
            liquidationFee: 0
        });
    }

    /// @notice Edits the collateral factor of an existing key in place (affects positions bound to it immediately).
    function setCollateralFactor(uint256 reserveId, uint32 key, uint16 collateralFactor) external {
        _reserve(reserveId);
        dynamicConfigs[reserveId][key].collateralFactor = collateralFactor;
    }

    function updateReserveConfig(uint256 reserveId, ReserveConfig calldata config) external {
        _reserve(reserveId).config = config;
    }

    function setPaused(uint256 reserveId, bool paused) external {
        _reserve(reserveId).config.paused = paused;
    }

    function setFrozen(uint256 reserveId, bool frozen) external {
        _reserve(reserveId).config.frozen = frozen;
    }

    function setBorrowable(uint256 reserveId, bool borrowable) external {
        _reserve(reserveId).config.borrowable = borrowable;
    }

    function setHalted(uint256 reserveId, bool halted) external {
        _reserve(reserveId).halted = halted;
    }

    function setPrice(uint256 reserveId, uint256 price) external {
        _reserve(reserveId).price = price;
    }

    function setSupplyIndex(uint256 reserveId, uint256 index) external {
        require(index >= RAY, "index < RAY");
        _reserve(reserveId).supplyIndex = index;
    }

    /// @notice Accrues interest on drawn debt without any user transaction.
    function setDrawnIndex(uint256 reserveId, uint256 index) external {
        require(index >= RAY, "index < RAY");
        _reserve(reserveId).drawnIndex = index;
    }

    function setPremiumDebt(uint256 reserveId, address user, uint256 amount) external {
        _reserve(reserveId);
        positions[reserveId][user].premiumDebt = amount;
    }

    /// @notice Forces the collateral flag of a user (models a state the module itself never produces).
    function forceUsingAsCollateral(uint256 reserveId, address user, bool usingAsCollateral) external {
        _reserve(reserveId);
        positions[reserveId][user].usingAsCollateral = usingAsCollateral;
    }

    /// @notice Governance rebinding of every dynamic config key of a user to the latest keys.
    function updateUserDynamicConfig(address user) external {
        _rebindAll(user);
    }

    function setAccountDataReverts(bool reverts) external {
        accountDataReverts = reverts;
    }

    /// @notice Makes getUserAccountData return these values; the health factor is derived from them
    ///         (healthFactor = avgCollateralFactor * totalCollateralValue * 1e27 / totalDebtValueRay).
    function setAccountDataOverride(uint256 avgCollateralFactor, uint256 totalCollateralValue, uint256 totalDebtValueRay) external {
        accountDataOverridden = true;
        overrideAvgCollateralFactor = avgCollateralFactor;
        overrideTotalCollateralValue = totalCollateralValue;
        overrideTotalDebtValueRay = totalDebtValueRay;
    }

    function clearAccountDataOverride() external {
        accountDataOverridden = false;
    }

    // ========== ACTIONS ==========

    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets) {
        _onlyPositionManager(onBehalfOf);
        MockReserve storage r = _reserve(reserveId);
        require(!r.config.paused, ReservePaused());
        require(!r.config.frozen, ReserveFrozen());
        require(!r.halted, SpokeHalted());
        require(amount > 0, InvalidAmount());

        shares = Math.mulDiv(amount, RAY, r.supplyIndex);
        require(shares > 0, InvalidShares());

        IERC20(r.reserve.underlying).safeTransferFrom(msg.sender, address(this), amount);
        positions[reserveId][onBehalfOf].suppliedShares += shares;
        actionCount++;
        return (shares, amount);
    }

    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets) {
        _onlyPositionManager(onBehalfOf);
        MockReserve storage r = _reserve(reserveId);
        require(!r.config.paused, ReservePaused());
        require(!r.halted, SpokeHalted());

        Position storage p = positions[reserveId][onBehalfOf];
        uint256 supplied = Math.mulDiv(p.suppliedShares, r.supplyIndex, RAY);
        require(amount > 0 && supplied > 0, InvalidAmount());

        assets = Math.min(amount, supplied);
        if (assets == supplied) {
            shares = p.suppliedShares;
        } else {
            shares = Math.min(Math.mulDiv(assets, RAY, r.supplyIndex, Math.Rounding.Ceil), p.suppliedShares);
        }
        uint256 liquidity = IERC20(r.reserve.underlying).balanceOf(address(this));
        require(liquidity >= assets, InsufficientLiquidity(liquidity));

        p.suppliedShares -= shares;
        if (p.usingAsCollateral) {
            _rebindAll(onBehalfOf);
            _requireHealthy(onBehalfOf);
        }

        IERC20(r.reserve.underlying).safeTransfer(msg.sender, assets);
        actionCount++;
    }

    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets) {
        _onlyPositionManager(onBehalfOf);
        MockReserve storage r = _reserve(reserveId);
        require(r.config.borrowable, ReserveNotBorrowable());
        require(!r.config.paused, ReservePaused());
        require(!r.config.frozen, ReserveFrozen());
        require(!r.halted, SpokeHalted());
        require(amount > 0, InvalidAmount());
        uint256 liquidity = IERC20(r.reserve.underlying).balanceOf(address(this));
        require(liquidity >= amount, InsufficientLiquidity(liquidity));

        shares = Math.mulDiv(amount, RAY, r.drawnIndex, Math.Rounding.Ceil);
        positions[reserveId][onBehalfOf].drawnShares += shares;
        _rebindAll(onBehalfOf);
        _requireHealthy(onBehalfOf);

        IERC20(r.reserve.underlying).safeTransfer(msg.sender, amount);
        actionCount++;
        return (shares, amount);
    }

    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256 shares, uint256 assets) {
        _onlyPositionManager(onBehalfOf);
        MockReserve storage r = _reserve(reserveId);
        require(!r.config.paused, ReservePaused());
        require(!r.halted, SpokeHalted());

        Position storage p = positions[reserveId][onBehalfOf];
        uint256 drawn = Math.mulDiv(p.drawnShares, r.drawnIndex, RAY, Math.Rounding.Ceil);
        uint256 total = drawn + p.premiumDebt;
        require(amount > 0 && total > 0, InvalidAmount());

        assets = Math.min(amount, total);
        uint256 premiumPaid = Math.min(assets, p.premiumDebt);
        p.premiumDebt -= premiumPaid;
        uint256 drawnPaid = assets - premiumPaid;
        if (drawnPaid >= drawn) {
            shares = p.drawnShares;
        } else {
            shares = Math.mulDiv(drawnPaid, RAY, r.drawnIndex);
        }
        p.drawnShares -= shares;

        IERC20(r.reserve.underlying).safeTransferFrom(msg.sender, address(this), assets);
        actionCount++;
    }

    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external {
        _onlyPositionManager(onBehalfOf);
        MockReserve storage r = _reserve(reserveId);
        require(!r.config.paused, ReservePaused());
        if (usingAsCollateral) require(!r.config.frozen, ReserveFrozen());

        Position storage p = positions[reserveId][onBehalfOf];
        if (p.usingAsCollateral == usingAsCollateral) return;
        p.usingAsCollateral = usingAsCollateral;
        if (usingAsCollateral) {
            p.boundKey = r.reserve.dynamicConfigKey;
        } else {
            _rebindAll(onBehalfOf);
            _requireHealthy(onBehalfOf);
        }
        actionCount++;
    }

    // ========== VIEWS ==========

    function getReserveCount() external view returns (uint256) {
        return reserves.length;
    }

    function getReserve(uint256 reserveId) external view returns (Reserve memory) {
        return _reserveView(reserveId).reserve;
    }

    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory) {
        return _reserveView(reserveId).config;
    }

    function getDynamicReserveConfig(uint256 reserveId, uint32 key) external view returns (DynamicReserveConfig memory) {
        _reserveView(reserveId);
        return dynamicConfigs[reserveId][key];
    }

    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool usingAsCollateral, bool borrowing) {
        _reserveView(reserveId);
        Position storage p = positions[reserveId][user];
        return (p.usingAsCollateral, p.drawnShares > 0 || p.premiumDebt > 0);
    }

    function getUserSuppliedAssets(uint256 reserveId, address user) public view returns (uint256) {
        MockReserve storage r = _reserveView(reserveId);
        return Math.mulDiv(positions[reserveId][user].suppliedShares, r.supplyIndex, RAY);
    }

    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256) {
        _reserveView(reserveId);
        return positions[reserveId][user].suppliedShares;
    }

    function getUserDebt(uint256 reserveId, address user) public view returns (uint256 drawnDebt, uint256 premiumDebt) {
        MockReserve storage r = _reserveView(reserveId);
        Position storage p = positions[reserveId][user];
        return (Math.mulDiv(p.drawnShares, r.drawnIndex, RAY, Math.Rounding.Ceil), p.premiumDebt);
    }

    function getUserTotalDebt(uint256 reserveId, address user) public view returns (uint256) {
        (uint256 drawnDebt, uint256 premiumDebt) = getUserDebt(reserveId, user);
        return drawnDebt + premiumDebt;
    }

    function getUserPosition(uint256 reserveId, address user) external view returns (UserPosition memory) {
        _reserveView(reserveId);
        Position storage p = positions[reserveId][user];
        return
            UserPosition({
                drawnShares: p.drawnShares.toUint120(),
                premiumShares: p.premiumDebt.toUint120(),
                premiumOffsetRay: 0,
                suppliedShares: p.suppliedShares.toUint120(),
                dynamicConfigKey: p.boundKey
            });
    }

    function getUserAccountData(address user) public view returns (UserAccountData memory data) {
        require(!accountDataReverts, AccountDataUnavailable());

        if (accountDataOverridden) {
            data.avgCollateralFactor = overrideAvgCollateralFactor;
            data.totalCollateralValue = overrideTotalCollateralValue;
            data.totalDebtValueRay = overrideTotalDebtValueRay;
            data.activeCollateralCount = overrideTotalCollateralValue > 0 ? 1 : 0;
            data.borrowCount = overrideTotalDebtValueRay > 0 ? 1 : 0;
        } else {
            uint256 weightedCollateralFactor;
            for (uint256 id; id < reserves.length; id++) {
                MockReserve storage r = reserves[id];
                Position storage p = positions[id][user];
                uint256 unit = 10 ** (18 - r.reserve.decimals);

                uint256 supplied = getUserSuppliedAssets(id, user);
                if (p.usingAsCollateral && supplied > 0) {
                    data.activeCollateralCount++;
                    uint256 collateralFactor = dynamicConfigs[id][p.boundKey].collateralFactor;
                    if (collateralFactor > 0) {
                        require(r.price > 0, InvalidPrice());
                        uint256 value = supplied * r.price * unit;
                        data.totalCollateralValue += value;
                        weightedCollateralFactor += value * collateralFactor;
                    }
                }

                uint256 debt = getUserTotalDebt(id, user);
                if (debt > 0) {
                    require(r.price > 0, InvalidPrice());
                    data.borrowCount++;
                    data.totalDebtValueRay += debt * r.price * unit * RAY;
                }
            }
            if (data.totalCollateralValue > 0) {
                data.avgCollateralFactor = (weightedCollateralFactor * 1e14) / data.totalCollateralValue;
            }
        }

        data.healthFactor = data.totalDebtValueRay == 0
            ? type(uint256).max
            : Math.mulDiv(data.avgCollateralFactor * data.totalCollateralValue, RAY, data.totalDebtValueRay);
    }

    function ORACLE() external view returns (address) {
        return address(this);
    }

    // ========== INTERNAL ==========

    function _onlyPositionManager(address onBehalfOf) internal view {
        require(msg.sender == onBehalfOf, Unauthorized());
    }

    function _reserve(uint256 reserveId) internal view returns (MockReserve storage) {
        require(reserveId < reserves.length, ReserveNotListed());
        return reserves[reserveId];
    }

    function _reserveView(uint256 reserveId) internal view returns (MockReserve storage) {
        return _reserve(reserveId);
    }

    function _rebindAll(address user) internal {
        for (uint256 id; id < reserves.length; id++) {
            positions[id][user].boundKey = reserves[id].reserve.dynamicConfigKey;
        }
    }

    function _requireHealthy(address user) internal view {
        require(getUserAccountData(user).healthFactor >= WAD, HealthFactorBelowThreshold());
    }
}
