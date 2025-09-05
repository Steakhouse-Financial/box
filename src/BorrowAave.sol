// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IBorrow} from "./interfaces/IBorrow.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MathLib} from "@morpho-blue/libraries/MathLib.sol";


interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function setUserEMode(uint8 categoryId) external;
    function getUserEMode(address user) external view returns (uint256);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    function getReserveData(address asset)
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
        );

    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);
}

interface IScaledBalanceToken {
    function scaledBalanceOf(address user) external view returns (uint256);
}


contract BorrowAave is IBorrow {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    uint256 internal constant RAY = 1e27;

    // interestRateMode: 1 = Stable, 2 = Variable (Aave v3 constant)

    function supplyCollateral(bytes calldata data, uint256 assets) external {
        (IPool pool, , address collateralAsset, , uint8 eMode) = dataToAaveParams(data);

        // Set e-mode if specified (0 means no e-mode)
        if (eMode > 0 && pool.getUserEMode(address(this)) != eMode) {
            pool.setUserEMode(eMode);
        }

        IERC20(collateralAsset).forceApprove(address(pool), assets);
        pool.supply(collateralAsset, assets, address(this), 0);
        pool.setUserUseReserveAsCollateral(collateralAsset, true);
    }

    function withdrawCollateral(bytes calldata data, uint256 assets) external {
        (IPool pool, , address collateralAsset, ,) = dataToAaveParams(data);
        pool.withdraw(collateralAsset, assets, address(this));
    }

    function borrow(bytes calldata data, uint256 borrowAmount) external {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);
        pool.borrow(loanAsset, borrowAmount, rateMode, 0, address(this));
    }

    function repay(bytes calldata data, uint256 repayAmount) external {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);
        IERC20(loanAsset).forceApprove(address(pool), repayAmount);
        pool.repay(loanAsset, repayAmount, rateMode, address(this));
    }

    function repayShares(bytes calldata data, uint256 shares) external {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);

        uint256 repayAmount;
        if (rateMode == 2) {
            // Variable debt: shares are scaledBalance; convert to amount using normalized variable debt index
            uint256 normalizedIndex = pool.getReserveNormalizedVariableDebt(loanAsset); // RAY-scaled
            repayAmount = shares.mulDivUp(normalizedIndex, RAY);
        } else {
            // Stable debt has no shares concept; interpret shares as amount
            repayAmount = shares;
        }

        IERC20(loanAsset).forceApprove(address(pool), repayAmount);
        pool.repay(loanAsset, repayAmount, rateMode, address(this));
    }

    function loanToken(bytes calldata data) external pure returns (address) {
        (, address loanAsset, , ,) = dataToAaveParams(data);
        return loanAsset;
    }

    function collateralToken(bytes calldata data) external pure returns (address) {
        (, , address collateralAsset, ,) = dataToAaveParams(data);
        return collateralAsset;
    }

    function ltv(bytes calldata data, address who) external view returns (uint256) {
        (IPool pool, , , ,) = dataToAaveParams(data);
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            ,
            ,
            ,
            
        ) = pool.getUserAccountData(who);

        return totalCollateralBase == 0 ? 0 : totalDebtBase.wDivUp(totalCollateralBase);
    }

    function debt(bytes calldata data, address who) public view returns (uint256) {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);
        (,,,,,,,, , address stableDebtToken, address variableDebtToken,,,,) = pool.getReserveData(loanAsset);
        address debtToken = rateMode == 2 ? variableDebtToken : stableDebtToken;
        return IERC20(debtToken).balanceOf(who);
    }

    function debtShares(bytes calldata data, address who) external view returns (uint256) {
        (IPool pool, address loanAsset, , uint256 rateMode,) = dataToAaveParams(data);
        if (rateMode == 2) {
            (,,,,,,,, , , address variableDebtToken,,,,) = pool.getReserveData(loanAsset);
            return IScaledBalanceToken(variableDebtToken).scaledBalanceOf(who);
        } else {
            (,,,,,,,, , address stableDebtToken, ,,,,) = pool.getReserveData(loanAsset);
            return IERC20(stableDebtToken).balanceOf(who);
        }
    }

    function collateral(bytes calldata data, address who) external view returns (uint256) {
        (IPool pool, , address collateralAsset, ,) = dataToAaveParams(data);
        (,,,,,,,, address aTokenAddress, , ,,,,) = pool.getReserveData(collateralAsset);
        return IERC20(aTokenAddress).balanceOf(who);
    }

    function dataToAaveParams(bytes calldata data)
        public
        pure
        returns (IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode, uint8 eMode)
    {
        // Check data length to determine format
        if (data.length == 160) { // 5 * 32 bytes for new format with e-mode
            (address poolAddress, address _loanAsset, address _collateralAsset, uint256 rateMode, uint8 _eMode) =
                abi.decode(data, (address, address, address, uint256, uint8));
            return (IPool(poolAddress), _loanAsset, _collateralAsset, rateMode, _eMode);
        } else { // Old format without e-mode
            (address poolAddress, address _loanAsset, address _collateralAsset, uint256 rateMode) =
                abi.decode(data, (address, address, address, uint256));
            return (IPool(poolAddress), _loanAsset, _collateralAsset, rateMode, 0);
        }
    }

    function aaveParamsToData(IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(address(pool), loanAsset, collateralAsset, interestRateMode);
    }
    
    function aaveParamsToDataWithEMode(IPool pool, address loanAsset, address collateralAsset, uint256 interestRateMode, uint8 eMode)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(address(pool), loanAsset, collateralAsset, interestRateMode, eMode);
    }
}


