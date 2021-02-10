// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;


interface WalletInterface {
  event CallSuccess(
    bool rolledBack,
    address to,
    uint256 value,
    bytes data,
    bytes returnData
  );

  event CallFailure(
    address to,
    uint256 value,
    bytes data,
    string revertReason
  );

  // Use an array of Calls for executing generic batch calls.
  struct Call {
    address to;
    uint96 value;
    bytes data;
  }

  struct ValueReplacement {
      uint16 callIndex;
      uint24 returnDataOffset;
      bool perform;
  }

  struct DataReplacement {
      uint16 callIndex;
      uint24 returnDataOffset;
      uint24 callDataOffset;
  }

  struct AdvancedCall {
    address to;
    uint96 value;
    bytes data;
    ValueReplacement replaceValue;
    DataReplacement[] replaceData;
  }

  // Use an array of CallReturns for handling generic batch calls.
  struct CallReturn {
    bool ok;
    bytes returnData;
  }

  struct AdvancedCallReturn {
    bool ok;
    bytes returnData;
    uint96 callValue;
    bytes callData;
  }

  receive() external payable;

  function execute(
    Call[] calldata calls
  ) external returns (bool[] memory ok, bytes[] memory returnData);

  function executeAdvanced(
    AdvancedCall[] calldata calls
  ) external returns (bool[] memory ok, bytes[] memory returnData);

  function simulate(
    Call[] calldata calls
  ) external /* view */ returns (bool[] memory ok, bytes[] memory returnData);

  function simulateAdvanced(
    AdvancedCall[] calldata calls
  ) external /* view */ returns (bool[] memory ok, bytes[] memory returnData);
}


interface RevertReasonHelperInterface {
  function reason(uint256 code) external pure returns (string memory);
}


library Address {
  function isContract(address account) internal view returns (bool) {
    uint256 size;
    assembly { size := extcodesize(account) }
    return size > 0;
  }
}


