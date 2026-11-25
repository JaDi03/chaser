// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract ChaserReactiveTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant CHAIN = 1301;
    address internal constant POOL_MANAGER = address(0xA11CE);
    bytes32 internal constant POOL_ID = bytes32(uint256(0x1234));
    uint256 internal constant TIMEOUT = 300;
    uint256 internal constant CONFIRM = 60;
    uint256 internal constant MAX_VAULTS = 10;
    uint256 internal constant T0 = 1_700_000_000;
    // range -480..480: the lines are one width (960) past each edge
    int24 internal constant UP_LINE = 480 + 960;
    int24 internal constant DOWN_LINE = -480 - 960;

    ChaserReactive internal rc;
    MockSystem internal system;
    address internal factory = makeAddr("factory");
    address internal vault = makeAddr("vault");

    function setUp() public {
        vm.warp(T0);
        vm.etch(SYSTEM, address(new MockSystem()).code);
        system = MockSystem(payable(SYSTEM));
        rc = _newRc(MAX_VAULTS);
        rc.setFactory(factory);
        _react(_created(vault, -480, 480));
    }

    function test_setFactorySubscribesOnlyToTheFactory() public {
        ChaserReactive fresh = _newRc(MAX_VAULTS);
        uint256 subs = system.subscribeCount();
        fresh.setFactory(factory);
        assertEq(system.subscribeCount(), subs + 1);
        assertFalse(fresh.swapsSubscribed());
    }

    function test_firstVaultSubscribesToTheSwapsOnly() public view {
        // the factory's events of this pool, then the pool's swaps; never one subscription per vault
        assertEq(system.subscribeCount(), 2);
        assertTrue(rc.swapsSubscribed());
        address[] memory active = rc.activeVaults();
        assertEq(active.length, 1);
        assertEq(active[0], vault);
        ChaserReactive.Watch memory w = rc.watchOf(vault);
        assertEq(w.tickLower, -480);
        assertEq(w.tickUpper, 480);
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory log_ = _swap(5000);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        rc.react(log_);
    }

    function test_setFactoryOnlyOwnerOnceAndNotZero() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChaserReactive.NotOwner.selector);
        rc.setFactory(address(1));
        vm.expectRevert(ChaserReactive.FactoryAlreadySet.selector);
        rc.setFactory(address(1));
        ChaserReactive fresh = _newRc(MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        fresh.setFactory(address(0));
    }

    function test_noCallbackInsideTheLine() public {
        _confirm(UP_LINE - 1);
        _confirm(DOWN_LINE);
        assertEq(system.callbackCount(), 0);
    }

    function test_callbackAfterTheWindowAboveTheLine() public {
        _confirm(UP_LINE);
        assertEq(system.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = system.lastCallback();
        assertEq(cb.chainId, CHAIN);
        assertEq(cb.recipient, vault);
        assertEq(cb.gasLimit, 1_000_000);
        assertEq(cb.payload, abi.encodeWithSignature("rebalance(address,int24)", address(0), UP_LINE));
        assertTrue(rc.watchOf(vault).pending);
    }

    function test_callbackAfterTheWindowBelowTheLine() public {
        _confirm(DOWN_LINE - 1);
        assertEq(system.callbackCount(), 1);
    }

    // A1, A5: a single swap past the line, or a round trip, never asks for a move before the window
    function test_confirmationWindowBlocksAQuickPush() public {
        _react(_swap(5000));
        assertEq(system.callbackCount(), 0);
        vm.warp(T0 + 30);
        _react(_swap(0));
        vm.warp(T0 + 90);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 0);
        assertEq(rc.watchOf(vault).beyondSince, T0 + 90);
    }

    function test_confirmationWindowBoundary() public {
        _react(_swap(5000));
        vm.warp(T0 + CONFIRM - 1);
        _react(_swap(5100));
        assertEq(system.callbackCount(), 0);
        vm.warp(T0 + CONFIRM);
        _react(_swap(5200));
        assertEq(system.callbackCount(), 1);
        assertEq(
            system.lastCallback().payload, abi.encodeWithSignature("rebalance(address,int24)", address(0), int24(5200))
        );
    }

    function test_switchingSideRestartsTheWindow() public {
        _react(_swap(5000));
        vm.warp(T0 + CONFIRM);
        _react(_swap(-5000));
        assertEq(system.callbackCount(), 0);
        assertFalse(rc.watchOf(vault).beyondUp);
    }

    function test_pendingBlocksRepeatsUntilTimeout() public {
        _confirm(5000);
        uint256 asked = block.timestamp;
        _react(_swap(5100));
        assertEq(system.callbackCount(), 1);
        vm.warp(asked + TIMEOUT - 1);
        _react(_swap(5100));
        assertEq(system.callbackCount(), 1);
        vm.warp(asked + TIMEOUT);
        _react(_swap(5200));
        assertEq(system.callbackCount(), 2);
        assertEq(rc.watchOf(vault).pendingSince, asked + TIMEOUT);
    }

    // D5: back inside the line while a request is pending restarts the window and keeps the pending timeout
    function test_backInsideWithPendingRestartsTheWindow() public {
        _confirm(5000);
        _react(_swap(0));
        assertEq(rc.watchOf(vault).beyondSince, 0);
        assertTrue(rc.watchOf(vault).pending);
        _react(_swap(5000));
        vm.warp(block.timestamp + CONFIRM);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 1);
    }

    function test_rangeMovedUpdatesTheRangeAndClearsTheWindow() public {
        _confirm(5000);
        _react(_rangeMoved(vault, 4020, 4980));
        ChaserReactive.Watch memory w = rc.watchOf(vault);
        assertFalse(w.pending);
        assertEq(w.beyondSince, 0);
        assertEq(w.tickLower, 4020);
        _confirm(5000);
        assertEq(system.callbackCount(), 1);
    }

    function test_vaultPauseStopsAndResumesItsCallbacks() public {
        _react(_paused(vault, true));
        assertTrue(rc.watchOf(vault).paused);
        _confirm(5000);
        assertEq(system.callbackCount(), 0);
        _react(_paused(vault, false));
        _confirm(5000);
        assertEq(system.callbackCount(), 1);
    }

    function test_withdrawnUnregistersAndStopsListeningToThePool() public {
        uint256 unsubs = system.unsubscribeCount();
        _react(_withdrawn(vault));
        assertEq(rc.activeVaults().length, 0);
        assertEq(rc.watchOf(vault).slot, 0);
        // the pool's swaps
        assertEq(system.unsubscribeCount(), unsubs + 1);
        assertFalse(rc.swapsSubscribed());
        _confirm(5000);
        assertEq(system.callbackCount(), 0);
        // the factory publishing the closing again changes nothing
        _react(_withdrawn(vault));
        assertEq(system.unsubscribeCount(), unsubs + 1);
    }

    function test_unregisterKeepsTheOtherVaults() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _react(_created(a, -480, 480));
        _react(_created(b, 960, 1920));
        _react(_withdrawn(vault));
        address[] memory active = rc.activeVaults();
        assertEq(active.length, 2);
        assertEq(rc.watchOf(active[0]).slot, 1);
        assertEq(rc.watchOf(active[1]).slot, 2);
        assertTrue(rc.swapsSubscribed());
        // only a crosses its line at 1440; for b (960..1920) 1440 is inside the range
        _confirm(UP_LINE);
        assertEq(system.callbackCount(), 1);
        assertEq(system.lastCallback().recipient, a);
    }

    function test_eachVaultFollowsItsOwnRange() public {
        address high = makeAddr("high");
        _react(_created(high, 960, 1920));
        _confirm(UP_LINE);
        assertEq(system.callbackCount(), 1);
        assertEq(system.lastCallback().recipient, vault);
        assertFalse(rc.watchOf(high).pending);
    }

    function test_ignoresFakeFactoriesFakeVaultsAndOtherPools() public {
        // VaultCreated from another contract
        IReactive.LogRecord memory log_ = _created(makeAddr("x"), -480, 480);
        log_.contractAddress = address(0xBAD);
        _react(log_);
        // VaultCreated for another pool
        log_ = _created(makeAddr("y"), -480, 480);
        log_.topic1 = uint256(POOL_ID) + 1;
        _react(log_);
        assertEq(rc.activeVaults().length, 1);
        // factory events about an unregistered vault
        _react(_rangeMoved(address(0xBAD), 9000, 9960));
        _react(_withdrawn(address(0xBAD)));
        // the same events about our vault from another emitter, or for another pool
        log_ = _rangeMoved(vault, 9000, 9960);
        log_.contractAddress = vault;
        _react(log_);
        log_ = _withdrawn(vault);
        log_.contractAddress = address(0xBAD);
        _react(log_);
        log_ = _withdrawn(vault);
        log_.topic1 = uint256(POOL_ID) + 1;
        _react(log_);
        assertEq(rc.watchOf(vault).tickLower, -480);
        assertEq(rc.activeVaults().length, 1);
        // swaps of another pool, another emitter or another chain
        log_ = _swap(5000);
        log_.topic1 = uint256(POOL_ID) + 1;
        _react(log_);
        log_ = _swap(5000);
        log_.contractAddress = address(0xBAD);
        _react(log_);
        log_ = _swap(5000);
        log_.chainId = CHAIN + 1;
        _react(log_);
        assertEq(rc.watchOf(vault).beyondSince, 0);
    }

    function test_duplicateVaultCreatedIsIgnored() public {
        uint256 subs = system.subscribeCount();
        _react(_created(vault, 9000, 9960));
        assertEq(rc.activeVaults().length, 1);
        assertEq(rc.watchOf(vault).tickLower, -480);
        assertEq(system.subscribeCount(), subs);
    }

    function test_capIgnoresVaultsBeyondMax() public {
        ChaserReactive small = _newRc(2);
        small.setFactory(factory);
        _reactOn(small, _created(makeAddr("a"), -480, 480));
        _reactOn(small, _created(makeAddr("b"), -480, 480));
        vm.expectEmit(address(small));
        emit ChaserReactive.VaultIgnored(makeAddr("c"));
        _reactOn(small, _created(makeAddr("c"), -480, 480));
        assertEq(small.activeVaults().length, 2);
    }

    function test_invalidRangeIsIgnored() public {
        _react(_created(makeAddr("bad"), 480, 480));
        assertEq(rc.activeVaults().length, 1);
    }

    function test_operatorPauseStopsSwapsAndKeepsVaults() public {
        rc.pause();
        assertFalse(rc.swapsSubscribed());
        _confirm(5000);
        assertEq(system.callbackCount(), 0);
        assertEq(rc.activeVaults().length, 1);
        rc.resume();
        assertTrue(rc.swapsSubscribed());
        _confirm(5000);
        assertEq(system.callbackCount(), 1);
    }

    function test_pauseAndResumeAreIdempotent() public {
        uint256 subs = system.subscribeCount();
        uint256 unsubs = system.unsubscribeCount();
        rc.pause();
        rc.pause();
        assertEq(system.unsubscribeCount(), unsubs + 1);
        rc.resume();
        rc.resume();
        assertEq(system.subscribeCount(), subs + 1);
    }

    function test_vaultCreatedWhilePausedDoesNotListenToSwaps() public {
        rc.pause();
        _react(_created(makeAddr("a"), -480, 480));
        assertFalse(rc.swapsSubscribed());
        rc.resume();
        assertTrue(rc.swapsSubscribed());
    }

    // F2, F6: at most MAX_CALLBACKS_PER_REACT callbacks per reaction; the others are asked on the next swap
    function test_callbacksPerReactionAreCapped() public {
        for (uint256 i; i < MAX_VAULTS - 1; i++) {
            _react(_created(address(uint160(0x2000 + i)), -480, 480));
        }
        _confirm(5000);
        assertEq(system.callbackCount(), rc.MAX_CALLBACKS_PER_REACT());
        _react(_swap(5000));
        assertEq(system.callbackCount(), MAX_VAULTS);
        // nobody is asked twice while pending
        _react(_swap(5000));
        assertEq(system.callbackCount(), MAX_VAULTS);
    }

    // F1: the operator can drop a vault whose closing never arrived; nobody else can
    function test_forgetDropsAVaultOnlyForTheOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChaserReactive.NotOwner.selector);
        rc.forget(vault);
        rc.forget(vault);
        assertEq(rc.activeVaults().length, 0);
        assertFalse(rc.swapsSubscribed());
        rc.forget(vault);
        rc.forget(makeAddr("unknown"));
    }

    // A3: the owner can take REACT out; nobody else can
    function test_withdrawFunds() public {
        vm.deal(address(rc), 2 ether);
        address payable to = payable(makeAddr("treasury"));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChaserReactive.NotOwner.selector);
        rc.withdrawFunds(to, 1 ether);
        rc.withdrawFunds(to, 1 ether);
        assertEq(to.balance, 1 ether);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        rc.withdrawFunds(payable(address(0)), 1);
    }

    // A6, D3: parameters out of bounds are refused
    function test_constructorBounds() public {
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, address(0), POOL_ID, 1_000_000, TIMEOUT, CONFIRM, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 299_999, TIMEOUT, CONFIRM, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 3_000_001, TIMEOUT, CONFIRM, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, 59, CONFIRM, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, 1 days + 1, CONFIRM, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, TIMEOUT, 29, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, TIMEOUT, 1 days + 1, MAX_VAULTS);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, TIMEOUT, CONFIRM, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, TIMEOUT, CONFIRM, 51);
    }

    /// Gas of one react() for a swap with every vault asking for a callback (the worst case), and with every vault
    /// inside its line (the common case). Printed to size `maxVaults` against the 900 000 gas cap of react().
    function test_gasPerVault() public {
        ChaserReactive big = _newRc(50);
        big.setFactory(factory);
        for (uint256 i; i < 50; i++) {
            _reactOn(big, _created(address(uint160(0x1000 + i)), -480, 480));
        }
        uint256 inside = _gasOf(big, _swap(0));
        uint256 firstCross = _gasOf(big, _swap(5000));
        vm.warp(block.timestamp + CONFIRM);
        uint256 worst = _gasOf(big, _swap(5000));
        assertEq(system.callbackCount(), big.MAX_CALLBACKS_PER_REACT());
        console.log("react gas, 50 vaults inside the line", inside);
        console.log("react gas, 50 vaults past the line, 8 callbacks", worst);
        console.log("react gas, 50 vaults crossing the line at once", firstCross);
    }

    function _gasOf(ChaserReactive target, IReactive.LogRecord memory log_) internal returns (uint256 used) {
        vm.prank(SYSTEM);
        uint256 before = gasleft();
        target.react(log_);
        used = before - gasleft();
    }

    function _newRc(uint256 maxVaults_) internal returns (ChaserReactive) {
        return new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 1_000_000, TIMEOUT, CONFIRM, maxVaults_);
    }

    /// A swap at `tick`, then the same tick once the confirmation window has passed.
    function _confirm(int24 tick) internal {
        _react(_swap(tick));
        vm.warp(block.timestamp + CONFIRM);
        _react(_swap(tick));
    }

    function _reactOn(ChaserReactive target, IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        target.react(log_);
    }

    function _react(IReactive.LogRecord memory log_) internal {
        _reactOn(rc, log_);
    }

    function _swap(int24 tick) internal pure returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = POOL_MANAGER;
        log_.topic0 = uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
        log_.topic1 = uint256(POOL_ID);
        log_.data = abi.encode(int128(-1), int128(1), uint160(1), uint128(1), tick, uint24(3000));
    }

    function _created(address v, int24 lower, int24 upper) internal returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = factory;
        log_.topic0 = uint256(keccak256("VaultCreated(bytes32,address,address,int24,int24)"));
        log_.topic1 = uint256(POOL_ID);
        log_.topic2 = uint256(uint160(v));
        log_.topic3 = uint256(uint160(makeAddr("owner")));
        log_.data = abi.encode(lower, upper);
    }

    function _fromFactory(address v, string memory signature) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = factory;
        log_.topic0 = uint256(keccak256(bytes(signature)));
        log_.topic1 = uint256(POOL_ID);
        log_.topic2 = uint256(uint160(v));
    }

    function _rangeMoved(address v, int24 lower, int24 upper) internal view returns (IReactive.LogRecord memory log_) {
        log_ = _fromFactory(v, "VaultMoved(bytes32,address,int24,int24)");
        log_.data = abi.encode(lower, upper);
    }

    function _paused(address v, bool paused_) internal view returns (IReactive.LogRecord memory log_) {
        log_ = _fromFactory(v, "VaultPaused(bytes32,address,bool)");
        log_.data = abi.encode(paused_);
    }

    function _withdrawn(address v) internal view returns (IReactive.LogRecord memory log_) {
        log_ = _fromFactory(v, "VaultClosed(bytes32,address)");
    }
}
