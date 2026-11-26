// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ChaserVault, IVaultFactory} from "./ChaserVault.sol";

interface ICallbackReserve {
    function depositTo(address contract_) external payable;
}

/// @title ChaserFactory
/// @notice Creates ChaserVaults for a fixed list of pools; each vault belongs to the account that created it, and one
/// account may create several. Each vault opens a range of the pool's width centered on the current price and keeps a
/// reserve that pays its Reactive callbacks. Vaults report their moves, pauses and closing here, and the factory
/// republishes them with the pool id, so the pool's reactive contract follows every vault through one subscription.
/// No owner, no admin: the pool list and every parameter are fixed at deployment.
contract ChaserFactory is IVaultFactory, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;

    struct PoolConfig {
        PoolKey key;
        address reactive;
        int24 widthTicks;
        int24 maxDeviationTicks;
        uint256 cooldownSeconds;
        uint256 maxVaults;
        uint256 reserveWei;
        uint128 minLiquidity;
    }

    error InvalidParams();
    error PoolNotAllowed();
    error PriceMoved(int24 tick, int24 expectedTick);
    error PoolFull();
    error WrongReserve();
    error DepositTooSmall();
    error NotVault();

    event VaultCreated(
        PoolId indexed poolId, address indexed vault, address indexed owner, int24 tickLower, int24 tickUpper
    );
    event VaultMoved(PoolId indexed poolId, address indexed vault, int24 tickLower, int24 tickUpper);
    event VaultPaused(PoolId indexed poolId, address indexed vault, bool paused);
    event VaultClosed(PoolId indexed poolId, address indexed vault);

    IPayable public immutable callbackProxy;
    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;

    PoolId[] internal _poolIds;
    mapping(PoolId => PoolConfig) internal _pools;
    mapping(PoolId => uint256) public activeVaults;
    mapping(address => PoolId) public vaultPool;
    mapping(address => bool) public isVault;
    mapping(address => bool) public isClosed;

    constructor(
        IPayable callbackProxy_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        PoolConfig[] memory pools_
    ) {
        if (address(callbackProxy_) == address(0) || address(permit2_) == address(0) || pools_.length == 0) {
            revert InvalidParams();
        }
        callbackProxy = callbackProxy_;
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        permit2 = permit2_;
        for (uint256 i; i < pools_.length; i++) {
            PoolConfig memory p = pools_[i];
            PoolId id = p.key.toId();
            // the range is centered on an aligned tick, so each half must be a whole number of tick spacings
            if (
                p.reactive == address(0) || p.key.tickSpacing <= 0 || p.widthTicks <= 0
                    || p.widthTicks % (2 * p.key.tickSpacing) != 0 || p.maxDeviationTicks <= 0
                    || p.maxDeviationTicks > p.widthTicks || p.maxVaults == 0 || p.minLiquidity == 0
                    || _pools[id].reactive != address(0)
            ) revert InvalidParams();
            _pools[id] = p;
            _poolIds.push(id);
        }
    }

    function poolIds() external view returns (PoolId[] memory) {
        return _poolIds;
    }

    function poolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _pools[poolId];
    }

    /// @notice Creates the caller's vault and opens its position with up to `amount0Max` and `amount1Max`, taken
    /// with `transferFrom` (approve the exact amounts first). What the position does not use goes back to the caller.
    /// `msg.value` must be exactly the pool's `reserveWei`: it becomes the vault's callback reserve at the Reactive
    /// callback proxy, is spent only on callback fees and does not come back on withdraw. Anyone can add to it later with
    /// the proxy's `depositTo(vault)`.
    /// @param expectedTick The pool tick the caller saw; the call reverts if the price moved more than
    /// `maxSlippageTicks` since, so a price pushed just before the deposit cannot set the range.
    function create(PoolId poolId, uint128 amount0Max, uint128 amount1Max, int24 expectedTick, int24 maxSlippageTicks)
        external
        payable
        nonReentrant
        returns (address vault)
    {
        PoolConfig memory p = _pools[poolId];
        if (p.reactive == address(0)) revert PoolNotAllowed();
        if (activeVaults[poolId] >= p.maxVaults) revert PoolFull();
        if (msg.value != p.reserveWei) revert WrongReserve();

        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(poolId);
        int256 slippage = int256(tick) - int256(expectedTick);
        if (maxSlippageTicks < 0 || slippage > maxSlippageTicks || slippage < -int256(maxSlippageTicks)) {
            revert PriceMoved(tick, expectedTick);
        }

        int24 tickLower = _floor(tick, p.key.tickSpacing) - p.widthTicks / 2;
        int24 tickUpper = tickLower + p.widthTicks;
        if (
            tickLower < TickMath.minUsableTick(p.key.tickSpacing)
                || tickUpper > TickMath.maxUsableTick(p.key.tickSpacing)
        ) revert InvalidParams();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity < p.minLiquidity) revert DepositTooSmall();

        vault = address(
            new ChaserVault(
                callbackProxy,
                p.reactive,
                positionManager,
                permit2,
                p.key,
                msg.sender,
                p.maxDeviationTicks,
                p.cooldownSeconds
            )
        );
        isVault[vault] = true;
        vaultPool[vault] = poolId;
        activeVaults[poolId]++;

        ERC20(Currency.unwrap(p.key.currency0)).safeTransferFrom(msg.sender, vault, amount0Max);
        ERC20(Currency.unwrap(p.key.currency1)).safeTransferFrom(msg.sender, vault, amount1Max);
        ChaserVault(payable(vault)).open(tickLower, tickUpper, liquidity, amount0Max, amount1Max);
        if (msg.value > 0) ICallbackReserve(address(callbackProxy)).depositTo{value: msg.value}(vault);

        emit VaultCreated(poolId, vault, msg.sender, tickLower, tickUpper);
    }

    /// @notice Called by a vault of this factory after the reactive contract moved its range.
    function vaultMoved(int24 tickLower, int24 tickUpper) external {
        _onlyOpenVault();
        emit VaultMoved(vaultPool[msg.sender], msg.sender, tickLower, tickUpper);
    }

    /// @notice Called by a vault of this factory when its owner pauses or resumes it.
    function vaultPaused(bool paused) external {
        _onlyOpenVault();
        emit VaultPaused(vaultPool[msg.sender], msg.sender, paused);
    }

    /// @notice Called by a vault of this factory when its owner withdraws, which frees its place in the pool. A closed
    /// vault that still gets a callback calls it again: the event is published again so the reactive contract stops.
    function vaultClosed() external {
        if (!isVault[msg.sender]) revert NotVault();
        PoolId poolId = vaultPool[msg.sender];
        if (!isClosed[msg.sender]) {
            isClosed[msg.sender] = true;
            activeVaults[poolId]--;
        }
        emit VaultClosed(poolId, msg.sender);
    }

    function _onlyOpenVault() internal view {
        if (!isVault[msg.sender] || isClosed[msg.sender]) revert NotVault();
    }

    /// @dev Rounds a tick down to the tick spacing (towards negative infinity).
    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        // forge-lint: disable-next-line(divide-before-multiply)
        return compressed * spacing;
    }
}
