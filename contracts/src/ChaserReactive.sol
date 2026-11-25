// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ChaserReactive
/// @notice Watches one Uniswap v4 pool and asks the vault to move its range once the price has stayed past an edge of
/// the range by `triggerTicks` for `confirmSeconds` without coming back. It learns the range from the vault's own
/// events, so it never needs to read the destination chain. The vault rechecks the rule before acting.
contract ChaserReactive is AbstractReactive {
    error NotOwner();
    error InvalidParams();
    error VaultAlreadySet();
    error FundsTransferFailed();

    event VaultSet(address indexed vault);
    event RangeTracked(int24 tickLower, int24 tickUpper);
    event VaultClosed();
    event CallbackRequested(int24 tick);
    event PausedSet(bool paused);
    event FundsWithdrawn(address indexed to, uint256 amount);

    int24 public constant MAX_TRIGGER_TICKS = 200_000;
    uint64 public constant MIN_CALLBACK_GAS = 300_000;
    uint64 public constant MAX_CALLBACK_GAS = 3_000_000;
    uint256 public constant MIN_PENDING_TIMEOUT = 60;
    uint256 public constant MAX_WINDOW_SECONDS = 1 days;

    /// keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"), IPoolManager.Swap
    uint256 public constant SWAP_TOPIC =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    /// keccak256("RangeMoved(uint256,int24,int24,int24,uint128)"), ChaserVault.RangeMoved
    uint256 public constant RANGE_MOVED_TOPIC = uint256(keccak256("RangeMoved(uint256,int24,int24,int24,uint128)"));
    /// keccak256("Withdrawn(uint256,uint256,uint256)"), ChaserVault.Withdrawn
    uint256 public constant WITHDRAWN_TOPIC = uint256(keccak256("Withdrawn(uint256,uint256,uint256)"));

    address public immutable owner;
    uint256 public immutable chainId;
    address public immutable poolManager;
    uint256 public immutable poolId;
    int24 public immutable triggerTicks;
    uint64 public immutable callbackGasLimit;
    uint256 public immutable pendingTimeout;
    uint256 public immutable confirmSeconds;

    address public vault;
    bool public hasRange;
    int24 public tickLower;
    int24 public tickUpper;
    bool public pending;
    uint256 public pendingSince;
    bool public paused;
    /// @notice When the price was first seen past the line on the current side; 0 while it is inside.
    uint256 public beyondSince;
    bool public beyondUp;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 chainId_,
        address poolManager_,
        bytes32 poolId_,
        int24 triggerTicks_,
        uint64 callbackGasLimit_,
        uint256 pendingTimeout_,
        uint256 confirmSeconds_
    ) payable {
        if (
            poolManager_ == address(0) || triggerTicks_ <= 0 || triggerTicks_ > MAX_TRIGGER_TICKS
                || callbackGasLimit_ < MIN_CALLBACK_GAS || callbackGasLimit_ > MAX_CALLBACK_GAS
                || pendingTimeout_ < MIN_PENDING_TIMEOUT || pendingTimeout_ > MAX_WINDOW_SECONDS
                || confirmSeconds_ > MAX_WINDOW_SECONDS
        ) revert InvalidParams();
        owner = msg.sender;
        chainId = chainId_;
        poolManager = poolManager_;
        poolId = uint256(poolId_);
        triggerTicks = triggerTicks_;
        callbackGasLimit = callbackGasLimit_;
        pendingTimeout = pendingTimeout_;
        confirmSeconds = confirmSeconds_;
        _subscribeSwaps();
    }

    /// @notice Sets the vault once. The vault needs this contract's address at deployment, so it comes second.
    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert InvalidParams();
        vault = vault_;
        _subscribeVault();
        emit VaultSet(vault_);
    }

    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        SYSTEM.unsubscribe(chainId, poolManager, SWAP_TOPIC, poolId, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit PausedSet(true);
    }

    function resume() external onlyOwner {
        if (!paused) return;
        paused = false;
        _subscribeSwaps();
        emit PausedSet(false);
    }

    /// @notice Sends REACT held by this contract to `to`. Reserves deposited through the system contract are not
    /// affected; an empty balance only stops the automation once those reserves run out.
    function withdrawFunds(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidParams();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert FundsTransferFailed();
        emit FundsWithdrawn(to, amount);
    }

    /// @notice Entry point for the Reactive Network. Irrelevant logs end without reverting (a revert is charged).
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != chainId) return;

        if (log_.contractAddress == vault) {
            if (log_.topic0 == RANGE_MOVED_TOPIC) {
                (int24 lower, int24 upper,,) = abi.decode(log_.data, (int24, int24, int24, uint128));
                tickLower = lower;
                tickUpper = upper;
                hasRange = true;
                pending = false;
                beyondSince = 0;
                emit RangeTracked(lower, upper);
            } else if (log_.topic0 == WITHDRAWN_TOPIC) {
                hasRange = false;
                pending = false;
                beyondSince = 0;
                emit VaultClosed();
            }
            return;
        }

        if (log_.contractAddress != poolManager || log_.topic0 != SWAP_TOPIC || log_.topic1 != poolId) return;
        if (!hasRange || paused) return;

        (,,,, int24 tick,) = abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
        bool up = int256(tick) >= int256(tickUpper) + triggerTicks;
        if (!up && int256(tick) >= int256(tickLower) - triggerTicks) {
            // back inside the line: a real trend has to start its confirmation again
            beyondSince = 0;
            return;
        }
        if (beyondSince == 0 || beyondUp != up) {
            beyondSince = block.timestamp;
            beyondUp = up;
        }
        if (block.timestamp < beyondSince + confirmSeconds) return;
        if (pending && block.timestamp < pendingSince + pendingTimeout) return;

        pending = true;
        pendingSince = block.timestamp;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainId,
                recipient: vault,
                gasLimit: callbackGasLimit,
                payload: abi.encodeWithSignature("rebalance(address,int24)", address(0), tick)
            })
        );
        emit CallbackRequested(tick);
    }

    function _subscribeSwaps() internal {
        SYSTEM.subscribe(chainId, poolManager, SWAP_TOPIC, poolId, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @dev Every event of the vault: RangeMoved and Withdrawn are used, the rest are ignored in `react`.
    function _subscribeVault() internal {
        SYSTEM.subscribe(chainId, vault, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
