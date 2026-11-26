// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ChaserVault} from "../src/ChaserVault.sol";
import {ChaserFactory} from "../src/ChaserFactory.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {ForkBase} from "./utils/ForkBase.sol";

/// Runs against the official Uniswap v4 contracts on a pinned Unichain Sepolia fork; the vault is made by the factory.
contract ChaserVaultForkTest is ForkBase {
    using PoolIdLibrary for PoolKey;

    ChaserVault internal vault;

    function setUp() public {
        _setUpFork();
        vault = _create(owner, 10e18, 10e18);
    }

    /// Lets this test contract stand in as the factory of vaults it deploys directly.
    function vaultClosed() external {}

    function vaultMoved(int24, int24) external {}

    function vaultPaused(bool) external {}

    function test_openMintsPositionAndRefundsTheRest() public view {
        assertGt(vault.tokenId(), 0);
        assertEq(IERC721(address(posm)).ownerOf(vault.tokenId()), address(vault));
        assertGt(posm.getPositionLiquidity(vault.tokenId()), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(vault.triggerTicks(), WIDTH);
        assertEq(vault.owner(), owner);
        assertEq(address(vault.factory()), address(factory));
    }

    function test_rebalanceOnlyFromProxyAndOurReactiveContract() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), proxy));
        vault.rebalance(rc, 0);

        address fakeRc = makeAddr("fakeRc");
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, fakeRc, rc));
        vault.rebalance(fakeRc, 0);
    }

    function test_skipsInsideTrigger() public {
        _moveTo(UPPER + WIDTH - 120);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.InsideTrigger, _tick());
        _rebalance();
        assertEq(vault.tokenId(), id);
    }

    function test_movesBelowThePriceAfterATrendUp() public {
        _moveTo(UPPER + WIDTH + 300);
        int24 tick = _tick();
        _rebalance();

        assertEq(vault.tickUpper() - vault.tickLower(), WIDTH);
        assertLe(vault.tickUpper(), tick);
        assertGt(vault.tickUpper(), tick - SPACING);
        _assertSingleToken(false);
    }

    function test_movesAboveThePriceAfterATrendDown() public {
        _moveTo(LOWER - WIDTH - 300);
        int24 tick = _tick();
        _rebalance();

        assertEq(vault.tickUpper() - vault.tickLower(), WIDTH);
        assertGt(vault.tickLower(), tick);
        assertLe(vault.tickLower(), tick + SPACING);
        _assertSingleToken(true);
    }

    function test_neverSwaps() public {
        _moveTo(UPPER + WIDTH + 300);
        (uint256 before0, uint256 before1) = _amountsOf(vault);
        assertEq(before0, 0);
        _rebalance();
        (uint256 after0,) = _amountsOf(vault);
        // all token1 is still held (plus fees), and no token1 became token0: token0 is only fees in the vault
        assertGe(_held1() + 10, before1);
        assertEq(after0, 0);
        assertEq(_held0(), token0.balanceOf(address(vault)));
    }

    function test_cooldownBlocksASecondMove() public {
        _moveTo(UPPER + WIDTH + 300);
        _rebalance();
        _moveTo(vault.tickUpper() + WIDTH + 300);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.CoolingDown, _tick());
        _rebalance();
        assertEq(vault.tokenId(), id);
        vm.warp(block.timestamp + COOLDOWN);
        _rebalance();
        assertTrue(vault.tokenId() != id);
    }

    function test_pausedSkipsButWithdrawStillWorks() public {
        vm.prank(owner);
        vault.setPaused(true);
        _moveTo(UPPER + WIDTH + 300);
        uint256 id = vault.tokenId();
        _rebalance();
        assertEq(vault.tokenId(), id);

        vm.prank(owner);
        vault.withdraw(owner);
        assertEq(vault.tokenId(), 0);
        assertGt(token1.balanceOf(owner), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }

    function test_onlyOwnerCanWithdrawAndPause() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(ChaserVault.NotOwner.selector);
        vault.withdraw(stranger);
        vm.expectRevert(ChaserVault.NotOwner.selector);
        vault.setPaused(true);
        vm.stopPrank();
    }

    function test_onlyTheFactoryOpensAndOnlyOnce() public {
        vm.prank(owner);
        vm.expectRevert(ChaserVault.NotFactory.selector);
        vault.open(LOWER, UPPER, 1, 0, 0);
        vm.prank(address(factory));
        vm.expectRevert(ChaserVault.AlreadyOpened.selector);
        vault.open(LOWER, UPPER, 1, 0, 0);
    }

    // F5: a pause change is reported to the factory once; repeats do nothing and changes are spaced out
    function test_pauseIsReportedOnceAndSpacedOut() public {
        vm.startPrank(owner);
        vm.expectEmit(address(factory));
        emit ChaserFactory.VaultPaused(poolId, address(vault), true);
        vault.setPaused(true);
        vm.recordLogs();
        vault.setPaused(true);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.expectRevert(ChaserVault.PauseTooSoon.selector);
        vault.setPaused(false);
        vm.warp(block.timestamp + vault.MIN_PAUSE_INTERVAL());
        vault.setPaused(false);
        assertFalse(vault.paused());
        vm.stopPrank();
    }

    function test_movesAreReportedToTheFactory() public {
        _moveTo(UPPER + WIDTH + 300);
        vm.recordLogs();
        _rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("VaultMoved(bytes32,address,int24,int24)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != topic) continue;
            (int24 lower, int24 upper) = abi.decode(logs[i].data, (int24, int24));
            assertEq(lower, vault.tickLower());
            assertEq(upper, vault.tickUpper());
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(vault));
            found = true;
        }
        assertTrue(found);
    }

    // F1: a closed vault that still gets a callback makes the factory publish its closing again
    function test_closedVaultReportsTheClosingAgainOnACallback() public {
        vm.prank(owner);
        vault.withdraw(owner);
        vm.expectEmit(address(factory));
        emit ChaserFactory.VaultClosed(poolId, address(vault));
        _rebalance();
        assertEq(factory.activeVaults(poolId), 0);
    }

    // A16: the owner chooses where the funds go
    function test_withdrawToAnotherAddress() public {
        address to = makeAddr("coldWallet");
        vm.prank(owner);
        vault.withdraw(to);
        assertGt(token0.balanceOf(to), 0);
        assertGt(token1.balanceOf(to), 0);
        assertEq(token0.balanceOf(owner), 0);
        vm.prank(owner);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        vault.withdraw(address(0));
    }

    function test_withdrawClosesForGood() public {
        vm.prank(owner);
        vault.withdraw(owner);
        assertTrue(vault.closed());
        assertEq(factory.activeVaults(poolId), 0);
        vm.prank(owner);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        vault.setPaused(false);
        // a second withdraw sweeps what arrived later and does not count the vault as closed twice
        token1.mint(address(vault), 1e18);
        vm.prank(owner);
        vault.withdraw(owner);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(factory.activeVaults(poolId), 0);
        // the factory refuses to open it again
        vm.prank(address(factory));
        vm.expectRevert(ChaserVault.AlreadyOpened.selector);
        vault.open(LOWER, UPPER, 1, 0, 0);
    }

    function test_rejectsHookedPoolsAndTokensWithoutCode() public {
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(address(0xB00C));
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, hooked, owner, DEVIATION, COOLDOWN);

        PoolKey memory noCode = key;
        noCode.currency1 = Currency.wrap(address(0xDEAD));
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, noCode, owner, DEVIATION, COOLDOWN);
    }

    // A1: a price pushed after the reactive contract confirmed its tick does not move the position
    function test_deviationSkipsAPushedPrice() public {
        _moveTo(UPPER + WIDTH + 300);
        int24 confirmed = _tick();
        _moveTo(confirmed + 1000);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.Deviation, _tick());
        _rebalanceObserved(confirmed);
        assertEq(vault.tokenId(), id);
    }

    function test_deviationWithinToleranceStillMoves() public {
        _moveTo(UPPER + WIDTH + 300);
        int24 confirmed = _tick();
        _moveTo(confirmed + DEVIATION - 10);
        uint256 id = vault.tokenId();
        _rebalanceObserved(confirmed);
        assertTrue(vault.tokenId() != id);
    }

    // A9: the downside half of the rule
    function test_skipsInsideTriggerBelow() public {
        _moveTo(LOWER - WIDTH + 60);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.InsideTrigger, _tick());
        _rebalance();
        assertEq(vault.tokenId(), id);
    }

    function test_negativeUnalignedTickAlignsTheNewRange() public {
        _moveTo(LOWER - WIDTH - 337);
        int24 tick = _tick();
        assertTrue(tick % SPACING != 0);
        _rebalance();
        assertEq(vault.tickLower() % SPACING, 0);
        assertGt(vault.tickLower(), tick);
        assertLe(vault.tickLower(), tick + SPACING);
    }

    function test_withdrawSendsToken0AfterATrendDown() public {
        _moveTo(LOWER - WIDTH - 300);
        _rebalance();
        uint256 before0 = token0.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(owner);
        assertGt(token0.balanceOf(owner), before0);
        assertEq(token0.balanceOf(address(vault)), 0);
    }

    function test_noPositionSkips() public {
        vm.prank(owner);
        vault.withdraw(owner);
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.NoPosition, _tick());
        _rebalance();
    }

    // A2: native currency sent to the vault goes back to the owner
    function test_withdrawReturnsNative() public {
        vm.deal(makeAddr("sender"), 1 ether);
        vm.prank(makeAddr("sender"));
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdraw(owner);
        assertEq(owner.balance, before + 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_payOnlyFromProxy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, makeAddr("stranger"), proxy));
        vault.pay(1);
    }

    // A4: a huge donation of the held token does not block moves; the excess stays and leaves with withdraw
    function test_hugeDonationDoesNotBlockMoves() public {
        _moveTo(UPPER + WIDTH + 300);
        uint256 donation = uint256(type(uint128).max) + 1;
        token1.mint(address(vault), donation);
        uint256 id = vault.tokenId();
        _rebalance();
        assertTrue(vault.tokenId() != id);
        assertGe(token1.balanceOf(address(vault)), donation);
    }

    // A6: parameters out of bounds are refused
    function test_constructorBounds() public {
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, 0, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, 200_001, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, DEVIATION, 30 days + 1);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, address(0), DEVIATION, COOLDOWN);
    }

    // D4: a price tolerance wider than the range is refused when the position opens
    function test_openRefusesADeviationWiderThanTheRange() public {
        ChaserVault v = new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, 2 * WIDTH, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        v.open(LOWER, UPPER, 1, 0, 0);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        v.open(UPPER, LOWER, 1, 0, 0);
    }

    // the shared reactive contract learns the vault from the real VaultCreated and follows the real RangeMoved
    function test_reactiveContractReadsTheRealEvents() public {
        vm.etch(0x8888888888888888888888888888888888888888, address(new MockSystem()).code);
        ChaserReactive reactive =
            new ChaserReactive(block.chainid, address(manager), PoolId.unwrap(poolId), 1_000_000, 300, 60, 10);
        reactive.setFactory(address(factory));

        vm.recordLogs();
        ChaserVault v = _create(makeAddr("second"), 10e18, 10e18);
        _forward(reactive, vm.getRecordedLogs());
        ChaserReactive.Watch memory w = reactive.watchOf(address(v));
        assertEq(w.tickLower, v.tickLower());
        assertEq(w.tickUpper, v.tickUpper());

        _moveTo(UPPER + WIDTH + 300);
        int24 confirmed = _tick();
        vm.recordLogs();
        vm.prank(proxy);
        v.rebalance(rc, confirmed);
        _forward(reactive, vm.getRecordedLogs());
        w = reactive.watchOf(address(v));
        assertEq(w.tickLower, v.tickLower());
        assertEq(w.tickUpper, v.tickUpper());

        vm.recordLogs();
        vm.prank(makeAddr("second"));
        v.withdraw(makeAddr("second"));
        _forward(reactive, vm.getRecordedLogs());
        assertEq(reactive.watchOf(address(v)).slot, 0);
    }

    // D1: a stranger's wei cannot freeze the withdrawal of an owner that refuses native currency
    function test_withdrawWorksForAnOwnerThatRefusesNative() public {
        RefusesNative refuser = new RefusesNative();
        ChaserVault v =
            new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, address(refuser), DEVIATION, COOLDOWN);
        token1.mint(address(v), 3e18);
        vm.deal(makeAddr("stranger"), 1);
        vm.prank(makeAddr("stranger"));
        (bool ok,) = address(v).call{value: 1}("");
        assertTrue(ok);
        vm.prank(address(refuser));
        v.withdraw(address(refuser));
        assertEq(token1.balanceOf(address(refuser)), 3e18);
        assertEq(address(v).balance, 1);
    }

    function _forward(ChaserReactive reactive, Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; i++) {
            IReactive.LogRecord memory log_;
            log_.chainId = block.chainid;
            log_.contractAddress = logs[i].emitter;
            log_.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) log_.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) log_.topic2 = uint256(logs[i].topics[2]);
            if (logs[i].topics.length > 3) log_.topic3 = uint256(logs[i].topics[3]);
            log_.data = logs[i].data;
            vm.prank(0x8888888888888888888888888888888888888888);
            reactive.react(log_);
        }
    }

    /// The reactive contract confirmed the current tick; read it before the prank, which applies to the next call.
    function _rebalance() internal {
        _rebalanceObserved(_tick());
    }

    function _rebalanceObserved(int24 observedTick) internal {
        vm.prank(proxy);
        vault.rebalance(rc, observedTick);
    }

    function _held0() internal view returns (uint256) {
        (uint256 amount0,) = _amountsOf(vault);
        return amount0 + token0.balanceOf(address(vault));
    }

    function _held1() internal view returns (uint256) {
        (, uint256 amount1) = _amountsOf(vault);
        return amount1 + token1.balanceOf(address(vault));
    }

    function _assertSingleToken(bool onlyToken0) internal view {
        (uint256 amount0, uint256 amount1) = _amountsOf(vault);
        if (onlyToken0) {
            assertGt(amount0, 0);
            assertEq(amount1, 0);
        } else {
            assertEq(amount0, 0);
            assertGt(amount1, 0);
        }
    }
}

/// An owner contract with no way to receive native currency.
contract RefusesNative {}
