// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Non-transferable balance token standing in for an Aave v3 aToken or variable debt token.
contract MockAaveV3BalanceToken {
    address public immutable pool;
    mapping(address account => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor() {
        pool = msg.sender;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        balanceOf[account] += amount;
        totalSupply += amount;
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == pool, "only pool");
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }
}

/// @notice Minimal Aave v3 Pool for FundingAave unit tests.
/// @dev Mirrors the real pool where FundingAave depends on it:
/// - `getReserveData` never reverts; for an asset that is not a reserve it returns `aTokenAddress == 0` and
///   `variableDebtTokenAddress == 0` but NON-zero `stableDebtTokenAddress` and `interestRateStrategyAddress`
///   (the Ethereum pool at block 23,294,087 does exactly this), so a module must check the two specific fields;
/// - supply/borrow of an unlisted asset and zero amounts revert; withdraw/repay accept `type(uint256).max`;
/// - withdraw above the supplied balance reverts; repay caps at the debt and returns the amount repaid;
/// - borrowed tokens go to `msg.sender` (no credit delegation), withdrawn tokens go to `to`;
/// - borrow and withdraw revert when the position would exceed `maxLtvBps` (priced with `setAssetPrice`, 8 decimals).
/// Interest is simulated with `accrueDebt`.
contract MockAaveV3Pool {
    using SafeERC20 for IERC20;

    address public constant STABLE_DEBT_TOKEN = address(0x102633152313C81cD80419b6EcF66d14Ad68949A);
    address public constant INTEREST_RATE_STRATEGY = address(0x9ec6F08190DeA04A54f8Afc53Db96134e5E3FdFB);
    uint256 public constant MAX_LTV_BPS = 8000;
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8500;

    struct Reserve {
        address aToken;
        address variableDebtToken;
        uint16 id;
        uint8 decimals;
        uint256 price; // 8 decimals, like the Aave oracle base currency
    }

    mapping(address asset => Reserve) public reserves;
    address[] public reservesList;
    mapping(address user => uint256) public userEMode;
    mapping(address user => mapping(address asset => bool)) public usingAsCollateral;

    // ========== TEST SETUP ==========

    function listReserve(address asset, uint256 price) external returns (address aToken, address variableDebtToken) {
        require(reserves[asset].aToken == address(0), "already listed");
        aToken = address(new MockAaveV3BalanceToken());
        variableDebtToken = address(new MockAaveV3BalanceToken());
        reserves[asset] = Reserve(aToken, variableDebtToken, uint16(reservesList.length), IERC20Metadata(asset).decimals(), price);
        reservesList.push(asset);
    }

    /// @dev Overrides the two reserve token addresses, e.g. to model a reserve with only one of them set.
    function setReserveTokens(address asset, address aToken, address variableDebtToken) external {
        reserves[asset].aToken = aToken;
        reserves[asset].variableDebtToken = variableDebtToken;
    }

    function setAssetPrice(address asset, uint256 price) external {
        reserves[asset].price = price;
    }

    /// @dev Simulates interest by minting debt without moving tokens.
    function accrueDebt(address user, address asset, uint256 amount) external {
        MockAaveV3BalanceToken(reserves[asset].variableDebtToken).mint(user, amount);
    }

    // ========== POOL ==========

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        Reserve memory r = _listed(asset);
        require(amount != 0, "INVALID_AMOUNT");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        MockAaveV3BalanceToken(r.aToken).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        Reserve memory r = _listed(asset);
        uint256 balance = MockAaveV3BalanceToken(r.aToken).balanceOf(msg.sender);
        if (amount == type(uint256).max) amount = balance;
        require(amount != 0, "INVALID_AMOUNT");
        require(amount <= balance, "NOT_ENOUGH_AVAILABLE_USER_BALANCE");
        MockAaveV3BalanceToken(r.aToken).burn(msg.sender, amount);
        if (MockAaveV3BalanceToken(r.aToken).balanceOf(msg.sender) == 0) usingAsCollateral[msg.sender][asset] = false;
        _requireHealthy(msg.sender);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16, address onBehalfOf) external {
        Reserve memory r = _listed(asset);
        require(amount != 0, "INVALID_AMOUNT");
        require(interestRateMode == 2, "INVALID_INTEREST_RATE_MODE_SELECTED");
        require(onBehalfOf == msg.sender, "no credit delegation in mock");
        MockAaveV3BalanceToken(r.variableDebtToken).mint(onBehalfOf, amount);
        _requireHealthy(onBehalfOf);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256) {
        Reserve memory r = _listed(asset);
        require(amount != 0, "INVALID_AMOUNT");
        require(interestRateMode == 2, "INVALID_INTEREST_RATE_MODE_SELECTED");
        uint256 debt = MockAaveV3BalanceToken(r.variableDebtToken).balanceOf(onBehalfOf);
        require(debt != 0, "NO_DEBT_OF_SELECTED_TYPE");
        uint256 paid = amount < debt ? amount : debt;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), paid);
        MockAaveV3BalanceToken(r.variableDebtToken).burn(onBehalfOf, paid);
        return paid;
    }

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external {
        Reserve memory r = _listed(asset);
        require(MockAaveV3BalanceToken(r.aToken).balanceOf(msg.sender) != 0, "UNDERLYING_BALANCE_ZERO");
        usingAsCollateral[msg.sender][asset] = useAsCollateral;
        if (!useAsCollateral) _requireHealthy(msg.sender);
    }

    function setUserEMode(uint8 categoryId) external {
        userEMode[msg.sender] = categoryId;
    }

    function getUserEMode(address user) external view returns (uint256) {
        return userEMode[user];
    }

    function getUserAccountData(
        address user
    )
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        for (uint256 i; i < reservesList.length; i++) {
            address asset = reservesList[i];
            Reserve memory r = reserves[asset];
            uint256 unit = 10 ** r.decimals;
            if (r.aToken != address(0) && usingAsCollateral[user][asset]) {
                totalCollateralBase += (MockAaveV3BalanceToken(r.aToken).balanceOf(user) * r.price) / unit;
            }
            if (r.variableDebtToken != address(0)) {
                uint256 debt = MockAaveV3BalanceToken(r.variableDebtToken).balanceOf(user);
                totalDebtBase += (debt * r.price + unit - 1) / unit;
            }
        }
        uint256 maxDebt = (totalCollateralBase * MAX_LTV_BPS) / 1e4;
        availableBorrowsBase = maxDebt > totalDebtBase ? maxDebt - totalDebtBase : 0;
        currentLiquidationThreshold = totalCollateralBase == 0 ? 0 : LIQUIDATION_THRESHOLD_BPS;
        ltv = totalCollateralBase == 0 ? 0 : MAX_LTV_BPS;
        healthFactor = totalDebtBase == 0 ? type(uint256).max : (totalCollateralBase * LIQUIDATION_THRESHOLD_BPS * 1e14) / totalDebtBase;
    }

    function getReserveData(
        address asset
    )
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        )
    {
        Reserve memory r = reserves[asset];
        if (r.aToken != address(0) || r.variableDebtToken != address(0)) {
            liquidityIndex = 1e27;
            variableBorrowIndex = 1e27;
            lastUpdateTimestamp = uint40(block.timestamp);
            id = r.id;
        }
        aTokenAddress = r.aToken;
        stableDebtTokenAddress = STABLE_DEBT_TOKEN;
        variableDebtTokenAddress = r.variableDebtToken;
        interestRateStrategyAddress = INTEREST_RATE_STRATEGY;
    }

    // ========== INTERNAL ==========

    function _listed(address asset) internal view returns (Reserve memory r) {
        r = reserves[asset];
        require(r.aToken != address(0) && r.variableDebtToken != address(0), "RESERVE_INACTIVE");
    }

    function _requireHealthy(address user) internal view {
        (uint256 collateralBase, uint256 debtBase, , , , ) = getUserAccountData(user);
        require(debtBase * 1e4 <= collateralBase * MAX_LTV_BPS, "COLLATERAL_CANNOT_COVER_NEW_BORROW");
    }
}
