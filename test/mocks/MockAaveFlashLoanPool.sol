// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFlashLoanReceiver} from "../../src/periphery/FlashLoanAave.sol";

/// @notice Minimal Aave v3 Pool flash loan for FlashLoanAave unit tests; it is also its own addresses provider.
/// @dev Mirrors the real pool where FlashLoanAave depends on it:
/// - the premium is `amount * FLASHLOAN_PREMIUM_TOTAL / 10_000` rounded up, like Aave's `percentMulCeil`;
/// - the `initiator` passed to `executeOperation` is the caller of `flashLoan`;
/// - with mode 0 the pool pulls `amount + premium` back from the receiver with `transferFrom` after the callback.
/// Other modes (opening a debt instead of repaying) are not supported.
contract MockAaveFlashLoanPool {
    using SafeERC20 for IERC20;

    uint128 public constant FLASHLOAN_PREMIUM_TOTAL = 5; // 0.05%, in basis points

    function getPool() external view returns (address) {
        return address(this);
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address,
        bytes calldata params,
        uint16
    ) external {
        uint256[] memory premiums = new uint256[](assets.length);
        for (uint256 i; i < assets.length; i++) {
            require(modes[i] == 0, "only mode 0 in mock");
            premiums[i] = Math.mulDiv(amounts[i], FLASHLOAN_PREMIUM_TOTAL, 10_000, Math.Rounding.Ceil);
            IERC20(assets[i]).safeTransfer(receiverAddress, amounts[i]);
        }

        bool success = IFlashLoanReceiver(receiverAddress).executeOperation(assets, amounts, premiums, msg.sender, params);
        require(success, "INVALID_FLASHLOAN_EXECUTOR_RETURN");

        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).safeTransferFrom(receiverAddress, address(this), amounts[i] + premiums[i]);
        }
    }
}
