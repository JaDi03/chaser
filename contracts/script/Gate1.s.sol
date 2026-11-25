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
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ChaserVault} from "../src/ChaserVault.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {TestToken} from "../src/test-utils/TestToken.sol";

interface IDeposit {
    function depositTo(address contract_) external payable;
}

/// @notice Gate 1 deployment on testnet, in this order (each step prints what the next one needs):
/// 1. pool()                               --rpc-url <destination>  test tokens, pool, background liquidity, swapper
/// 2. reactive(bytes32 poolId)             --rpc-url lasna          reactive contract, funded with REACT reserves
/// 3. vault(address rc, address t0, address t1)  --rpc-url <destination>  vault and its callback reserve
/// 4. linkVault(address rc, address vault) --rpc-url lasna          the reactive contract starts watching the vault
/// 5. open(address vault)                  --rpc-url <destination>  opens the position (emits the first RangeMoved)
/// Step 5 must run after step 4 is final on Lasna: the reactive contract learns the range only from a RangeMoved it
/// is already subscribed to. Run every step with --sender set to the signing account: it becomes the owner.
/// Every per-network value is read from config/networks/<NETWORK>.json.
contract Gate1 is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    string internal cfg;

    function setUp() public {
        cfg = vm.readFile(string.concat(vm.projectRoot(), "/../config/networks/", vm.envString("NETWORK"), ".json"));
    }

    function pool() external {
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

    function reactive(bytes32 poolId) external {
        vm.startBroadcast();
        // funded as its own balance (not system reserves) so the owner can take what is left with withdrawFunds
        ChaserReactive rc = new ChaserReactive{value: vm.parseJsonUint(cfg, ".chaser.params.reactiveFundingWei")}(
            vm.parseJsonUint(cfg, ".chainId"),
            _addr(".uniswap.poolManager"),
            poolId,
            _int24(".chaser.params.triggerTicks"),
            uint64(vm.parseJsonUint(cfg, ".chaser.params.callbackGasLimit")),
            vm.parseJsonUint(cfg, ".chaser.params.pendingTimeoutSeconds"),
            vm.parseJsonUint(cfg, ".chaser.params.confirmSeconds")
        );
        require(rc.owner() == msg.sender, "owner is not the sender");
        vm.stopBroadcast();
        console.log("reactive", address(rc));
    }

    function vault(address rc, address t0, address t1) external {
        vm.startBroadcast();
        ChaserVault v = new ChaserVault(
            IPayable(payable(_addr(".reactive.callbackProxy"))),
            rc,
            IPositionManager(_addr(".uniswap.positionManager")),
            IAllowanceTransfer(_addr(".uniswap.permit2")),
            _key(t0, t1),
            msg.sender,
            _int24(".chaser.params.triggerTicks"),
            _int24(".chaser.params.maxDeviationTicks"),
            vm.parseJsonUint(cfg, ".chaser.params.cooldownSeconds")
        );
        require(v.owner() == msg.sender, "owner is not the sender");
        IDeposit(_addr(".reactive.callbackProxy"))
        .depositTo{value: vm.parseJsonUint(cfg, ".chaser.params.callbackReserveWei")}(
            address(v)
        );
        vm.stopBroadcast();
        console.log("vault", address(v));
    }

    function linkVault(address rc, address v) external {
        vm.startBroadcast();
        ChaserReactive(payable(rc)).setVault(v);
        vm.stopBroadcast();
    }

    function open(address v) external {
        ChaserVault cv = ChaserVault(payable(v));
        PoolKey memory key = cv.poolKey();
        IPoolManager manager = cv.poolManager();
        int24 half = _int24(".chaser.params.widthTicks") / 2;
        (uint160 sqrtPrice, int24 tick,,) = manager.getSlot0(key.toId());
        int24 lower = (tick / key.tickSpacing) * key.tickSpacing - half;
        int24 upper = lower + 2 * half;
        uint128 amount = 10e18;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount, amount
        );
        vm.startBroadcast();
        TestToken(Currency.unwrap(key.currency0)).approve(v, amount);
        TestToken(Currency.unwrap(key.currency1)).approve(v, amount);
        cv.open(lower, upper, liquidity, amount, amount);
        vm.stopBroadcast();
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
