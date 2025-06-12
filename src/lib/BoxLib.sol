// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Box} from "src/Box.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

library BoxLib {
    /// @notice Adds a feeder to a Box instance, assume 0-day timelocks
    function addFeeder(Box box, address feeder) internal {
        bytes memory encoding = abi.encodeWithSelector(
            box.setIsFeeder.selector,
            address(feeder),
            true
        );
        box.submit(encoding);
        box.setIsFeeder(address(feeder), true);
    }


    function addCollateral(Box box, IERC20 token, IOracle oracle) internal {
        bytes memory encoding = abi.encodeWithSelector(
            box.addInvestmentToken.selector,
            address(token),
            address(oracle)
        );
        box.submit(encoding);
        box.addInvestmentToken(token, oracle);
    }
}
