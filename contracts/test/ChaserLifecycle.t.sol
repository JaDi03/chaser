// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ChaserFactory} from "../src/ChaserFactory.sol";
import {ChaserVault} from "../src/ChaserVault.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {TestToken} from "../src/test-utils/TestToken.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {ForkBase} from "./utils/ForkBase.sol";

/// An account acting through a contract: creates vaults it owns and closes or pauses them in the same transaction.
contract Actor {
    function create(ChaserFactory f, PoolId id, TestToken t0, TestToken t1, uint128 amount, int24 tick)
        public
        payable
        returns (ChaserVault v)
    {
        t0.approve(address(f), amount);
        t1.approve(address(f), amount);
        v = ChaserVault(payable(f.create{value: msg.value}(id, amount, amount, tick, 60)));
    }

    function createAndLeave(ChaserFactory f, PoolId id, TestToken t0, TestToken t1, uint128 amount, int24 tick)
        external
        payable
        returns (ChaserVault v)
    {
        v = create(f, id, t0, t1, amount, tick);
        v.withdraw(address(this));
    }

    function createAndPause(ChaserFactory f, PoolId id, TestToken t0, TestToken t1, uint128 amount, int24 tick)
        external
        payable
        returns (ChaserVault v)
    {
        v = create(f, id, t0, t1, amount, tick);
        v.setPaused(true);
    }

    receive() external payable {}
}

/// The shared reactive contract fed only with what the Reactive Network can deliver: logs of subscriptions that existed
/// before the transaction (the factory's events of the pool, and the pool's swaps).
contract ChaserLifecycleForkTest is ForkBase {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    ChaserReactive internal reactive;
    Actor internal actor;

    function setUp() public {
        _setUpFork();
        vm.etch(SYSTEM, address(new MockSystem()).code);
        reactive =
            new ChaserReactive(block.chainid, address(manager), PoolId.unwrap(poolId), 1_000_000, 300, 60, MAX_VAULTS);
        reactive.setFactory(address(factory));
        actor = new Actor();
    }

    // F1: vaults created and closed in one transaction never stay registered, so they cannot fill the reactive contract
    function test_vaultsClosedInTheirCreationTransactionLeaveNoTrace() public {
        for (uint256 i; i < MAX_VAULTS; i++) {
            _fundActor(3e16);
            int24 tick = _tick();
            vm.recordLogs();
            actor.createAndLeave{value: RESERVE}(factory, poolId, token0, token1, 3e16, tick);
            _deliver(vm.getRecordedLogs());
        }
        assertEq(factory.activeVaults(poolId), 0);
        assertEq(reactive.activeVaults().length, 0);
        assertFalse(reactive.swapsSubscribed());

        vm.recordLogs();
        ChaserVault honest = _create(owner, 10e18, 10e18);
        _deliver(vm.getRecordedLogs());
        assertTrue(reactive.watchOf(address(honest)).slot != 0);
    }

    // F1: a pause in the creation transaction is seen
    function test_pauseInTheCreationTransactionIsSeen() public {
        _fundActor(10e18);
        int24 tick = _tick();
        vm.recordLogs();
        ChaserVault v = actor.createAndPause{value: RESERVE}(factory, poolId, token0, token1, 10e18, tick);
        _deliver(vm.getRecordedLogs());
        assertTrue(v.paused());
        assertTrue(reactive.watchOf(address(v)).paused);
    }

    // F1: a closing lost on the way (for example while the reactive contract was in debt) heals on the next callback
    function test_lostClosingHealsOnTheNextCallback() public {
        vm.recordLogs();
        ChaserVault v = _create(owner, 10e18, 10e18);
        _deliver(vm.getRecordedLogs());
        vm.prank(owner);
        v.withdraw(owner);
        // the closing is not delivered; the reactive contract still asks this vault after a trend
        assertTrue(reactive.watchOf(address(v)).slot != 0);
        _moveTo(UPPER + WIDTH + 300);
        int24 tick = _tick();
        vm.recordLogs();
        vm.prank(proxy);
        v.rebalance(rc, tick);
        _deliver(vm.getRecordedLogs());
        assertEq(reactive.watchOf(address(v)).slot, 0);
        assertEq(reactive.activeVaults().length, 0);
    }

    function _deliver(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; i++) {
            address e = logs[i].emitter;
            if (e != address(factory) && e != address(manager)) continue;
            IReactive.LogRecord memory log_;
            log_.chainId = block.chainid;
            log_.contractAddress = e;
            log_.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) log_.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) log_.topic2 = uint256(logs[i].topics[2]);
            if (logs[i].topics.length > 3) log_.topic3 = uint256(logs[i].topics[3]);
            log_.data = logs[i].data;
            vm.prank(SYSTEM);
            reactive.react(log_);
        }
    }

    function _fundActor(uint128 amount) internal {
        token0.mint(address(actor), amount);
        token1.mint(address(actor), amount);
        vm.deal(address(this), address(this).balance + RESERVE);
    }
}
