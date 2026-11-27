// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ChaserFactory} from "../src/ChaserFactory.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {TestToken} from "../src/test-utils/TestToken.sol";

/// @notice Testnet deployment, in this order (each step prints what the next one needs):
/// 1. pool()                         --rpc-url <destination>  optional: new test tokens, pool, liquidity, swapper
/// 2. reactive()                     --rpc-url lasna          the pool's shared reactive contract, funded with REACT
/// 3. factory(address rc)            --rpc-url <destination>  the factory for the pool in the config
/// 4. linkFactory(address rc, address factory) --rpc-url lasna  the reactive contract starts watching the factory
/// 5. create(address factory)        --rpc-url <destination>  optional: a demo vault with test tokens
/// Step 5 must run after step 4 is final on Lasna: the reactive contract learns vaults only from the factory's
/// VaultCreated events it is already subscribed to. Run every step with --sender set to the signing account.
/// Every per-network value is read from config/networks/<NETWORK>.json (`chaser.pool` and `chaser.params`).
contract Chaser is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal cfg;

    function setUp() public {
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/../config/networks/", vm.envString("NETWORK"), ".json"));
    }

    function pool() external {
        _onDestination();
        _testnetOnly();
        IPoolManager manager = IPositionManager(_addr(".uniswap.positionManager")).poolManager();
        vm.startBroadcast();
        TestToken a = new TestToken("Chaser Test A", "CTA", 18);
        TestToken b = new TestToken("Chaser Test B", "CTB", 18);
        (TestToken t0, TestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory key = _key(address(t0), address(t1));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapper = new PoolSwapTest(manager);
        t0.mint(msg.sender, 1e30);
        t1.mint(msg.sender, 1e30);
        t0.approve(address(lp), type(uint256).max);
        t1.approve(address(lp), type(uint256).max);
        t0.approve(address(swapper), type(uint256).max);
        t1.approve(address(swapper), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e21, 0), "");
        vm.stopBroadcast();

        console.log("token0", address(t0));
        console.log("token1", address(t1));
        console.log("swapper", address(swapper));
        console.logBytes32(PoolId.unwrap(key.toId()));
    }

    function reactive() external {
        _onReactive();
        PoolKey memory key = _poolKey();
        vm.startBroadcast();
        // funded as its own balance (not system reserves) so the owner can take what is left with withdrawFunds
        ChaserReactive rc = new ChaserReactive{value: vm.parseJsonUint(cfg, ".chaser.params.reactiveFundingWei")}(
            vm.parseJsonUint(cfg, ".chainId"),
            _addr(".uniswap.poolManager"),
            PoolId.unwrap(key.toId()),
            uint64(vm.parseJsonUint(cfg, ".chaser.params.callbackGasLimit")),
            vm.parseJsonUint(cfg, ".chaser.params.pendingTimeoutSeconds"),
            vm.parseJsonUint(cfg, ".chaser.params.confirmSeconds"),
            vm.parseJsonUint(cfg, ".chaser.params.maxVaults")
        );
        require(rc.owner() == msg.sender, "owner is not the sender");
        vm.stopBroadcast();
        console.log("reactive", address(rc));
    }

    function factory(address rc) external {
        _onDestination();
        ChaserFactory.PoolConfig[] memory pools = new ChaserFactory.PoolConfig[](1);
        pools[0] = ChaserFactory.PoolConfig({
            key: _poolKey(),
            reactive: rc,
            widthTicks: _int24(".chaser.params.widthTicks"),
            maxDeviationTicks: _int24(".chaser.params.maxDeviationTicks"),
            cooldownSeconds: vm.parseJsonUint(cfg, ".chaser.params.cooldownSeconds"),
            maxVaults: vm.parseJsonUint(cfg, ".chaser.params.maxVaults"),
            reserveWei: vm.parseJsonUint(cfg, ".chaser.params.callbackReserveWei"),
            minLiquidity: uint128(vm.parseJsonUint(cfg, ".chaser.params.minLiquidity"))
        });
        vm.startBroadcast();
        ChaserFactory f = new ChaserFactory(
            IPayable(payable(_addr(".reactive.callbackProxy"))),
            IPositionManager(_addr(".uniswap.positionManager")),
            IAllowanceTransfer(_addr(".uniswap.permit2")),
            pools
        );
        vm.stopBroadcast();
        console.log("factory", address(f));
    }

    function linkFactory(address rc, address f) external {
        _onReactive();
        vm.startBroadcast();
        ChaserReactive(payable(rc)).setFactory(f);
        vm.stopBroadcast();
    }

    function create(address f) external {
        _onDestination();
        _testnetOnly();
        ChaserFactory cf = ChaserFactory(f);
        PoolKey memory key = _poolKey();
        (, int24 tick,,) = cf.poolManager().getSlot0(key.toId());
        uint128 amount = 10e18;
        vm.startBroadcast();
        TestToken(Currency.unwrap(key.currency0)).approve(f, amount);
        TestToken(Currency.unwrap(key.currency1)).approve(f, amount);
        address v = cf.create{value: vm.parseJsonUint(cfg, ".chaser.params.callbackReserveWei")}(
            key.toId(), amount, amount, tick, key.tickSpacing
        );
        vm.stopBroadcast();
        console.log("vault", v);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return _key(_addr(".chaser.pool.token0"), _addr(".chaser.pool.token1"));
    }

    function _key(address t0, address t1) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(t0),
            Currency.wrap(t1),
            uint24(vm.parseJsonUint(cfg, ".chaser.params.fee")),
            _int24(".chaser.params.tickSpacing"),
            IHooks(address(0))
        );
    }

    // the RPC must match the config file, so a crossed NETWORK and --rpc-url never deploys on the wrong chain
    function _onDestination() internal view {
        require(block.chainid == vm.parseJsonUint(cfg, ".chainId"), "rpc is not this network's chain");
    }

    function _onReactive() internal view {
        require(block.chainid == vm.parseJsonUint(cfg, ".reactive.chainId"), "rpc is not this network's reactive chain");
    }

    // test tokens and test routers only exist on networks marked as testnet
    function _testnetOnly() internal view {
        require(vm.parseJsonBool(cfg, ".testnet"), "testnet-only step");
    }

    function _addr(string memory path) internal view returns (address) {
        return vm.parseJsonAddress(cfg, path);
    }

    function _int24(string memory path) internal view returns (int24) {
        int256 value = vm.parseJsonInt(cfg, path);
        require(value >= type(int24).min && value <= type(int24).max, "value does not fit int24");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(value);
    }
}
