// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ChaserFactory} from "../../src/ChaserFactory.sol";
import {ChaserVault} from "../../src/ChaserVault.sol";
import {TestToken} from "../../src/test-utils/TestToken.sol";

interface ICallbackProxyReserves {
    function reserves(address contract_) external view returns (uint256);
}

/// Official Uniswap v4 contracts and the Reactive callback proxy on a pinned Unichain Sepolia fork, a fresh test pool
/// with background liquidity, and a factory for it.
abstract contract ForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 68_778_100;
    int24 internal constant SPACING = 60;
    int24 internal constant WIDTH = 960;
    int24 internal constant LOWER = -480;
    int24 internal constant UPPER = 480;
    uint256 internal constant COOLDOWN = 60;
    int24 internal constant DEVIATION = 240;
    uint256 internal constant MAX_VAULTS = 3;
    uint256 internal constant RESERVE = 0.002 ether;
    uint128 internal constant MIN_LIQUIDITY = 1e18;

    IPositionManager internal posm;
    IPoolManager internal manager;
    IAllowanceTransfer internal permit2;
    address internal proxy;
    address internal rc = makeAddr("reactiveContract");
    address internal owner = makeAddr("owner");
    PoolKey internal key;
    PoolId internal poolId;
    PoolSwapTest internal swapper;
    ChaserFactory internal factory;
    TestToken internal token0;
    TestToken internal token1;

    function _setUpFork() internal {
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/../config/networks/unichain-sepolia.json"));
        vm.createSelectFork(vm.parseJsonString(cfg, ".rpcUrl"), FORK_BLOCK);
        posm = IPositionManager(vm.parseJsonAddress(cfg, ".uniswap.positionManager"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(cfg, ".uniswap.permit2"));
        proxy = vm.parseJsonAddress(cfg, ".reactive.callbackProxy");
        manager = posm.poolManager();
        assertEq(address(manager), vm.parseJsonAddress(cfg, ".uniswap.poolManager"));

        TestToken a = new TestToken("Test A", "TA", 18);
        TestToken b = new TestToken("Test B", "TB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, SPACING, IHooks(address(0)));
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // background liquidity so swaps can move the price across a wide band
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        _fundAndApprove(address(this), address(lp), 1e30);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e21, 0), "");
        swapper = new PoolSwapTest(manager);
        _fundAndApprove(address(this), address(swapper), 0);

        factory = _newFactory(_config());
    }

    function _config() internal view returns (ChaserFactory.PoolConfig memory) {
        return ChaserFactory.PoolConfig({
            key: key,
            reactive: rc,
            widthTicks: WIDTH,
            maxDeviationTicks: DEVIATION,
            cooldownSeconds: COOLDOWN,
            maxVaults: MAX_VAULTS,
            reserveWei: RESERVE,
            minLiquidity: MIN_LIQUIDITY
        });
    }

    function _newFactory(ChaserFactory.PoolConfig memory p) internal returns (ChaserFactory) {
        ChaserFactory.PoolConfig[] memory pools = new ChaserFactory.PoolConfig[](1);
        pools[0] = p;
        return new ChaserFactory(IPayable(payable(proxy)), posm, permit2, pools);
    }

    /// `who` approves the exact amounts and creates a vault at the current price.
    function _create(address who, uint128 amount0, uint128 amount1) internal returns (ChaserVault) {
        token0.mint(who, amount0);
        token1.mint(who, amount1);
        vm.deal(who, RESERVE);
        vm.startPrank(who);
        token0.approve(address(factory), amount0);
        token1.approve(address(factory), amount1);
        address v = factory.create{value: RESERVE}(poolId, amount0, amount1, _tick(), SPACING);
        vm.stopPrank();
        return ChaserVault(payable(v));
    }

    function _moveTo(int24 target) internal {
        bool zeroForOne = target < _tick();
        swapper.swap(
            key,
            SwapParams(zeroForOne, -1e30, TickMath.getSqrtPriceAtTick(target)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    function _amountsOf(ChaserVault v) internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(poolId);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(v.tickLower()),
            TickMath.getSqrtPriceAtTick(v.tickUpper()),
            posm.getPositionLiquidity(v.tokenId())
        );
    }

    function _reserveOf(address v) internal view returns (uint256) {
        return ICallbackProxyReserves(proxy).reserves(v);
    }

    function _fundAndApprove(address who, address spender, uint256 amount) internal {
        if (amount > 0) {
            token0.mint(who, amount);
            token1.mint(who, amount);
        }
        token0.approve(spender, type(uint256).max);
        token1.approve(spender, type(uint256).max);
    }
}
