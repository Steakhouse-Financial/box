// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Steakhouse Financial
pragma solidity ^0.8.28;

interface IMockController {
    function checkAccountStatus(address account, address[] calldata collaterals) external view returns (bytes4);
}

/// @notice Ethereum Vault Connector mock for unit tests. Written from the documented EVC behaviour, not from EVC code.
/// @dev Semantics reproduced:
/// - accounts sharing the first 19 bytes form one owner group; the owner is registered on the first authenticated call
///   from an address of the group, and every later call for any account of the group must come from that owner
///   (`EVC_NotAuthorized` otherwise, so a wrong `owner ^ id` derivation fails);
/// - collateral and controller sets per account, with idempotent enable/disable;
/// - `call` authenticates, sets the on-behalf-of account for the target, bubbles the target's revert data and runs the
///   deferred account status checks when the outermost frame exits; direct calls outside a frame check immediately;
/// - an account check fails with `EVC_ControllerViolation` for more than one controller and otherwise asks the
///   controller (the borrow vault) to validate the account;
/// - `disableController(account)` can only be called by the controller vault itself;
/// - operators and permits are not supported: `setOperator`, `setAccountOperator` and `permit` always revert.
contract MockEVC {
    error EVC_NotAuthorized();
    error EVC_InvalidAddress();
    error EVC_ControllerViolation();
    error EVC_InvalidValue();
    error EVC_OnBehalfOfAccountNotAuthenticated();
    error AuthorisationsNotSupported();

    struct CallRecord {
        address caller;
        address target;
        address onBehalfOf;
        bytes data;
    }

    mapping(bytes19 prefix => address) internal owners;
    mapping(address account => address[]) internal collaterals;
    mapping(address account => address[]) internal controllers;

    address internal onBehalfOf;
    uint256 internal depth;
    address[] internal deferredChecks;

    CallRecord[] internal callRecords;
    uint256 public enableCollateralCount;
    uint256 public enableControllerCount;

    // ========== AUTHORISATIONS (never supported) ==========

    function setOperator(bytes19, address, uint256) external payable {
        revert AuthorisationsNotSupported();
    }

    function setAccountOperator(address, address, bool) external payable {
        revert AuthorisationsNotSupported();
    }

    function permit(address, address, uint256, uint256, uint256, uint256, bytes calldata, bytes calldata) external payable {
        revert AuthorisationsNotSupported();
    }

    // ========== COLLATERALS AND CONTROLLERS ==========

    function enableCollateral(address account, address vault) external payable {
        _authenticate(account);
        require(vault != address(this), EVC_InvalidAddress());
        enableCollateralCount++;
        if (!_contains(collaterals[account], vault)) collaterals[account].push(vault);
        _requireAccountStatusCheck(account);
    }

    function disableCollateral(address account, address vault) external payable {
        _authenticate(account);
        _remove(collaterals[account], vault);
        _requireAccountStatusCheck(account);
    }

    function enableController(address account, address vault) external payable {
        _authenticate(account);
        require(vault != address(this), EVC_InvalidAddress());
        enableControllerCount++;
        if (!_contains(controllers[account], vault)) controllers[account].push(vault);
        _requireAccountStatusCheck(account);
    }

    /// @dev Only the controller vault can remove itself
    function disableController(address account) external payable {
        _remove(controllers[account], msg.sender);
        _requireAccountStatusCheck(account);
    }

    function requireAccountStatusCheck(address account) external payable {
        _requireAccountStatusCheck(account);
    }

    // ========== CALL ==========

    function call(
        address targetContract,
        address onBehalfOfAccount,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory) {
        require(value == 0, EVC_InvalidValue());
        require(targetContract != address(this), EVC_InvalidAddress());
        if (targetContract != msg.sender) _authenticate(onBehalfOfAccount);

        callRecords.push(CallRecord(msg.sender, targetContract, onBehalfOfAccount, data));

        address previous = onBehalfOf;
        onBehalfOf = onBehalfOfAccount;
        depth++;
        (bool success, bytes memory result) = targetContract.call(data);
        depth--;
        onBehalfOf = previous;

        if (!success) {
            assembly ("memory-safe") {
                revert(add(32, result), mload(result))
            }
        }
        if (depth == 0) _runDeferredChecks();
        return result;
    }

    /// @notice The account on whose behalf the current `call` frame runs
    function getCurrentOnBehalfOfAccount(address) external view returns (address, bool) {
        require(depth > 0, EVC_OnBehalfOfAccountNotAuthenticated());
        return (onBehalfOf, false);
    }

    // ========== VIEWS ==========

    function isCollateralEnabled(address account, address vault) external view returns (bool) {
        return _contains(collaterals[account], vault);
    }

    function isControllerEnabled(address account, address vault) external view returns (bool) {
        return _contains(controllers[account], vault);
    }

    function getCollaterals(address account) external view returns (address[] memory) {
        return collaterals[account];
    }

    function getControllers(address account) external view returns (address[] memory) {
        return controllers[account];
    }

    function getAccountOwner(address account) external view returns (address) {
        return owners[_prefix(account)];
    }

    function callCount() external view returns (uint256) {
        return callRecords.length;
    }

    function callAt(uint256 index) external view returns (CallRecord memory) {
        return callRecords[index];
    }

    function lastCall() external view returns (CallRecord memory) {
        return callRecords[callRecords.length - 1];
    }

    // ========== INTERNAL ==========

    function _authenticate(address account) internal {
        bytes19 prefix = _prefix(account);
        address registered = owners[prefix];
        if (registered == address(0)) {
            require(_prefix(msg.sender) == prefix, EVC_NotAuthorized());
            owners[prefix] = msg.sender;
        } else {
            require(registered == msg.sender, EVC_NotAuthorized());
        }
    }

    function _requireAccountStatusCheck(address account) internal {
        if (depth == 0) {
            _checkAccount(account);
        } else if (!_contains(deferredChecks, account)) {
            deferredChecks.push(account);
        }
    }

    function _runDeferredChecks() internal {
        while (deferredChecks.length > 0) {
            address account = deferredChecks[deferredChecks.length - 1];
            deferredChecks.pop();
            _checkAccount(account);
        }
    }

    function _checkAccount(address account) internal view {
        address[] storage accountControllers = controllers[account];
        if (accountControllers.length == 0) return;
        require(accountControllers.length == 1, EVC_ControllerViolation());
        bytes4 magic = IMockController(accountControllers[0]).checkAccountStatus(account, collaterals[account]);
        require(magic == IMockController.checkAccountStatus.selector, EVC_ControllerViolation());
    }

    function _prefix(address account) internal pure returns (bytes19) {
        return bytes19(uint152(uint160(account) >> 8));
    }

    function _contains(address[] storage list, address item) internal view returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == item) return true;
        }
        return false;
    }

    function _remove(address[] storage list, address item) internal {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == item) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }
}
