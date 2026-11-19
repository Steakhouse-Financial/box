// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {CollateralParams, IMidnight, Market, Offer} from "../../src/interfaces/midnight/IMidnight.sol";
import {IRatifier} from "../../src/interfaces/midnight/IRatifier.sol";
import {IdLib} from "../../src/libraries/midnight/IdLib.sol";
import {TickLib} from "../../src/libraries/midnight/TickLib.sol";
import {IBuyCallback} from "../helpers/MidnightTestInterfaces.sol";

bytes32 constant MIDNIGHT_CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

/// @notice Morpho Midnight mock for unit tests. Written from the documented Midnight behaviour, not from Midnight code.
/// @dev Semantics reproduced:
/// - positions are counted in units: one position per (market id, address), debt is a plain face value (no accrual);
/// - markets are created lazily by every entry point (`touchMarket`), with chainId/midnight/collateral checks and a
///   tick spacing of 4; `settlementFee` reverts `MarketNotCreated` for a market that was never touched;
/// - `take` of a buy offer runs Midnight's checks in order (taker auth, caps, continuous fee cap, tick spacing,
///   start/expiry, self take, unused receiver, ratifier authorisation and answer, tick range, consumption, no debt
///   increase after maturity, reduce-only), pays `floor(units * (tickPrice - fee))` to `receiverIfTakerIsSeller`,
///   keeps the settlement fee, nets seller credit before debt, and requires the seller to be healthy at the end;
/// - a maker callback (`offer.callback`) is called with `onBuy` after the seller's debt grew and before any transfer,
///   and then pays instead of the maker; the seller cannot be liquidated during the take;
/// - borrowing is allowed at `block.timestamp == maturity` and blocked after it, like Midnight;
/// - `repay` pulls exactly `units` from the caller and panics on `units > debt`; it works after maturity;
/// - `supplyCollateral` / `withdrawCollateral` / `repay` / `take` require `msg.sender == onBehalf` (or an authorisation);
///   first activation of a collateral calls its oracle; `withdrawCollateral` requires the borrower to stay healthy;
/// - health: `debt <= sum(floor(floor(collateral * price / 1e36) * lltv / 1e18))`, no oracle call when debt is 0;
/// - `liquidate`: pre-maturity only when unhealthy (LIF = maxLif), post-maturity only when `block.timestamp > maturity`
///   (LIF ramps to maxLif over one hour).
/// Simplifications: sell offers, taker/repay/liquidate callbacks revert `CallbackNotSupported` or
/// `SellOffersNotSupported`; the settlement fee is a flat per-market value; no continuous fee accrual, no gates, no
/// bad-debt realisation and no recovery close factor.
contract MockMidnight is IMidnight {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant MAX_COLLATERAL_PARAMS = 128;
    uint256 internal constant MAX_ACTIVATED_COLLATERALS = 16;
    uint256 internal constant TIME_TO_MAX_LIF = 1 hours;
    uint8 internal constant DEFAULT_TICK_SPACING = 4;

    // Midnight errors (same names, hence same selectors).
    error CannotIncreaseDebtPostMaturity();
    error CollateralParamsNotSorted();
    error ConsumedAssets();
    error ConsumedUnits();
    error ContinuousFeeAboveOfferCap();
    error InconsistentInput();
    error InvalidChainId();
    error InvalidLltv();
    error InvalidMidnight();
    error InvalidOfferCaps();
    error MakerCreditOrDebtIncreased();
    error MarketNotCreated();
    error NoCollateralParams();
    error NotBorrower();
    error NotLiquidatable();
    error OfferExpired();
    error OfferNotStarted();
    error RatifierFailed();
    error RatifierUnauthorized();
    error SelfTake();
    error SellerIsLiquidatable();
    error TakerUnauthorized();
    error TickNotAccessible();
    error TooManyActivatedCollaterals();
    error TooManyCollateralParams();
    error Unauthorized();
    error UnhealthyBorrower();
    error UnusedReceiverMustBeZero();
    error WrongBuyCallbackReturnValue();

    // Mock-only errors.
    error CallbackNotSupported();
    error SellOffersNotSupported();
    error ForcedTakeRevert();

    struct Position {
        uint128 credit;
        uint128 debt;
        mapping(uint256 index => uint128) collateral;
    }

    mapping(bytes32 id => uint8) internal _tickSpacing;
    mapping(bytes32 id => uint256) internal _settlementFee;
    mapping(bytes32 id => uint32) internal _continuousFee;
    mapping(bytes32 id => mapping(address user => Position)) internal _positions;
    mapping(address maker => mapping(bytes32 group => uint128)) internal _consumed;
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;
    mapping(bytes32 offerHash => bool) public forcedTakeRevert;
    /// @notice Set on the seller for the duration of a take (Midnight uses transient storage for the same purpose)
    mapping(bytes32 id => mapping(address user => bool)) public liquidationLocked;

    /// @notice Number of successful takes (lets tests check that an offer was skipped rather than taken).
    uint256 public takeCount;

    // ========== TEST HOOKS ==========

    function setTickSpacing(bytes32 id, uint8 newTickSpacing) external {
        _tickSpacing[id] = newTickSpacing;
    }

    /// @notice Flat settlement fee (WAD per unit) applied to every take in market `id`, whatever the time to maturity.
    function setSettlementFee(bytes32 id, uint256 newSettlementFee) external {
        _settlementFee[id] = newSettlementFee;
    }

    function setContinuousFee(bytes32 id, uint32 newContinuousFee) external {
        _continuousFee[id] = newContinuousFee;
    }

    /// @notice Makes every take of `offer` revert `ForcedTakeRevert` (after the market touch).
    function setForcedTakeRevert(Offer memory offer, bool forced) external {
        forcedTakeRevert[keccak256(abi.encode(offer))] = forced;
    }

    /// @notice Reduces the face debt of `user` without any token movement, like an external liquidation or bad-debt
    /// realisation would. Panics if `units` exceeds the debt.
    function reduceDebt(bytes32 id, address user, uint256 units) external {
        _positions[id][user].debt -= units.toUint128();
    }

    // ========== AUTHORISATION / CONSUMPTION ==========

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        _checkAuthorized(onBehalf);
        isAuthorized[onBehalf][authorized] = newIsAuthorized;
    }

    /// @notice Sets the consumed amount of `onBehalf`'s offers in `group`. `type(uint128).max` cancels the group.
    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external {
        _checkAuthorized(onBehalf);
        _consumed[onBehalf][group] = amount;
    }

    // ========== MARKETS ==========

    function touchMarket(Market memory market) public returns (bytes32 id) {
        id = IdLib.toId(market);
        if (_tickSpacing[id] != 0) return id;

        require(market.chainId == block.chainid, InvalidChainId());
        require(market.midnight == address(this), InvalidMidnight());
        uint256 length = market.collateralParams.length;
        require(length > 0, NoCollateralParams());
        require(length <= MAX_COLLATERAL_PARAMS, TooManyCollateralParams());
        for (uint256 i; i < length; i++) {
            if (i > 0) require(market.collateralParams[i - 1].token < market.collateralParams[i].token, CollateralParamsNotSorted());
            require(market.collateralParams[i].lltv < WAD, InvalidLltv());
        }
        _tickSpacing[id] = DEFAULT_TICK_SPACING;
    }

    // ========== ENTRY POINTS ==========

    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory
    ) external returns (uint256 buyerAssets, uint256 sellerAssets) {
        require(taker == msg.sender || isAuthorized[taker][msg.sender], TakerUnauthorized());
        bytes32 id = touchMarket(offer.market);
        require(!forcedTakeRevert[keccak256(abi.encode(offer))], ForcedTakeRevert());
        require(offer.buy, SellOffersNotSupported());
        require(takerCallback == address(0), CallbackNotSupported());

        require((offer.maxAssets == 0) != (offer.maxUnits == 0), InvalidOfferCaps());
        require(_continuousFee[id] <= offer.continuousFeeCap, ContinuousFeeAboveOfferCap());
        require(offer.tick % _tickSpacing[id] == 0, TickNotAccessible());
        require(offer.start <= block.timestamp, OfferNotStarted());
        require(block.timestamp <= offer.expiry, OfferExpired());
        require(offer.maker != taker, SelfTake());
        require(offer.receiverIfMakerIsSeller == address(0), UnusedReceiverMustBeZero());
        require(isAuthorized[offer.maker][offer.ratifier], RatifierUnauthorized());
        require(IRatifier(offer.ratifier).isRatified(offer, ratifierData, taker) == MIDNIGHT_CALLBACK_SUCCESS, RatifierFailed());

        uint256 buyerPrice = TickLib.tickToPrice(offer.tick);
        uint256 timeToMaturity = offer.market.maturity > block.timestamp ? offer.market.maturity - block.timestamp : 0;
        // Checked subtraction: a fee above the price panics, like Midnight.
        uint256 sellerPrice = buyerPrice - settlementFee(id, timeToMaturity);
        buyerAssets = Math.mulDiv(units, buyerPrice, WAD);
        sellerAssets = Math.mulDiv(units, sellerPrice, WAD);

        _consume(offer, units, buyerAssets);
        _settleUnits(offer, id, taker, units);

        bool wasLocked = liquidationLocked[id][taker];
        liquidationLocked[id][taker] = true;
        if (offer.callback != address(0)) {
            require(
                IBuyCallback(offer.callback).onBuy(id, offer.market, buyerAssets, units, 0, offer.maker, offer.callbackData) ==
                    MIDNIGHT_CALLBACK_SUCCESS,
                WrongBuyCallbackReturnValue()
            );
        }

        address payer = offer.callback != address(0) ? offer.callback : offer.maker;
        IERC20 loanToken = IERC20(offer.market.loanToken);
        if (buyerAssets > sellerAssets) loanToken.safeTransferFrom(payer, address(this), buyerAssets - sellerAssets);
        loanToken.safeTransferFrom(payer, receiverIfTakerIsSeller, sellerAssets);

        if (!wasLocked) liquidationLocked[id][taker] = false;
        require(liquidationLocked[id][taker] || _isHealthy(offer.market, id, taker), SellerIsLiquidatable());
        takeCount++;
    }

    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory) external {
        _checkAuthorized(onBehalf);
        require(callback == address(0), CallbackNotSupported());
        bytes32 id = touchMarket(market);
        _positions[id][onBehalf].debt -= units.toUint128();
        IERC20(market.loanToken).safeTransferFrom(msg.sender, address(this), units);
    }

    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external {
        _checkAuthorized(onBehalf);
        bytes32 id = touchMarket(market);
        CollateralParams memory params = market.collateralParams[collateralIndex];
        Position storage position = _positions[id][onBehalf];
        uint256 oldCollateral = position.collateral[collateralIndex];
        if (oldCollateral == 0 && assets > 0) {
            IOracle(params.oracle).price();
            require(_activatedCollaterals(market, id, onBehalf) < MAX_ACTIVATED_COLLATERALS, TooManyActivatedCollaterals());
        }
        position.collateral[collateralIndex] = (oldCollateral + assets).toUint128();
        IERC20(params.token).safeTransferFrom(msg.sender, address(this), assets);
    }

    function withdrawCollateral(
        Market memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        _checkAuthorized(onBehalf);
        bytes32 id = touchMarket(market);
        CollateralParams memory params = market.collateralParams[collateralIndex];
        _positions[id][onBehalf].collateral[collateralIndex] -= assets.toUint128();
        require(_isHealthy(market, id, onBehalf), UnhealthyBorrower());
        IERC20(params.token).safeTransfer(receiver, assets);
    }

    /// @notice Liquidates `borrower`. Exactly one of `seizedAssets` / `repaidUnits` must be non-zero in practice (at
    /// least one must be 0). The caller pays the repaid units and `receiver` gets the seized collateral.
    function liquidate(
        Market memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool postMaturityMode,
        address receiver,
        address callback,
        bytes memory
    ) external returns (uint256, uint256) {
        require(callback == address(0), CallbackNotSupported());
        bytes32 id = touchMarket(market);
        require(seizedAssets == 0 || repaidUnits == 0, InconsistentInput());
        Position storage position = _positions[id][borrower];
        require(position.debt > 0, NotBorrower());
        require(!liquidationLocked[id][borrower], NotLiquidatable());
        if (postMaturityMode) require(block.timestamp > market.maturity, NotLiquidatable());
        else require(!_isHealthy(market, id, borrower), NotLiquidatable());

        CollateralParams memory params = market.collateralParams[collateralIndex];
        uint256 price = IOracle(params.oracle).price();
        uint256 lif = liquidationIncentiveFactor(params.lltv, params.liquidationCursor, market.maturity, postMaturityMode);
        if (repaidUnits > 0) {
            seizedAssets = Math.mulDiv(Math.mulDiv(repaidUnits, lif, WAD), ORACLE_PRICE_SCALE, price);
        } else {
            repaidUnits = Math.mulDiv(
                Math.mulDiv(seizedAssets, price, ORACLE_PRICE_SCALE, Math.Rounding.Ceil),
                WAD,
                lif,
                Math.Rounding.Ceil
            );
        }

        position.debt -= repaidUnits.toUint128();
        position.collateral[collateralIndex] -= seizedAssets.toUint128();
        IERC20(params.token).safeTransfer(receiver, seizedAssets);
        IERC20(market.loanToken).safeTransferFrom(msg.sender, address(this), repaidUnits);
        return (seizedAssets, repaidUnits);
    }

    // ========== VIEWS ==========

    function debt(bytes32 id, address user) external view returns (uint128) {
        return _positions[id][user].debt;
    }

    function collateral(bytes32 id, address user, uint256 index) external view returns (uint128) {
        return _positions[id][user].collateral[index];
    }

    function credit(bytes32 id, address user) external view returns (uint128) {
        return _positions[id][user].credit;
    }

    function consumed(address user, bytes32 group) external view returns (uint128) {
        return _consumed[user][group];
    }

    function settlementFee(bytes32 id, uint256) public view returns (uint256) {
        require(_tickSpacing[id] != 0, MarketNotCreated());
        return _settlementFee[id];
    }

    function tickSpacing(bytes32 id) external view returns (uint8) {
        return _tickSpacing[id];
    }

    function continuousFee(bytes32 id) external view returns (uint32) {
        return _continuousFee[id];
    }

    function isHealthy(Market memory market, bytes32 id, address borrower) external view returns (bool) {
        return _isHealthy(market, id, borrower);
    }

    /// @notice `1 / (1 - cursor * (1 - lltv))`, rounded down.
    function maxLif(uint256 lltv, uint256 liquidationCursor) public pure returns (uint256) {
        return Math.mulDiv(WAD, WAD, WAD - Math.mulDiv(liquidationCursor, WAD - lltv, WAD));
    }

    function liquidationIncentiveFactor(
        uint256 lltv,
        uint256 liquidationCursor,
        uint256 maturity,
        bool postMaturityMode
    ) public view returns (uint256) {
        uint256 max = maxLif(lltv, liquidationCursor);
        if (!postMaturityMode) return max;
        uint256 elapsed = block.timestamp - maturity;
        return Math.min(max, WAD + Math.mulDiv(max - WAD, elapsed, TIME_TO_MAX_LIF));
    }

    // ========== INTERNAL ==========

    function _checkAuthorized(address onBehalf) internal view {
        require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender], Unauthorized());
    }

    function _consume(Offer memory offer, uint256 units, uint256 buyerAssets) internal {
        uint256 newConsumed = _consumed[offer.maker][offer.group] + (offer.maxAssets > 0 ? buyerAssets : units);
        if (offer.maxAssets > 0) require(newConsumed <= offer.maxAssets, ConsumedAssets());
        else require(newConsumed <= offer.maxUnits, ConsumedUnits());
        _consumed[offer.maker][offer.group] = newConsumed.toUint128();
    }

    /// @dev The seller's credit is used before its debt grows; the buyer's debt is reduced before its credit grows.
    function _settleUnits(Offer memory offer, bytes32 id, address seller, uint256 units) internal {
        Position storage sellerPosition = _positions[id][seller];
        uint256 creditUsed = Math.min(sellerPosition.credit, units);
        uint256 debtIncrease = units - creditUsed;
        require(block.timestamp <= offer.market.maturity || debtIncrease == 0, CannotIncreaseDebtPostMaturity());
        sellerPosition.credit -= creditUsed.toUint128();
        sellerPosition.debt += debtIncrease.toUint128();

        Position storage buyerPosition = _positions[id][offer.maker];
        uint256 debtRepaid = Math.min(buyerPosition.debt, units);
        uint256 creditIncrease = units - debtRepaid;
        require(!offer.reduceOnly || creditIncrease == 0, MakerCreditOrDebtIncreased());
        buyerPosition.debt -= debtRepaid.toUint128();
        buyerPosition.credit += creditIncrease.toUint128();
    }

    function _activatedCollaterals(Market memory market, bytes32 id, address user) internal view returns (uint256 count) {
        for (uint256 i; i < market.collateralParams.length; i++) {
            if (_positions[id][user].collateral[i] > 0) count++;
        }
    }

    function _isHealthy(Market memory market, bytes32 id, address borrower) internal view returns (bool) {
        Position storage position = _positions[id][borrower];
        uint256 debtUnits = position.debt;
        if (debtUnits == 0) return true;
        uint256 maxDebt;
        for (uint256 i; i < market.collateralParams.length; i++) {
            uint256 assets = position.collateral[i];
            if (assets == 0) continue;
            CollateralParams memory params = market.collateralParams[i];
            uint256 value = Math.mulDiv(assets, IOracle(params.oracle).price(), ORACLE_PRICE_SCALE);
            maxDebt += Math.mulDiv(value, params.lltv, WAD);
        }
        return debtUnits <= maxDebt;
    }
}
