// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IERC4626} from "@vault-v2/src/interfaces/IERC4626.sol";
import {IERC20} from "@vault-v2/src/interfaces/IERC20.sol";
import {IERC4626Adapter} from "./IERC4626Adapter.sol";
import {SafeERC20Lib} from "@vault-v2/src/libraries/SafeERC20Lib.sol";

/// Vaults should transfer exactly the input in deposit and withdraw.
contract ERC4626Adapter is IERC4626Adapter {
    /* IMMUTABLES */

    address public immutable parentVault;
    address public immutable vault;

    /* STORAGE */

    address public skimRecipient;

    /* FUNCTIONS */

    constructor(address _parentVault, address _vault) {
        parentVault = _parentVault;
        vault = _vault;
        SafeERC20Lib.safeApprove(IVaultV2(_parentVault).asset(), _parentVault, type(uint256).max);
        SafeERC20Lib.safeApprove(IVaultV2(_parentVault).asset(), _vault, type(uint256).max);
    }

    function setSkimRecipient(address newSkimRecipient) external {
        require(msg.sender == IVaultV2(parentVault).owner(), NotAuthorized());
        skimRecipient = newSkimRecipient;
        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @dev Skims the adapter's balance of `token` and sends it to `skimRecipient`.
    /// @dev This is useful to handle rewards that the adapter has earned.
    function skim(address token) external {
        require(msg.sender == skimRecipient, NotAuthorized());
        require(token != vault, CannotSkimVault());
        uint256 balance = IERC20(token).balanceOf(address(this));
        SafeERC20Lib.safeTransfer(token, skimRecipient, balance);
        emit Skim(token, balance);
    }

    /// @dev Does not log anything because the ids (logged in the parent vault) are enough.
    /// @dev Returns the ids of the allocation.
    function allocate(bytes memory data, uint256 assets) external returns (bytes32[] memory, uint256 loss) {
        require(data.length == 0, InvalidData());
        require(msg.sender == parentVault, NotAuthorized());

        IERC4626(vault).deposit(assets, address(this));

        return (ids(), 0);
    }

    /// @dev Does not log anything because the ids (logged in the parent vault) are enough.
    /// @dev Returns the ids of the deallocation.
    function deallocate(bytes memory data, uint256 assets) external returns (bytes32[] memory, uint256 loss) {
        require(data.length == 0, InvalidData());
        require(msg.sender == parentVault, NotAuthorized());

        IERC4626(vault).withdraw(assets, address(this), address(this));

        return (ids(), 0);
    }

    /// @dev Returns adapter's ids.
    function ids() internal view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = keccak256(abi.encode("adapter", address(this)));
        return ids_;
    }

    /// @dev Returns adapter's ids.
    function id() public view returns (bytes32) {
        return keccak256(abi.encode("adapter", address(this)));
    }

    /// @dev Returns adapter's data.
    function data() public view returns (bytes memory) {
        return abi.encode("adapter", address(this));
    }
}