contract Wallet is WalletInterface {
  using Address for address;

  bytes4 _selfCallContext;

  // The "revert reason helper" contains a collection of revert reason strings.
  RevertReasonHelperInterface internal constant _REVERT_REASON_HELPER = (
    RevertReasonHelperInterface(0xFc96814Ec38f6c19161f8Db168574099DaE06f2B)
  );

  address public immutable controller;

  constructor(address _controller) {
    controller = _controller;
  }

  receive() external payable override {}

  function execute(
    Call[] calldata calls
  ) external override returns (bool[] memory ok, bytes[] memory returnData) {
    require(msg.sender == controller, "Only controller may call this function.");

    // Ensure that each `to` address is a contract and is not this contract.
    for (uint256 i = 0; i < calls.length; i++) {
      if (calls[i].value == 0) {
        _ensureValidGenericCallTarget(calls[i].to);
      }
    }

    // Note: from this point on, there are no reverts (apart from out-of-gas or
    // call-depth-exceeded) originating from this contract. However, one of the
    // calls may revert, in which case the function will return `false`, along
    // with the revert reason encoded as bytes, and fire a CallFailure event.

    // Specify length of returned values in order to work with them in memory.
    ok = new bool[](calls.length);
    returnData = new bytes[](calls.length);

    // Set self-call context to call _execute.
    _selfCallContext = this.execute.selector;

    // Make the atomic self-call - if any call fails, calls that preceded it
    // will be rolled back and calls that follow it will not be made.
    (bool externalOk, bytes memory rawCallResults) = address(this).call(
      abi.encodeWithSelector(
        this._execute.selector, calls
      )
    );

    // Ensure that self-call context has been cleared.
    if (!externalOk) {
      delete _selfCallContext;
    }

    // Parse data returned from self-call into each call result and store / log.
    CallReturn[] memory callResults = abi.decode(rawCallResults, (CallReturn[]));
    for (uint256 i = 0; i < callResults.length; i++) {
      Call memory currentCall = calls[i];

      // Set the status and the return data / revert reason from the call.
      ok[i] = callResults[i].ok;
      returnData[i] = callResults[i].returnData;

      // Emit CallSuccess or CallFailure event based on the outcome of the call.
      if (callResults[i].ok) {
        // Note: while the call succeeded, the action may still have "failed".
        emit CallSuccess(
          !externalOk, // If another call failed this will have been rolled back
          currentCall.to,
          uint256(currentCall.value),
          currentCall.data,
          callResults[i].returnData
        );
      } else {
        // Note: while the call failed, the nonce will still be incremented,
        // which will invalidate all supplied signatures.
        emit CallFailure(
          currentCall.to,
          uint256(currentCall.value),
          currentCall.data,
          _decodeRevertReason(callResults[i].returnData)
        );

        // exit early - any calls after the first failed call will not execute.
        break;
      }
    }
  }

  function _execute(
    Call[] calldata calls
  ) external returns (CallReturn[] memory callResults) {
    // Ensure caller is this contract and self-call context is correctly set.
    _enforceSelfCallFrom(this.execute.selector);

    bool rollBack = false;
    callResults = new CallReturn[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      // Perform low-level call and set return values using result.
      (bool ok, bytes memory returnData) = calls[i].to.call{
        value: uint256(calls[i].value)
      }(calls[i].data);
      callResults[i] = CallReturn({ok: ok, returnData: returnData});
      if (!ok) {
        // Exit early - any calls after the first failed call will not execute.
        rollBack = true;
        break;
      }
    }

    if (rollBack) {
      // Wrap in length encoding and revert (provide bytes instead of a string).
      bytes memory callResultsBytes = abi.encode(callResults);
      assembly { revert(add(32, callResultsBytes), mload(callResultsBytes)) }
    }
  }

  function executeAdvanced(
    AdvancedCall[] calldata calls
  ) external override returns (bool[] memory ok, bytes[] memory returnData) {
    require(msg.sender == controller, "Only controller may call this function.");

    // Ensure that each `to` address is a contract and is not this contract.
    for (uint256 i = 0; i < calls.length; i++) {
      if (calls[i].value == 0) {
        _ensureValidGenericCallTarget(calls[i].to);
      }
    }

    // Note: from this point on, there are no reverts (apart from out-of-gas or
    // call-depth-exceeded) originating from this contract. However, one of the
    // calls may revert, in which case the function will return `false`, along
    // with the revert reason encoded as bytes, and fire an CallFailure event.

    // Specify length of returned values in order to work with them in memory.
    ok = new bool[](calls.length);
    returnData = new bytes[](calls.length);

    // Set self-call context to call _executeAdvanced.
    _selfCallContext = this.executeAdvanced.selector;

    // Make the atomic self-call - if any call fails, calls that preceded it
    // will be rolled back and calls that follow it will not be made.
    (bool externalOk, bytes memory rawCallResults) = address(this).call(
      abi.encodeWithSelector(
        this._executeAdvanced.selector, calls
      )
    );

    // Ensure that self-call context has been cleared.
    if (!externalOk) {
      delete _selfCallContext;
    }

    // Parse data returned from self-call into each call result and store / log.
    AdvancedCallReturn[] memory callResults = abi.decode(rawCallResults, (AdvancedCallReturn[]));
    for (uint256 i = 0; i < callResults.length; i++) {
      AdvancedCall memory currentCall = calls[i];

      // Set the status and the return data / revert reason from the call.
      ok[i] = callResults[i].ok;
      returnData[i] = callResults[i].returnData;

      // Emit CallSuccess or CallFailure event based on the outcome of the call.
      if (callResults[i].ok) {
        // Note: while the call succeeded, the action may still have "failed".
        emit CallSuccess(
          !externalOk, // If another call failed this will have been rolled back
          currentCall.to,
          uint256(callResults[i].callValue),
          callResults[i].callData,
          callResults[i].returnData
        );
      } else {
        // Note: while the call failed, the nonce will still be incremented,
        // which will invalidate all supplied signatures.
        emit CallFailure(
          currentCall.to,
          uint256(callResults[i].callValue),
          callResults[i].callData,
          _decodeRevertReason(callResults[i].returnData)
        );

        // exit early - any calls after the first failed call will not execute.
        break;
      }
    }
  }

  function _executeAdvanced(
    AdvancedCall[] calldata calls
  ) external returns (AdvancedCallReturn[] memory callResults) {
    // Ensure caller is this contract and self-call context is correctly set.
    _enforceSelfCallFrom(this.executeAdvanced.selector);

    bool rollBack = false;
    callResults = new AdvancedCallReturn[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      AdvancedCall memory a = calls[i];
      uint256 callValue = uint256(a.value);
      bytes memory callData = a.data;

      // Note: this check could (should?) be performed prior to execution.
      if (a.replaceValue.perform) {
        if (i <= a.replaceValue.callIndex) {
          revert(_revertReason(36));
        }

        uint256 returnOffset = a.replaceValue.returnDataOffset;
        bytes memory resultsAtIndex = callResults[a.replaceValue.callIndex].returnData;

        if (resultsAtIndex.length < returnOffset + 32) {
          revert(_revertReason(37));
        }

        // TODO: this can be made much more efficient via assembly
        bytes memory valueData = new bytes(32);
        for (uint256 k = 0; k < 32; k++) {
            valueData[k] = resultsAtIndex[returnOffset + k];
        }
        callValue = abi.decode(valueData, (uint256));
      }

      for (uint256 j = 0; j < a.replaceData.length; j++) {
        if (i <= a.replaceData[j].callIndex) {
          revert(_revertReason(38));
        }

        uint256 callOffset = a.replaceData[j].callDataOffset;
        uint256 returnOffset = a.replaceData[j].returnDataOffset;
        bytes memory resultsAtIndex = callResults[a.replaceData[j].callIndex].returnData;

        if (resultsAtIndex.length < returnOffset + 32) {
          revert(_revertReason(37));
        }

        for (uint256 k = 0; k < 32; k++) {
            callData[callOffset + k] = resultsAtIndex[returnOffset + k];
        }
      }

      // Perform low-level call and set return values using result.
      (bool ok, bytes memory returnData) = a.to.call{value: callValue}(callData);
      callResults[i] = AdvancedCallReturn({
          ok: ok,
          returnData: returnData,
          callValue: uint96(callValue),
          callData: callData
      });
      if (!ok) {
        // Exit early - any calls after the first failed call will not execute.
        rollBack = true;
        break;
      }
    }

    if (rollBack) {
      // Wrap in length encoding and revert (provide bytes instead of a string).
      bytes memory callResultsBytes = abi.encode(callResults);
      assembly { revert(add(32, callResultsBytes), mload(callResultsBytes)) }
    }
  }

  function simulate(
    Call[] calldata calls
  ) external /* view */ override returns (bool[] memory ok, bytes[] memory returnData) {
    // Ensure that each `to` address is a contract and is not this contract.
    for (uint256 i = 0; i < calls.length; i++) {
      if (calls[i].value == 0) {
        _ensureValidGenericCallTarget(calls[i].to);
      }
    }

    // Specify length of returned values in order to work with them in memory.
    ok = new bool[](calls.length);
    returnData = new bytes[](calls.length);

    // Set self-call context to call _simulateActionWithAtomicBatchCallsAtomic.
    _selfCallContext = this.simulate.selector;

    // Make the atomic self-call - if any call fails, calls that preceded it
    // will be rolled back and calls that follow it will not be made.
    (bool mustBeFalse, bytes memory rawCallResults) = address(this).call(
      abi.encodeWithSelector(
        this._simulate.selector, calls
      )
    );

    // Note: this should never be the case, but check just to be extra safe.
    if (mustBeFalse) {
      revert(_revertReason(35));
    }

    // Ensure that self-call context has been cleared.
    delete _selfCallContext;

    // Parse data returned from self-call into each call result and store / log.
    CallReturn[] memory callResults = abi.decode(rawCallResults, (CallReturn[]));
    for (uint256 i = 0; i < callResults.length; i++) {
      // Set the status and the return data / revert reason from the call.
      ok[i] = callResults[i].ok;
      returnData[i] = callResults[i].returnData;

      if (!callResults[i].ok) {
        // exit early - any calls after the first failed call will not execute.
        break;
      }
    }
  }

  function _simulate(
    Call[] calldata calls
  ) external returns (CallReturn[] memory callResults) {
    // Ensure caller is this contract and self-call context is correctly set.
    _enforceSelfCallFrom(this.simulate.selector);

    callResults = new CallReturn[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      // Perform low-level call and set return values using result.
      (bool ok, bytes memory returnData) = calls[i].to.call{
        value: uint256(calls[i].value)
      }(calls[i].data);
      callResults[i] = CallReturn({ok: ok, returnData: returnData});
      if (!ok) {
        // Exit early - any calls after the first failed call will not execute.
        break;
      }
    }

    // Wrap in length encoding and revert (provide bytes instead of a string).
    bytes memory callResultsBytes = abi.encode(callResults);
    assembly { revert(add(32, callResultsBytes), mload(callResultsBytes)) }
  }

  function simulateAdvanced(
    AdvancedCall[] calldata calls
  ) external /* view */ override returns (bool[] memory ok, bytes[] memory returnData) {
    // Ensure that each `to` address is a contract and is not this contract.
    for (uint256 i = 0; i < calls.length; i++) {
      if (calls[i].value == 0) {
        _ensureValidGenericCallTarget(calls[i].to);
      }
    }

    // Specify length of returned values in order to work with them in memory.
    ok = new bool[](calls.length);
    returnData = new bytes[](calls.length);

    // Set self-call context to call _simulateActionWithAtomicBatchCallsAtomic.
    _selfCallContext = this.simulateAdvanced.selector;

    // Make the atomic self-call - if any call fails, calls that preceded it
    // will be rolled back and calls that follow it will not be made.
    (bool mustBeFalse, bytes memory rawCallResults) = address(this).call(
      abi.encodeWithSelector(
        this._simulateAdvanced.selector, calls
      )
    );

    // Note: this should never be the case, but check just to be extra safe.
    if (mustBeFalse) {
      revert(_revertReason(35));
    }

    // Ensure that self-call context has been cleared.
    delete _selfCallContext;

    // Parse data returned from self-call into each call result and store / log.
    CallReturn[] memory callResults = abi.decode(rawCallResults, (CallReturn[]));
    for (uint256 i = 0; i < callResults.length; i++) {
      // Set the status and the return data / revert reason from the call.
      ok[i] = callResults[i].ok;
      returnData[i] = callResults[i].returnData;

      if (!callResults[i].ok) {
        // exit early - any calls after the first failed call will not execute.
        break;
      }
    }
  }

  function _simulateAdvanced(
    AdvancedCall[] calldata calls
  ) external returns (CallReturn[] memory callResults) {
    // Ensure caller is this contract and self-call context is correctly set.
    _enforceSelfCallFrom(this.simulateAdvanced.selector);

    callResults = new CallReturn[](calls.length);

    for (uint256 i = 0; i < calls.length; i++) {
      AdvancedCall memory a = calls[i];
      uint256 callValue = uint256(a.value);
      bytes memory callData = a.data;

      // Note: this check could (should?) be performed prior to execution.
      if (a.replaceValue.perform) {
        if (i <= a.replaceValue.callIndex) {
          revert(_revertReason(36));
        }

        uint256 returnOffset = a.replaceValue.returnDataOffset;
        bytes memory resultsAtIndex = callResults[a.replaceValue.callIndex].returnData;

        if (resultsAtIndex.length < returnOffset + 32) {
          revert(_revertReason(37));
        }

        // TODO: this can be made much more efficient via assembly
        bytes memory valueData = new bytes(32);
        for (uint256 k = 0; k < 32; k++) {
            valueData[k] = resultsAtIndex[returnOffset + k];
        }
        callValue = abi.decode(valueData, (uint256));
      }

      for (uint256 j = 0; j < a.replaceData.length; j++) {
        if (i <= a.replaceData[j].callIndex) {
          revert(_revertReason(38));
        }

        uint256 callOffset = a.replaceData[j].callDataOffset;
        uint256 returnOffset = a.replaceData[j].returnDataOffset;
        bytes memory resultsAtIndex = callResults[a.replaceData[j].callIndex].returnData;

        if (resultsAtIndex.length < returnOffset + 32) {
          revert(_revertReason(37));
        }

        for (uint256 k = 0; k < 32; k++) {
            callData[callOffset + k] = resultsAtIndex[returnOffset + k];
        }
      }

      // Perform low-level call and set return values using result.
      (bool ok, bytes memory returnData) = a.to.call{value: callValue}(callData);
      callResults[i] = CallReturn({ok: ok, returnData: returnData});
      if (!ok) {
        // Exit early - any calls after the first failed call will not execute.
        break;
      }
    }

    // Wrap in length encoding and revert (provide bytes instead of a string).
    bytes memory callResultsBytes = abi.encode(callResults);
    assembly { revert(add(32, callResultsBytes), mload(callResultsBytes)) }
  }

  function _enforceSelfCallFrom(bytes4 selfCallContext) internal {
    // Ensure caller is this contract and self-call context is correctly set.
    if (msg.sender != address(this) || _selfCallContext != selfCallContext) {
      revert(_revertReason(25));
    }

    // Clear the self-call context.
    delete _selfCallContext;
  }

  function _ensureValidGenericCallTarget(address to) internal view {
    if (!to.isContract()) {
      revert(_revertReason(26));
    }

    if (to == address(this)) {
      revert(_revertReason(27));
    }
  }

  function _decodeRevertReason(
    bytes memory revertData
  ) internal pure returns (string memory revertReason) {
    // Solidity prefixes revert reason with 0x08c379a0 -> Error(string) selector
    if (
      revertData.length > 68 && // prefix (4) + position (32) + length (32)
      revertData[0] == bytes1(0x08) &&
      revertData[1] == bytes1(0xc3) &&
      revertData[2] == bytes1(0x79) &&
      revertData[3] == bytes1(0xa0)
    ) {
      // Get the revert reason without the prefix from the revert data.
      bytes memory revertReasonBytes = new bytes(revertData.length - 4);
      for (uint256 i = 4; i < revertData.length; i++) {
        revertReasonBytes[i - 4] = revertData[i];
      }

      // Decode the resultant revert reason as a string.
      revertReason = abi.decode(revertReasonBytes, (string));
    } else {
      // Simply return the default, with no revert reason.
      revertReason = _revertReason(type(uint256).max);
    }
  }

  function _revertReason(
    uint256 code
  ) internal pure returns (string memory reason) {
    reason = _REVERT_REASON_HELPER.reason(code);
  }
}