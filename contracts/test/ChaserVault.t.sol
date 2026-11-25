// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
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
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ChaserVault} from "../src/ChaserVault.sol";
import {ChaserReactive} from "../src/ChaserReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestToken} from "../src/test-utils/TestToken.sol";

/// Runs against the official Uniswap v4 contracts on a pinned Unichain Sepolia fork.
contract ChaserVaultForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 68_778_100;
    int24 internal constant SPACING = 60;
    int24 internal constant LOWER = -480;
    int24 internal constant UPPER = 480;
    int24 internal constant TRIGGER = 960;
    uint256 internal constant COOLDOWN = 60;
    int24 internal constant DEVIATION = 240;

    IPositionManager internal posm;
    IPoolManager internal manager;
    IAllowanceTransfer internal permit2;
    address internal proxy;
    address internal rc = makeAddr("reactiveContract");
    address internal owner = makeAddr("owner");
    PoolKey internal key;
    PoolSwapTest internal swapper;
    ChaserVault internal vault;
    TestToken internal token0;
    TestToken internal token1;

    function setUp() public {
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
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // background liquidity so swaps can move the price across a wide band
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        _fundAndApprove(address(this), address(lp), 1e30);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60_000, 60_000, 1e21, 0), "");
        swapper = new PoolSwapTest(manager);
        _fundAndApprove(address(this), address(swapper), 0);

        vault = new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, TRIGGER, DEVIATION, COOLDOWN);
        _open(10e18, 10e18);
    }

    function test_openMintsPositionAndRefundsTheRest() public view {
        assertGt(vault.tokenId(), 0);
        assertEq(IERC721(address(posm)).ownerOf(vault.tokenId()), address(vault));
        assertGt(posm.getPositionLiquidity(vault.tokenId()), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
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
        _moveTo(UPPER + TRIGGER - 120);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.InsideTrigger, _tick());
        _rebalance();
        assertEq(vault.tokenId(), id);
    }

    function test_movesBelowThePriceAfterATrendUp() public {
        _moveTo(UPPER + TRIGGER + 300);
        int24 tick = _tick();
        _rebalance();

        assertEq(vault.tickUpper() - vault.tickLower(), UPPER - LOWER);
        assertLe(vault.tickUpper(), tick);
        assertGt(vault.tickUpper(), tick - SPACING);
        _assertSingleToken(false);
    }

    function test_movesAboveThePriceAfterATrendDown() public {
        _moveTo(LOWER - TRIGGER - 300);
        int24 tick = _tick();
        _rebalance();

        assertEq(vault.tickUpper() - vault.tickLower(), UPPER - LOWER);
        assertGt(vault.tickLower(), tick);
        assertLe(vault.tickLower(), tick + SPACING);
        _assertSingleToken(true);
    }

    function test_neverSwaps() public {
        _moveTo(UPPER + TRIGGER + 300);
        (uint256 before0, uint256 before1) = _amounts();
        assertEq(before0, 0);
        _rebalance();
        (uint256 after0,) = _amounts();
        // all token1 is still held (plus fees), and no token1 became token0: token0 is only fees in the vault
        assertGe(_held1() + 10, before1);
        assertEq(after0, 0);
        assertEq(_held0(), token0.balanceOf(address(vault)));
    }

    function test_cooldownBlocksASecondMove() public {
        _moveTo(UPPER + TRIGGER + 300);
        _rebalance();
        _moveTo(vault.tickUpper() + TRIGGER + 300);
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
        _moveTo(UPPER + TRIGGER + 300);
        uint256 id = vault.tokenId();
        _rebalance();
        assertEq(vault.tokenId(), id);

        vm.prank(owner);
        vault.withdraw();
        assertEq(vault.tokenId(), 0);
        assertGt(token1.balanceOf(owner), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }

    function test_onlyOwnerCanWithdrawPauseOpen() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(ChaserVault.NotOwner.selector);
        vault.withdraw();
        vm.expectRevert(ChaserVault.NotOwner.selector);
        vault.setPaused(true);
        vm.expectRevert(ChaserVault.NotOwner.selector);
        vault.open(LOWER, UPPER, 1, 1, 1);
        vm.stopPrank();
    }

    function test_rejectsHookedPoolsAndTokensWithoutCode() public {
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(address(0xB00C));
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, hooked, owner, TRIGGER, DEVIATION, COOLDOWN);

        PoolKey memory noCode = key;
        noCode.currency1 = Currency.wrap(address(0xDEAD));
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, noCode, owner, TRIGGER, DEVIATION, COOLDOWN);
    }

    // A1: a price pushed after the reactive contract confirmed its tick does not move the position
    function test_deviationSkipsAPushedPrice() public {
        _moveTo(UPPER + TRIGGER + 300);
        int24 confirmed = _tick();
        _moveTo(confirmed + 1000);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.Deviation, _tick());
        _rebalanceObserved(confirmed);
        assertEq(vault.tokenId(), id);
    }

    function test_deviationWithinToleranceStillMoves() public {
        _moveTo(UPPER + TRIGGER + 300);
        int24 confirmed = _tick();
        _moveTo(confirmed + DEVIATION - 10);
        uint256 id = vault.tokenId();
        _rebalanceObserved(confirmed);
        assertTrue(vault.tokenId() != id);
    }

    // A9: the downside half of the rule
    function test_skipsInsideTriggerBelow() public {
        _moveTo(LOWER - TRIGGER + 60);
        uint256 id = vault.tokenId();
        vm.expectEmit(address(vault));
        emit ChaserVault.RebalanceSkipped(ChaserVault.Skip.InsideTrigger, _tick());
        _rebalance();
        assertEq(vault.tokenId(), id);
    }

    function test_negativeUnalignedTickAlignsTheNewRange() public {
        _moveTo(LOWER - TRIGGER - 337);
        int24 tick = _tick();
        assertTrue(tick % SPACING != 0);
        _rebalance();
        assertEq(vault.tickLower() % SPACING, 0);
        assertGt(vault.tickLower(), tick);
        assertLe(vault.tickLower(), tick + SPACING);
    }

    function test_secondOpenIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ChaserVault.PositionAlreadyOpen.selector);
        vault.open(LOWER, UPPER, 1, 0, 0);
    }

    function test_openRefundsWhatIsNotUsed() public {
        vm.prank(owner);
        vault.withdraw();
        uint256 before0 = token0.balanceOf(owner);
        uint256 before1 = token1.balanceOf(owner);
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), 1e18, 1e18
        );
        vm.startPrank(owner);
        token0.approve(address(vault), 5e18);
        token1.approve(address(vault), 5e18);
        vault.open(LOWER, UPPER, liquidity, 5e18, 5e18);
        vm.stopPrank();
        assertGt(token0.balanceOf(owner), before0 - 5e18);
        assertGt(token1.balanceOf(owner), before1 - 5e18);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }

    function test_withdrawSendsToken0AfterATrendDown() public {
        _moveTo(LOWER - TRIGGER - 300);
        _rebalance();
        uint256 before0 = token0.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw();
        assertGt(token0.balanceOf(owner), before0);
        assertEq(token0.balanceOf(address(vault)), 0);
    }

    function test_noPositionSkips() public {
        vm.prank(owner);
        vault.withdraw();
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
        vault.withdraw();
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
        _moveTo(UPPER + TRIGGER + 300);
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
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, SPACING - 1, DEVIATION, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, 200_001, DEVIATION, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, TRIGGER, 0, COOLDOWN);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, owner, TRIGGER, DEVIATION, 30 days + 1);
        vm.expectRevert(ChaserVault.InvalidParams.selector);
        new ChaserVault(IPayable(payable(proxy)), rc, posm, permit2, key, address(0), TRIGGER, DEVIATION, COOLDOWN);
    }

    // the reactive contract decodes the vault's real RangeMoved event
    function test_reactiveContractReadsTheRealRangeMoved() public {
        vm.etch(0x8888888888888888888888888888888888888888, address(new MockSystem()).code);
        ChaserReactive reactive =
            new ChaserReactive(block.chainid, address(manager), PoolId.unwrap(key.toId()), TRIGGER, 1_000_000, 300, 0);
        reactive.setVault(address(vault));

        _moveTo(UPPER + TRIGGER + 300);
        vm.recordLogs();
        _rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("RangeMoved(uint256,int24,int24,int24,uint128)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != topic) continue;
            IReactive.LogRecord memory log_;
            log_.chainId = block.chainid;
            log_.contractAddress = address(vault);
            log_.topic0 = uint256(topic);
            log_.topic1 = uint256(logs[i].topics[1]);
            log_.data = logs[i].data;
            vm.prank(0x8888888888888888888888888888888888888888);
            reactive.react(log_);
        }
        assertEq(reactive.tickLower(), vault.tickLower());
        assertEq(reactive.tickUpper(), vault.tickUpper());
    }

    // D1: a stranger's wei cannot freeze the withdrawal of an owner that refuses native currency
    function test_withdrawWorksForAnOwnerThatRefusesNative() public {
        RefusesNative refuser = new RefusesNative();
        ChaserVault v = new ChaserVault(
            IPayable(payable(proxy)), rc, posm, permit2, key, address(refuser), TRIGGER, DEVIATION, COOLDOWN
        );
        token1.mint(address(v), 3e18);
        vm.deal(makeAddr("stranger"), 1);
        vm.prank(makeAddr("stranger"));
        (bool ok,) = address(v).call{value: 1}("");
        assertTrue(ok);
        vm.prank(address(refuser));
        v.withdraw();
        assertEq(token1.balanceOf(address(refuser)), 3e18);
        assertEq(address(v).balance, 1);
    }

    function _open(uint128 amount0, uint128 amount1) internal {
        token0.mint(owner, amount0);
        token1.mint(owner, amount1);
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), amount0, amount1
        );
        vm.startPrank(owner);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.open(LOWER, UPPER, liquidity, amount0, amount1);
        vm.stopPrank();
    }

    /// The reactive contract confirmed the current tick; read it before the prank, which applies to the next call.
    function _rebalance() internal {
        _rebalanceObserved(_tick());
    }

    function _rebalanceObserved(int24 observedTick) internal {
        vm.prank(proxy);
        vault.rebalance(rc, observedTick);
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
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _amounts() internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(vault.tickLower()),
            TickMath.getSqrtPriceAtTick(vault.tickUpper()),
            posm.getPositionLiquidity(vault.tokenId())
        );
    }

    function _held0() internal view returns (uint256) {
        (uint256 amount0,) = _amounts();
        return amount0 + token0.balanceOf(address(vault));
    }

    function _held1() internal view returns (uint256) {
        (, uint256 amount1) = _amounts();
        return amount1 + token1.balanceOf(address(vault));
    }

    function _assertSingleToken(bool onlyToken0) internal view {
        (uint256 amount0, uint256 amount1) = _amounts();
        if (onlyToken0) {
            assertGt(amount0, 0);
            assertEq(amount1, 0);
        } else {
            assertEq(amount0, 0);
            assertGt(amount1, 0);
        }
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

/// An owner contract with no way to receive native currency.
contract RefusesNative {}
