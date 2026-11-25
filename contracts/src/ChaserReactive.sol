// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title ChaserReactive
/// @notice Watches one Uniswap v4 pool for every vault the ChaserFactory creates on it. It asks a vault to move its
/// range once the price has stayed past an edge of that vault's range by one range width for `confirmSeconds`
/// without coming back. It learns vaults, ranges, pauses and closings only from the factory's events for this pool,
/// through one subscription made before any vault exists, so it never reads the destination chain. It listens to the
/// pool only while at least one vault is active. Each vault rechecks the rule before acting.
contract ChaserReactive is AbstractReactive {
    struct Watch {
        int24 tickLower;
        int24 tickUpper;
        bool pending;
        bool paused;
        bool beyondUp;
        uint64 beyondSince;
        uint64 pendingSince;
        // position in `_active` plus one; zero means the vault is not watched
        uint32 slot;
    }

    error NotOwner();
    error InvalidParams();
    error FactoryAlreadySet();
    error FundsTransferFailed();

    event FactorySet(address indexed factory);
    event VaultTracked(address indexed vault, int24 tickLower, int24 tickUpper);
    event VaultIgnored(address indexed vault);
    event RangeTracked(address indexed vault, int24 tickLower, int24 tickUpper);
    event VaultPaused(address indexed vault, bool paused);
    event VaultClosed(address indexed vault);
    event CallbackRequested(address indexed vault, int24 tick);
    event PausedSet(bool paused);
    event FundsWithdrawn(address indexed to, uint256 amount);

    int24 public constant MAX_TRIGGER_TICKS = 200_000;
    uint64 public constant MIN_CALLBACK_GAS = 300_000;
    uint64 public constant MAX_CALLBACK_GAS = 3_000_000;
    uint256 public constant MIN_PENDING_TIMEOUT = 60;
    uint256 public constant MIN_CONFIRM_SECONDS = 30;
    uint256 public constant MAX_WINDOW_SECONDS = 1 days;
    uint256 public constant MAX_VAULTS_LIMIT = 50;
    /// @notice Callbacks asked in one reaction; the rest wait for the next swap, so react() stays under its gas cap.
    uint256 public constant MAX_CALLBACKS_PER_REACT = 8;

    /// IPoolManager.Swap
    uint256 public constant SWAP_TOPIC =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    /// ChaserFactory.VaultCreated
    uint256 public constant VAULT_CREATED_TOPIC =
        uint256(keccak256("VaultCreated(bytes32,address,address,int24,int24)"));
    /// ChaserFactory.VaultMoved
    uint256 public constant VAULT_MOVED_TOPIC = uint256(keccak256("VaultMoved(bytes32,address,int24,int24)"));
    /// ChaserFactory.VaultPaused
    uint256 public constant VAULT_PAUSED_TOPIC = uint256(keccak256("VaultPaused(bytes32,address,bool)"));
    /// ChaserFactory.VaultClosed
    uint256 public constant VAULT_CLOSED_TOPIC = uint256(keccak256("VaultClosed(bytes32,address)"));

    address public immutable owner;
    uint256 public immutable chainId;
    address public immutable poolManager;
    uint256 public immutable poolId;
    uint64 public immutable callbackGasLimit;
    uint256 public immutable pendingTimeout;
    uint256 public immutable confirmSeconds;
    uint256 public immutable maxVaults;

    address public factory;
    bool public paused;
    bool public swapsSubscribed;
    mapping(address => Watch) internal _watches;
    address[] internal _active;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 chainId_,
        address poolManager_,
        bytes32 poolId_,
        uint64 callbackGasLimit_,
        uint256 pendingTimeout_,
        uint256 confirmSeconds_,
        uint256 maxVaults_
    ) payable {
        // a confirmation window under MIN_CONFIRM_SECONDS would let a short price push trigger a move
        if (
            poolManager_ == address(0) || callbackGasLimit_ < MIN_CALLBACK_GAS || callbackGasLimit_ > MAX_CALLBACK_GAS
                || pendingTimeout_ < MIN_PENDING_TIMEOUT || pendingTimeout_ > MAX_WINDOW_SECONDS
                || confirmSeconds_ < MIN_CONFIRM_SECONDS || confirmSeconds_ > MAX_WINDOW_SECONDS || maxVaults_ == 0
                || maxVaults_ > MAX_VAULTS_LIMIT
        ) revert InvalidParams();
        owner = msg.sender;
        chainId = chainId_;
        poolManager = poolManager_;
        poolId = uint256(poolId_);
        callbackGasLimit = callbackGasLimit_;
        pendingTimeout = pendingTimeout_;
        confirmSeconds = confirmSeconds_;
        maxVaults = maxVaults_;
    }

    /// @notice Sets the factory once. The factory needs this contract's address at deployment, so it comes second.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (factory_ == address(0)) revert InvalidParams();
        factory = factory_;
        // every factory event of this pool: created, moved, paused and closed vaults
        SYSTEM.subscribe(chainId, factory_, REACTIVE_IGNORE, poolId, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit FactorySet(factory_);
    }

    /// @notice Stops watching the pool; vaults stay registered and resume with `resume`.
    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        _syncSwaps();
        emit PausedSet(true);
    }

    function resume() external onlyOwner {
        if (!paused) return;
        paused = false;
        _syncSwaps();
        emit PausedSet(false);
    }

    /// @notice Stops watching a vault whose closing never arrived (for example while this contract was in debt). The
    /// vault and its funds are not touched; its owner can still withdraw.
    function forget(address vault) external onlyOwner {
        if (_watches[vault].slot != 0) _unregister(vault);
    }

    /// @notice Sends REACT held by this contract to `to`. Reserves deposited through the system contract are not
    /// affected; an empty balance only stops the automation once those reserves run out.
    function withdrawFunds(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidParams();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert FundsTransferFailed();
        emit FundsWithdrawn(to, amount);
    }

    function activeVaults() external view returns (address[] memory) {
        return _active;
    }

    function watchOf(address vault) external view returns (Watch memory) {
        return _watches[vault];
    }

    /// @notice Entry point for the Reactive Network. Irrelevant logs end without reverting (a revert is charged).
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != chainId) return;

        if (log_.contractAddress == poolManager) {
            if (log_.topic0 == SWAP_TOPIC && log_.topic1 == poolId && !paused) {
                (,,,, int24 tick,) = abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
                _onSwap(tick);
            }
            return;
        }

        if (log_.contractAddress != factory || factory == address(0) || log_.topic1 != poolId) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        address vault = address(uint160(log_.topic2));
        if (log_.topic0 == VAULT_CREATED_TOPIC) {
            _register(vault, log_.data);
            return;
        }
        Watch storage w = _watches[vault];
        if (w.slot == 0) return;
        if (log_.topic0 == VAULT_MOVED_TOPIC) {
            (int24 lower, int24 upper) = abi.decode(log_.data, (int24, int24));
            w.tickLower = lower;
            w.tickUpper = upper;
            w.pending = false;
            w.beyondSince = 0;
            emit RangeTracked(vault, lower, upper);
        } else if (log_.topic0 == VAULT_PAUSED_TOPIC) {
            bool vaultPaused = abi.decode(log_.data, (bool));
            w.paused = vaultPaused;
            w.pending = false;
            w.beyondSince = 0;
            emit VaultPaused(vault, vaultPaused);
        } else if (log_.topic0 == VAULT_CLOSED_TOPIC) {
            _unregister(vault);
        }
    }

    function _onSwap(int24 tick) internal {
        uint256 n = _active.length;
        uint256 asked = 0;
        for (uint256 i; i < n; i++) {
            address vault = _active[i];
            Watch storage w = _watches[vault];
            if (w.paused) continue;
            // the move distance is one full range width past the edge
            int256 width = int256(w.tickUpper) - int256(w.tickLower);
            bool up = int256(tick) >= int256(w.tickUpper) + width;
            if (!up && int256(tick) >= int256(w.tickLower) - width) {
                // back inside the line: a real trend has to start its confirmation again
                if (w.beyondSince != 0) w.beyondSince = 0;
                continue;
            }
            if (w.beyondSince == 0 || w.beyondUp != up) {
                // forge-lint: disable-next-line(unsafe-typecast)
                w.beyondSince = uint64(block.timestamp);
                w.beyondUp = up;
            }
            if (block.timestamp < uint256(w.beyondSince) + confirmSeconds) continue;
            if (w.pending && block.timestamp < uint256(w.pendingSince) + pendingTimeout) continue;
            // the vaults left over keep their window and are asked on a later swap, while these wait as pending
            if (asked == MAX_CALLBACKS_PER_REACT) continue;
            asked++;

            w.pending = true;
            // forge-lint: disable-next-line(unsafe-typecast)
            w.pendingSince = uint64(block.timestamp);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: chainId,
                    recipient: vault,
                    gasLimit: callbackGasLimit,
                    payload: abi.encodeWithSignature("rebalance(address,int24)", address(0), tick)
                })
            );
            emit CallbackRequested(vault, tick);
        }
    }

    function _register(address vault, bytes calldata data) internal {
        if (_watches[vault].slot != 0) return;
        (int24 lower, int24 upper) = abi.decode(data, (int24, int24));
        int256 width = int256(upper) - int256(lower);
        // the factory caps active vaults too; this guards the gas of react() if the two ever disagree
        if (_active.length >= maxVaults || width <= 0 || width > MAX_TRIGGER_TICKS) {
            emit VaultIgnored(vault);
            return;
        }
        _active.push(vault);
        _watches[vault] = Watch({
            tickLower: lower,
            tickUpper: upper,
            pending: false,
            paused: false,
            beyondUp: false,
            beyondSince: 0,
            pendingSince: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            slot: uint32(_active.length)
        });
        _syncSwaps();
        emit VaultTracked(vault, lower, upper);
    }

    function _unregister(address vault) internal {
        uint256 index = _watches[vault].slot - 1;
        address last = _active[_active.length - 1];
        _active[index] = last;
        // forge-lint: disable-next-line(unsafe-typecast)
        _watches[last].slot = uint32(index + 1);
        _active.pop();
        delete _watches[vault];
        _syncSwaps();
        emit VaultClosed(vault);
    }

    /// @dev Listens to the pool only while it is not paused and has at least one vault: every swap costs a react().
    function _syncSwaps() internal {
        bool want = !paused && _active.length > 0;
        if (want == swapsSubscribed) return;
        swapsSubscribed = want;
        if (want) SYSTEM.subscribe(chainId, poolManager, SWAP_TOPIC, poolId, REACTIVE_IGNORE, REACTIVE_IGNORE);
        else SYSTEM.unsubscribe(chainId, poolManager, SWAP_TOPIC, poolId, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
