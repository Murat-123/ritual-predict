// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    IScheduler,
    IRitualWallet,
    ITEEServiceRegistry
} from "../ritual/RitualChain.sol";

/// @dev Test-only scheduler installed at Ritual's canonical address with vm.etch.
contract MockScheduler is IScheduler {
    struct Call {
        address target;
        bytes data;
        uint32 gasLimit;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
        bool cancelled;
    }

    uint256 public nextCallId = 1;
    bool public revertOnCancel;
    mapping(address => bool) public approved;
    mapping(uint256 => Call) private _calls;

    function approveScheduler(address schedulerContract) external {
        approved[msg.sender] = schedulerContract == address(this);
    }

    function schedule(
        bytes calldata data,
        uint32 gasLimit,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId) {
        require(approved[msg.sender], "scheduler not approved");
        // vm.etch copies runtime code, not constructor-initialized storage.
        if (nextCallId == 0) nextCallId = 1;
        callId = nextCallId++;
        _calls[callId] = Call({
            target: msg.sender,
            data: data,
            gasLimit: gasLimit,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            ttl: ttl,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            payer: payer,
            cancelled: false
        });
    }

    function cancel(uint256 callId) external {
        if (revertOnCancel) revert("cancel failed");
        _calls[callId].cancelled = true;
    }

    function getCallState(uint256 callId) external view returns (uint8) {
        return _calls[callId].cancelled ? 3 : 0;
    }

    function setRevertOnCancel(bool value) external {
        revertOnCancel = value;
    }

    function getCall(
        uint256 callId
    )
        external
        view
        returns (
            address target,
            bytes memory data,
            uint32 gasLimit,
            uint32 startBlock,
            uint32 numCalls,
            uint32 frequency,
            uint32 ttl,
            uint256 maxFeePerGas,
            uint256 maxPriorityFeePerGas,
            uint256 value,
            address payer,
            bool cancelled
        )
    {
        Call storage c = _calls[callId];
        return (
            c.target,
            c.data,
            c.gasLimit,
            c.startBlock,
            c.numCalls,
            c.frequency,
            c.ttl,
            c.maxFeePerGas,
            c.maxPriorityFeePerGas,
            c.value,
            c.payer,
            c.cancelled
        );
    }

    function callTarget(uint256 callId) external view returns (address) {
        return _calls[callId].target;
    }

    function callData(uint256 callId) external view returns (bytes memory) {
        return _calls[callId].data;
    }

    function callGasLimit(uint256 callId) external view returns (uint32) {
        return _calls[callId].gasLimit;
    }

    function callStartBlock(uint256 callId) external view returns (uint32) {
        return _calls[callId].startBlock;
    }

    function callNumCalls(uint256 callId) external view returns (uint32) {
        return _calls[callId].numCalls;
    }

    function callFrequency(uint256 callId) external view returns (uint32) {
        return _calls[callId].frequency;
    }

    function callTtl(uint256 callId) external view returns (uint32) {
        return _calls[callId].ttl;
    }

    function callMaxFeePerGas(uint256 callId) external view returns (uint256) {
        return _calls[callId].maxFeePerGas;
    }

    function callMaxPriorityFeePerGas(
        uint256 callId
    ) external view returns (uint256) {
        return _calls[callId].maxPriorityFeePerGas;
    }

    function callValue(uint256 callId) external view returns (uint256) {
        return _calls[callId].value;
    }

    function callPayer(uint256 callId) external view returns (address) {
        return _calls[callId].payer;
    }

    /// @dev Simulates the Scheduler replacing calldata bytes 4-35 with executionIndex.
    function invoke(
        uint256 callId,
        uint256 executionIndex
    ) external returns (bool ok, bytes memory result) {
        Call storage c = _calls[callId];
        bytes memory data = c.data;
        require(data.length >= 36, "bad callback data");
        assembly {
            mstore(add(data, 36), executionIndex)
        }
        (ok, result) = c.target.call{value: c.value}(data);
    }
}

/// @dev Test-only RitualWallet installed at Ritual's canonical address with vm.etch.
contract MockRitualWallet is IRitualWallet {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public locks;

    function deposit(uint256 lockDuration) external payable {
        balances[msg.sender] += msg.value;
        uint256 lock = block.number + lockDuration;
        if (lock > locks[msg.sender]) locks[msg.sender] = lock;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function lockUntil(address account) external view returns (uint256) {
        return locks[account];
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }
}

/// @dev Test-only TEE registry installed at Ritual's canonical address with vm.etch.
contract MockTEEServiceRegistry is ITEEServiceRegistry {
    address public executor;
    bool public available;

    function setExecutor(address executor_, bool available_) external {
        executor = executor_;
        available = available_;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external view returns (address teeAddress, bool found) {
        return (executor, available);
    }
}

/// @dev Test-only HTTP precompile installed at 0x0801 with vm.etch.
contract MockHttpPrecompile {
    bool public shouldRevert;
    bool public malformed;
    uint16 public status = 200;
    string public body = "{}";
    string public errorMessage;
    bytes private _lastInput;

    function setResponse(
        uint16 status_,
        string calldata body_,
        string calldata errorMessage_
    ) external {
        status = status_;
        body = body_;
        errorMessage = errorMessage_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setMalformed(bool value) external {
        malformed = value;
    }

    fallback(bytes calldata input) external returns (bytes memory output) {
        if (shouldRevert) revert("HTTP failed");
        if (malformed) return hex"deadbeef";
        _lastInput = input;

        string[] memory headers = new string[](0);
        bytes memory actualOutput = abi.encode(
            status,
            headers,
            headers,
            bytes(body),
            errorMessage
        );
        return abi.encode(bytes(""), actualOutput);
    }

    function lastInput() external view returns (bytes memory) {
        return _lastInput;
    }
}

/// @dev Test-only jq precompile installed at 0x0803 with vm.etch.
contract MockJqPrecompile {
    bool public shouldRevert;
    bool public emptyResult;
    uint256 public value;

    function setValue(uint256 value_) external {
        value = value_;
    }

    function setShouldRevert(bool value_) external {
        shouldRevert = value_;
    }

    function setEmptyResult(bool value_) external {
        emptyResult = value_;
    }

    fallback(bytes calldata) external returns (bytes memory output) {
        if (shouldRevert) revert("jq failed");
        if (emptyResult) return bytes("");
        return abi.encode(value);
    }
}
