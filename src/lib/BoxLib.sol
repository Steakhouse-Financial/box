// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "src/Box.sol";
import {IBox} from "src/interfaces/IBox.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IFunding} from "src/interfaces/IFunding.sol";


/// @dev Instant functions for Box governance actions, assuming 0-day timelocks
library BoxLib {
    function addFeederInstant(Box box, address feeder) internal {
        bytes memory encoding = abi.encodeWithSelector(
            box.setIsFeeder.selector,
            feeder,
            true
        );
        box.submit(encoding);
        box.setIsFeeder(address(feeder), true);
    }

    function addTokenInstant(Box box, IERC20 token, IOracle oracle) internal {
        bytes memory encoding = abi.encodeWithSelector(
            box.addToken.selector,
            address(token),
            address(oracle)
        );
        box.submit(encoding);
        box.addToken(token, oracle);
    }

    function setGuardianInstant(Box box, address guardian) internal {
        bytes memory encoding = abi.encodeWithSelector(box.setGuardian.selector, guardian);
        box.submit(encoding);
        box.setGuardian(guardian);
    }

    function addFundingInstant(Box box, IFunding fundingModule) internal {
        bytes memory encoding = abi.encodeWithSelector(
            IBox.addFunding.selector,
            address(fundingModule)
        );
        box.submit(encoding);
        box.addFunding(fundingModule);
    }

    function addFundingFacilityInstant(Box box, IFunding fundingModule, bytes memory facilityData) internal {
        bytes memory encoding = abi.encodeWithSelector(
            IBox.addFundingFacility.selector,
            address(fundingModule),
            facilityData
        );
        box.submit(encoding);
        box.addFundingFacility(fundingModule, facilityData);
    }

    function addFundingCollateralInstant(Box box, IFunding fundingModule, IERC20 collateralToken) internal {
        bytes memory encoding = abi.encodeWithSelector(
            IBox.addFundingCollateral.selector,
            address(fundingModule),
            address(collateralToken)
        );
        box.submit(encoding);
        box.addFundingCollateral(fundingModule, collateralToken);
    }

    function addFundingDebtInstant(Box box, IFunding fundingModule, IERC20 debtToken) internal {
        bytes memory encoding = abi.encodeWithSelector(
            IBox.addFundingDebt.selector,
            address(fundingModule),
            address(debtToken)
        );
        box.submit(encoding);
        box.addFundingDebt(fundingModule, debtToken);
    }
}