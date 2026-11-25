// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
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

/// @title ChaserVault
/// @notice Holds one owner's Uniswap v4 position. When a trend leaves the range behind (the price is past an edge by
/// `triggerTicks`), a Reactive callback moves the single token the position holds into a range of the same width
/// next to the price. The vault never swaps.
contract ChaserVault is AbstractCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;

    enum Skip {
        Paused,
        NoPosition,
        CoolingDown,
        InsideTrigger,
        OutOfTickBounds,
        Deviation
    }

    error NotOwner();
    error InvalidParams();
    error PositionAlreadyOpen();
    error NothingToMove();

    event RangeMoved(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, int24 tick, uint128 liquidity);
    event RebalanceSkipped(Skip reason, int24 tick);
    event Withdrawn(uint256 amount0, uint256 amount1, uint256 amountNative);
    event PausedSet(bool paused);

    int24 public constant MAX_TRIGGER_TICKS = 200_000;
    uint256 public constant MAX_COOLDOWN_SECONDS = 30 days;

    address public immutable owner;
    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    int24 public immutable triggerTicks;
    int24 public immutable maxDeviationTicks;
    uint256 public immutable cooldownSeconds;
    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;

    PoolKey internal _poolKey;
    uint256 public tokenId;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public lastMoveAt;
    bool public paused;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPayable callbackProxy_,
        address reactiveContract_,
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        PoolKey memory poolKey_,
        address owner_,
        int24 triggerTicks_,
        int24 maxDeviationTicks_,
        uint256 cooldownSeconds_
    ) AbstractCallback(callbackProxy_, reactiveContract_) {
        // native currency and hooked pools are out of scope: both currencies must be ERC20 and the pool hook-free
        if (
            owner_ == address(0) || poolKey_.currency0.isAddressZero() || address(poolKey_.hooks) != address(0)
                || Currency.unwrap(poolKey_.currency0).code.length == 0
                || Currency.unwrap(poolKey_.currency1).code.length == 0
        ) revert InvalidParams();
        // a trigger below one tick spacing would recreate the same range
        if (
            triggerTicks_ < poolKey_.tickSpacing || triggerTicks_ > MAX_TRIGGER_TICKS || maxDeviationTicks_ <= 0
                || maxDeviationTicks_ > MAX_TRIGGER_TICKS || cooldownSeconds_ > MAX_COOLDOWN_SECONDS
        ) revert InvalidParams();
        owner = owner_;
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        triggerTicks = triggerTicks_;
        maxDeviationTicks = maxDeviationTicks_;
        cooldownSeconds = cooldownSeconds_;
        currency0 = poolKey_.currency0;
        currency1 = poolKey_.currency1;
        tickSpacing = poolKey_.tickSpacing;
        _poolKey = poolKey_;

        // the PositionManager pulls tokens through Permit2
        _approve(permit2_, address(positionManager_), poolKey_.currency0);
        _approve(permit2_, address(positionManager_), poolKey_.currency1);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Opens the position with the owner's tokens; anything not used goes back to the owner.
    function open(int24 tickLower_, int24 tickUpper_, uint128 liquidity, uint128 amount0Max, uint128 amount1Max)
        external
        nonReentrant
        onlyOwner
    {
        if (tokenId != 0) revert PositionAlreadyOpen();
        if (
            tickLower_ >= tickUpper_ || tickLower_ % tickSpacing != 0 || tickUpper_ % tickSpacing != 0
                || tickLower_ < TickMath.minUsableTick(tickSpacing) || tickUpper_ > TickMath.maxUsableTick(tickSpacing)
                || liquidity == 0
        ) revert InvalidParams();

        ERC20(Currency.unwrap(currency0)).safeTransferFrom(msg.sender, address(this), amount0Max);
        ERC20(Currency.unwrap(currency1)).safeTransferFrom(msg.sender, address(this), amount1Max);
        _mint(tickLower_, tickUpper_, liquidity, amount0Max, amount1Max);
        _sendAll(owner);
    }

    /// @notice Reactive callback. Rechecks the rule with the current pool price and moves only when it holds.
    /// @param rvmId Address of the sending reactive contract, injected by the Reactive Network.
    /// @param observedTick Tick the reactive contract saw after the price stayed past the line for its confirmation
    /// window; a current price far from it means the price moved or was pushed since, so the vault does not act.
    function rebalance(address rvmId, int24 observedTick)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(rvmId)
    {
        (, int24 tick,,) = poolManager.getSlot0(_poolKey.toId());
        if (paused) return _skip(Skip.Paused, tick);
        if (tokenId == 0) return _skip(Skip.NoPosition, tick);
        if (block.timestamp < lastMoveAt + cooldownSeconds) return _skip(Skip.CoolingDown, tick);
        int256 deviation = int256(tick) - int256(observedTick);
        if (deviation > maxDeviationTicks || deviation < -int256(maxDeviationTicks)) {
            return _skip(Skip.Deviation, tick);
        }

        int24 width = tickUpper - tickLower;
        bool movedUp = int256(tick) >= int256(tickUpper) + triggerTicks;
        if (!movedUp && int256(tick) >= int256(tickLower) - triggerTicks) return _skip(Skip.InsideTrigger, tick);

        int24 newLower;
        int24 newUpper;
        if (movedUp) {
            // the position holds currency1 only: place it just below the price
            newUpper = _floor(tick);
            newLower = newUpper - width;
        } else {
            // the position holds currency0 only: place it just above the price
            newLower = _floor(tick) + tickSpacing;
            newUpper = newLower + width;
        }
        if (newLower < TickMath.minUsableTick(tickSpacing) || newUpper > TickMath.maxUsableTick(tickSpacing)) {
            return _skip(Skip.OutOfTickBounds, tick);
        }

        lastMoveAt = block.timestamp;
        // only what the position returns is moved; tokens sent to the vault stay idle and leave with `withdraw`
        uint256 before = _balance(movedUp ? currency1 : currency0);
        _burn();
        uint256 returned = _balance(movedUp ? currency1 : currency0) - before;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(newLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(newUpper);
        uint128 liquidity;
        uint128 amount0Max = 0;
        uint128 amount1Max = 0;
        if (movedUp) {
            amount1Max = _capUint128(returned);
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount1Max);
        } else {
            amount0Max = _capUint128(returned);
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount0Max);
        }
        if (liquidity == 0) revert NothingToMove();
        // the new range is computed from this same price, so it needs only the token the position holds
        _mint(newLower, newUpper, liquidity, amount0Max, amount1Max);
    }

    /// @notice Closes the position and sends both tokens and any native balance to the owner. Works while paused and
    /// without Reactive. If the owner refuses native currency, the tokens still leave and the native balance stays.
    function withdraw() external nonReentrant onlyOwner {
        if (tokenId != 0) _burn();
        (uint256 amount0, uint256 amount1) = _sendAll(owner);
        uint256 amountNative = address(this).balance;
        if (amountNative > 0) {
            // an owner that refuses native currency must still get its tokens: the native balance then stays here
            (bool ok,) = payable(owner).call{value: amountNative}("");
            if (!ok) amountNative = 0;
        }
        emit Withdrawn(amount0, amount1, amountNative);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function _mint(int24 tickLower_, int24 tickUpper_, uint128 liquidity, uint128 amount0Max, uint128 amount1Max)
        internal
    {
        uint256 id = positionManager.nextTokenId();
        tokenId = id;
        tickLower = tickLower_;
        tickUpper = tickUpper_;

        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_poolKey, tickLower_, tickUpper_, liquidity, amount0Max, amount1Max, address(this), "");
        params[1] = abi.encode(currency0, currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        (, int24 tick,,) = poolManager.getSlot0(_poolKey.toId());
        emit RangeMoved(id, tickLower_, tickUpper_, tick, liquidity);
    }

    function _burn() internal {
        uint256 id = tokenId;
        tokenId = 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint128(0), uint128(0), "");
        params[1] = abi.encode(currency0, currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _sendAll(address to) internal returns (uint256 amount0, uint256 amount1) {
        amount0 = _balance(currency0);
        amount1 = _balance(currency1);
        if (amount0 > 0) ERC20(Currency.unwrap(currency0)).safeTransfer(to, amount0);
        if (amount1 > 0) ERC20(Currency.unwrap(currency1)).safeTransfer(to, amount1);
    }

    function _skip(Skip reason, int24 tick) internal {
        emit RebalanceSkipped(reason, tick);
    }

    /// @dev Anything above the uint128 range stays in the vault and leaves with `withdraw`.
    function _capUint128(uint256 amount) internal pure returns (uint128) {
        if (amount > type(uint128).max) return type(uint128).max;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(amount);
    }

    function _balance(Currency currency) internal view returns (uint256) {
        return ERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @dev Rounds a tick down to the pool's tick spacing (towards negative infinity).
    function _floor(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        // forge-lint: disable-next-line(divide-before-multiply)
        return compressed * tickSpacing;
    }

    function _approve(IAllowanceTransfer permit2_, address spender, Currency currency) internal {
        address token = Currency.unwrap(currency);
        ERC20(token).safeApprove(address(permit2_), type(uint256).max);
        permit2_.approve(token, spender, type(uint160).max, type(uint48).max);
    }
}
