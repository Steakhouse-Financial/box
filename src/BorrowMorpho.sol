// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Steakhouse Financial
pragma solidity ^0.8.13;

import {IBorrow} from "./interfaces/IBorrow.sol";
import {IMorpho, Id, MarketParams, Position} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MathLib} from "../lib/morpho-blue/src/libraries/MathLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import "@morpho-blue/libraries/ConstantsLib.sol";



contract BorrowMorpho is IBorrow {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using MathLib for uint256;

    function supplyCollateral(bytes calldata data, uint256 assets) external {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        IERC20(market.collateralToken).forceApprove(address(morpho), assets);
        morpho.supplyCollateral(market, assets, address(this), "");
    }

    function withdrawCollateral(bytes calldata data, uint256 assets) external {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        morpho.withdrawCollateral(market, assets, address(this), address(this));
    }

    function borrow(bytes calldata data, uint256 borrowAmount) external {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        morpho.borrow(market, borrowAmount, 0, address(this), address(this));
    }

    function repay(bytes calldata data, uint256 repayAmount) external {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);

        if(repayAmount == type(uint256).max) {
            repayAmount = debt(data, address(this));
            IERC20(market.loanToken).forceApprove(address(morpho), repayAmount);
            morpho.repay(market, 0, morpho.borrowShares(market.id(), address(this)), address(this), "");
        }
        else {
            IERC20(market.loanToken).forceApprove(address(morpho), repayAmount);
            morpho.repay(market, repayAmount, 0, address(this), "");
        }
    }

    function repayShares(bytes calldata data, uint256 shares) external {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        IERC20(market.loanToken).forceApprove(address(morpho), debt(data, address(this)));
        morpho.repay(market, 0, shares, address(this), "");
    }

    function loanToken(bytes calldata data) external view returns (address) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        return market.loanToken;
    }

    function collateralToken(bytes calldata data) external view returns (address) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        return market.collateralToken;
    }

    function ltv(bytes calldata data, address who) external view returns (uint256) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        Id marketId = market.id();
        uint256 borrowedAssets = morpho.expectedBorrowAssets(market, who);
        uint256 collateralAmount = morpho.collateral(marketId, who);
        uint256 collateralPrice = (market.oracle == address(0)) ? 0 : IOracle(market.oracle).price();
        uint256 collateralValue = collateralAmount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        return (collateralValue == 0) ? 0 : borrowedAssets.wDivUp(collateralValue);
    }

    function debt(bytes calldata data, address who) public view returns (uint256) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        return morpho.expectedBorrowAssets(market, who);
    }

    function debtShares(bytes calldata data, address who) external view returns (uint256) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        return morpho.borrowShares(market.id(), who);
    }

    function collateral(bytes calldata data, address who) external view returns (uint256) {
        (IMorpho morpho, MarketParams memory market) = dataToMorphoMarket(data);
        return morpho.collateral(market.id(), who);
    }

    function dataToMorphoMarket(bytes calldata data) public pure returns (IMorpho morpho, MarketParams memory market) {
        (address morphoAddress, MarketParams memory marketParams) = abi.decode(data, (address, MarketParams));
        return (IMorpho(morphoAddress), marketParams);
    }

    function morphoMarketToData(IMorpho morpho, MarketParams memory market) public pure returns (bytes memory) {
        return abi.encode(address(morpho), market);
    }
}