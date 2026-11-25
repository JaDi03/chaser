// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
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
    int24 internal constant TRIGGER = 960;
    uint256 internal constant TIMEOUT = 300;
    uint256 internal constant T0 = 1_700_000_000;

    ChaserReactive internal rc;
    MockSystem internal system;
    address internal vault = makeAddr("vault");

    function setUp() public {
        vm.warp(T0);
        vm.etch(SYSTEM, address(new MockSystem()).code);
        system = MockSystem(payable(SYSTEM));
        rc = new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 0);
        rc.setVault(vault);
        _react(_rangeMoved(-480, 480));
    }

    function test_constructorAndSetVaultSubscribe() public view {
        assertEq(system.subscribeCount(), 2);
        assertEq(rc.vault(), vault);
        assertTrue(rc.hasRange());
        assertEq(rc.tickLower(), -480);
        assertEq(rc.tickUpper(), 480);
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory log_ = _swap(5000);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        rc.react(log_);
    }

    function test_setVaultOnlyOwnerAndOnce() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChaserReactive.NotOwner.selector);
        rc.setVault(address(1));
        vm.expectRevert(ChaserReactive.VaultAlreadySet.selector);
        rc.setVault(address(1));
    }

    function test_noCallbackInsideTrigger() public {
        _react(_swap(480 + TRIGGER - 1));
        _react(_swap(-480 - TRIGGER));
        assertEq(system.callbackCount(), 0);
    }

    function test_callbackAboveTrigger() public {
        _react(_swap(480 + TRIGGER));
        assertEq(system.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = system.lastCallback();
        assertEq(cb.chainId, CHAIN);
        assertEq(cb.recipient, vault);
        assertEq(cb.gasLimit, 1_000_000);
        assertEq(cb.payload, abi.encodeWithSignature("rebalance(address,int24)", address(0), int24(480 + TRIGGER)));
        assertTrue(rc.pending());
    }

    function test_callbackBelowTrigger() public {
        _react(_swap(-480 - TRIGGER - 1));
        assertEq(system.callbackCount(), 1);
    }

    function test_pendingBlocksRepeatsUntilTimeout() public {
        _react(_swap(5000));
        _react(_swap(5100));
        assertEq(system.callbackCount(), 1);
        vm.warp(block.timestamp + TIMEOUT);
        _react(_swap(5200));
        assertEq(system.callbackCount(), 2);
    }

    function test_rangeMovedClearsPending() public {
        _react(_swap(5000));
        _react(_rangeMoved(4020, 4980));
        assertFalse(rc.pending());
        assertEq(rc.tickLower(), 4020);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 1);
    }

    function test_ignoresOtherSources() public {
        IReactive.LogRecord memory log_ = _swap(5000);
        log_.topic1 = uint256(POOL_ID) + 1;
        _react(log_);
        log_ = _swap(5000);
        log_.contractAddress = address(0xBAD);
        _react(log_);
        log_ = _swap(5000);
        log_.chainId = CHAIN + 1;
        _react(log_);
        assertEq(system.callbackCount(), 0);

        IReactive.LogRecord memory fake = _rangeMoved(9000, 9960);
        fake.contractAddress = address(0xBAD);
        _react(fake);
        assertEq(rc.tickLower(), -480);
    }

    function test_pauseStopsCallbacks() public {
        rc.pause();
        assertEq(system.unsubscribeCount(), 1);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 0);
        rc.resume();
        _react(_swap(5000));
        assertEq(system.callbackCount(), 1);
    }

    function test_noCallbackBeforeRangeKnown() public {
        ChaserReactive fresh = new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 0);
        fresh.setVault(vault);
        vm.prank(SYSTEM);
        fresh.react(_swap(5000));
        assertEq(system.callbackCount(), 0);
    }

    // A1, A5: a single swap past the line, or a round trip, never asks for a move before the confirmation window
    function test_confirmationWindowBlocksAQuickPush() public {
        ChaserReactive slow = _slow();
        _reactOn(slow, _swap(5000));
        assertEq(system.callbackCount(), 0);
        vm.warp(T0 + 30);
        _reactOn(slow, _swap(0));
        vm.warp(T0 + 90);
        _reactOn(slow, _swap(5000));
        assertEq(system.callbackCount(), 0);
        assertEq(slow.beyondSince(), T0 + 90);
    }

    function test_confirmationWindowAsksAfterThePriceStays() public {
        ChaserReactive slow = _slow();
        _reactOn(slow, _swap(5000));
        vm.warp(T0 + 59);
        _reactOn(slow, _swap(5100));
        assertEq(system.callbackCount(), 0);
        vm.warp(T0 + 60);
        _reactOn(slow, _swap(5200));
        assertEq(system.callbackCount(), 1);
        assertEq(
            system.lastCallback().payload, abi.encodeWithSignature("rebalance(address,int24)", address(0), int24(5200))
        );
    }

    function test_switchingSideRestartsTheWindow() public {
        ChaserReactive slow = _slow();
        _reactOn(slow, _swap(5000));
        vm.warp(T0 + 60);
        _reactOn(slow, _swap(-5000));
        assertEq(system.callbackCount(), 0);
        assertFalse(slow.beyondUp());
    }

    // A7: after the vault is withdrawn the reactive contract stops asking
    function test_withdrawnStopsCallbacks() public {
        IReactive.LogRecord memory log_ = _rangeMoved(0, 0);
        log_.topic0 = uint256(keccak256("Withdrawn(uint256,uint256,uint256)"));
        log_.data = abi.encode(uint256(1), uint256(2), uint256(0));
        _react(log_);
        assertFalse(rc.hasRange());
        _react(_swap(5000));
        assertEq(system.callbackCount(), 0);
    }

    function test_otherVaultEventsAreIgnored() public {
        IReactive.LogRecord memory log_ = _rangeMoved(9000, 9960);
        log_.topic0 = uint256(keccak256("PausedSet(bool)"));
        _react(log_);
        assertTrue(rc.hasRange());
        assertEq(rc.tickLower(), -480);
    }

    function test_pendingTimeoutBoundary() public {
        _react(_swap(5000));
        vm.warp(T0 + TIMEOUT - 1);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 1);
        vm.warp(T0 + TIMEOUT);
        _react(_swap(5000));
        assertEq(system.callbackCount(), 2);
        assertEq(rc.pendingSince(), T0 + TIMEOUT);
    }

    function test_ignoresLowerChainId() public {
        IReactive.LogRecord memory log_ = _swap(5000);
        log_.chainId = CHAIN - 1;
        _react(log_);
        assertEq(system.callbackCount(), 0);
    }

    function test_pauseAndResumeAreIdempotentAndResubscribe() public {
        uint256 subs = system.subscribeCount();
        rc.pause();
        rc.pause();
        assertEq(system.unsubscribeCount(), 1);
        rc.resume();
        rc.resume();
        assertEq(system.subscribeCount(), subs + 1);
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

    // A6: parameters out of bounds are refused
    function test_constructorBounds() public {
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, address(0), POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 0, 1_000_000, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, 200_001, 1_000_000, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 299_999, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 3_000_001, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, 59, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, 1 days + 1, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 1 days + 1);
    }

    function test_setVaultRefusesZero() public {
        ChaserReactive fresh = new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 0);
        vm.expectRevert(ChaserReactive.InvalidParams.selector);
        fresh.setVault(address(0));
    }

    function _slow() internal returns (ChaserReactive slow) {
        slow = new ChaserReactive(CHAIN, POOL_MANAGER, POOL_ID, TRIGGER, 1_000_000, TIMEOUT, 60);
        slow.setVault(vault);
        _reactOn(slow, _rangeMoved(-480, 480));
    }

    function _reactOn(ChaserReactive target, IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        target.react(log_);
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        rc.react(log_);
    }

    function _swap(int24 tick) internal pure returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = POOL_MANAGER;
        log_.topic0 = uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
        log_.topic1 = uint256(POOL_ID);
        log_.data = abi.encode(int128(-1), int128(1), uint160(1), uint128(1), tick, uint24(3000));
    }

    function _rangeMoved(int24 lower, int24 upper) internal view returns (IReactive.LogRecord memory log_) {
        log_.chainId = CHAIN;
        log_.contractAddress = vault;
        log_.topic0 = uint256(keccak256("RangeMoved(uint256,int24,int24,int24,uint128)"));
        log_.data = abi.encode(lower, upper, int24(0), uint128(1));
    }
}
