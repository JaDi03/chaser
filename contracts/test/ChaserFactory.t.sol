// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ChaserFactory} from "../src/ChaserFactory.sol";
import {ChaserVault} from "../src/ChaserVault.sol";
import {ForkBase} from "./utils/ForkBase.sol";

contract ChaserFactoryForkTest is ForkBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpFork();
    }

    function test_createOpensACenteredRangeForTheCaller() public {
        token0.mint(owner, 10e18);
        token1.mint(owner, 10e18);
        vm.deal(owner, RESERVE);
        vm.startPrank(owner);
        token0.approve(address(factory), 10e18);
        token1.approve(address(factory), 10e18);
        assertEq(_tick(), 0);
        vm.expectEmit(true, false, true, true, address(factory));
        emit ChaserFactory.VaultCreated(poolId, address(0), owner, LOWER, UPPER);
        ChaserVault v = ChaserVault(payable(factory.create{value: RESERVE}(poolId, 10e18, 10e18, 0, SPACING)));
        vm.stopPrank();

        assertEq(v.owner(), owner);
        assertEq(v.tickLower(), LOWER);
        assertEq(v.tickUpper(), UPPER);
        assertEq(IERC721(address(posm)).ownerOf(v.tokenId()), address(v));
        assertTrue(factory.isVault(address(v)));
        assertEq(PoolId.unwrap(factory.vaultPool(address(v))), PoolId.unwrap(poolId));
        assertEq(factory.activeVaults(poolId), 1);
        assertEq(_reserveOf(address(v)), RESERVE);
        // nothing stays in the factory
        assertEq(token0.balanceOf(address(factory)), 0);
        assertEq(token1.balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);
    }

    function test_createRefundsWhatThePositionDoesNotUse() public {
        // at a centered price the position takes about the same of each token
        ChaserVault v = _create(owner, 10e18, 30e18);
        assertGt(token1.balanceOf(owner), 19e18);
        assertEq(token0.balanceOf(address(v)), 0);
        assertEq(token1.balanceOf(address(v)), 0);
    }

    function test_rangeFollowsTheCurrentPrice() public {
        _moveTo(1337);
        int24 tick = _tick();
        ChaserVault v = _create(owner, 10e18, 10e18);
        int24 floored = (tick / SPACING) * SPACING;
        assertEq(v.tickLower(), floored - WIDTH / 2);
        assertEq(v.tickUpper(), floored + WIDTH / 2);
    }

    function test_unknownPoolIsRefused() public {
        PoolId other = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(ChaserFactory.PoolNotAllowed.selector);
        factory.create{value: RESERVE}(other, 1e18, 1e18, 0, SPACING);
    }

    // a price pushed just before the deposit cannot set the range
    function test_movedPriceIsRefused() public {
        int24 seen = _tick();
        _moveTo(seen + 600);
        token0.mint(owner, 10e18);
        token1.mint(owner, 10e18);
        vm.deal(owner, RESERVE);
        vm.startPrank(owner);
        token0.approve(address(factory), 10e18);
        token1.approve(address(factory), 10e18);
        int24 pushed = _tick();
        vm.expectRevert(abi.encodeWithSelector(ChaserFactory.PriceMoved.selector, pushed, seen));
        factory.create{value: RESERVE}(poolId, 10e18, 10e18, seen, SPACING);
        int24 now_ = _tick();
        vm.expectRevert(abi.encodeWithSelector(ChaserFactory.PriceMoved.selector, now_, now_));
        factory.create{value: RESERVE}(poolId, 10e18, 10e18, now_, -1);
        vm.stopPrank();
    }

    // F3: the reserve is the exact amount of the config; more or less is refused, so nothing extra stays at the proxy
    function test_reserveMustBeExact() public {
        int24 tick = _tick();
        vm.expectRevert(ChaserFactory.WrongReserve.selector);
        factory.create{value: RESERVE - 1}(poolId, 10e18, 10e18, tick, SPACING);
        vm.expectRevert(ChaserFactory.WrongReserve.selector);
        factory.create{value: RESERVE + 1}(poolId, 10e18, 10e18, tick, SPACING);
    }

    function test_dustDepositIsRefused() public {
        token0.mint(owner, 1e9);
        token1.mint(owner, 1e9);
        vm.deal(owner, RESERVE);
        vm.startPrank(owner);
        token0.approve(address(factory), 1e9);
        token1.approve(address(factory), 1e9);
        int24 tick = _tick();
        vm.expectRevert(ChaserFactory.DepositTooSmall.selector);
        factory.create{value: RESERVE}(poolId, 1e9, 1e9, tick, SPACING);
        vm.stopPrank();
    }

    function test_capRefusesMoreVaultsUntilOneCloses() public {
        ChaserVault first = _create(makeAddr("u1"), 10e18, 10e18);
        _create(makeAddr("u2"), 10e18, 10e18);
        _create(makeAddr("u3"), 10e18, 10e18);
        int24 tick = _tick();
        vm.expectRevert(ChaserFactory.PoolFull.selector);
        factory.create{value: RESERVE}(poolId, 10e18, 10e18, tick, SPACING);

        vm.prank(makeAddr("u1"));
        first.withdraw(makeAddr("u1"));
        assertEq(factory.activeVaults(poolId), 2);
        _create(makeAddr("u4"), 10e18, 10e18);
        assertEq(factory.activeVaults(poolId), 3);
    }

    // F1: only its vaults report; a closing counts once, and a closed vault may publish it again
    function test_onlyItsVaultsReportAndAClosingCountsOnce() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(ChaserFactory.NotVault.selector);
        factory.vaultClosed();
        vm.expectRevert(ChaserFactory.NotVault.selector);
        factory.vaultMoved(0, 960);
        vm.expectRevert(ChaserFactory.NotVault.selector);
        factory.vaultPaused(true);
        vm.stopPrank();

        ChaserVault v = _create(owner, 10e18, 10e18);
        _create(makeAddr("other"), 10e18, 10e18);
        vm.startPrank(address(v));
        vm.expectEmit(address(factory));
        emit ChaserFactory.VaultMoved(poolId, address(v), 0, 960);
        factory.vaultMoved(0, 960);
        vm.expectEmit(address(factory));
        emit ChaserFactory.VaultPaused(poolId, address(v), true);
        factory.vaultPaused(true);
        factory.vaultClosed();
        assertEq(factory.activeVaults(poolId), 1);
        vm.expectEmit(address(factory));
        emit ChaserFactory.VaultClosed(poolId, address(v));
        factory.vaultClosed();
        assertEq(factory.activeVaults(poolId), 1);
        // a closed vault reports no more moves or pauses
        vm.expectRevert(ChaserFactory.NotVault.selector);
        factory.vaultMoved(0, 960);
        vm.expectRevert(ChaserFactory.NotVault.selector);
        factory.vaultPaused(false);
        vm.stopPrank();
    }

    // nobody can spend another user's approval: the tokens always come from the caller
    function test_approvalOfOneUserCannotBeUsedByAnother() public {
        token0.mint(owner, 10e18);
        token1.mint(owner, 10e18);
        vm.startPrank(owner);
        token0.approve(address(factory), 10e18);
        token1.approve(address(factory), 10e18);
        vm.stopPrank();
        address stranger = makeAddr("stranger");
        vm.deal(stranger, RESERVE);
        int24 tick = _tick();
        vm.prank(stranger);
        vm.expectRevert();
        factory.create{value: RESERVE}(poolId, 10e18, 10e18, tick, SPACING);
        assertEq(token0.balanceOf(owner), 10e18);
    }

    function test_theFactoryCannotTouchAVault() public {
        ChaserVault v = _create(owner, 10e18, 10e18);
        vm.startPrank(address(factory));
        vm.expectRevert(ChaserVault.NotOwner.selector);
        v.withdraw(address(factory));
        vm.expectRevert(ChaserVault.NotOwner.selector);
        v.setPaused(true);
        vm.stopPrank();
    }

    function test_constructorRefusesBadPools() public {
        ChaserFactory.PoolConfig memory p = _config();
        p.widthTicks = 900;
        _expectBadFactory(p);
        p = _config();
        p.maxDeviationTicks = WIDTH + 1;
        _expectBadFactory(p);
        p = _config();
        p.maxDeviationTicks = 0;
        _expectBadFactory(p);
        p = _config();
        p.reactive = address(0);
        _expectBadFactory(p);
        p = _config();
        p.maxVaults = 0;
        _expectBadFactory(p);
        p = _config();
        p.minLiquidity = 0;
        _expectBadFactory(p);

        ChaserFactory.PoolConfig[] memory twice = new ChaserFactory.PoolConfig[](2);
        twice[0] = _config();
        twice[1] = _config();
        vm.expectRevert(ChaserFactory.InvalidParams.selector);
        new ChaserFactory(IPayable(payable(proxy)), posm, permit2, twice);

        ChaserFactory.PoolConfig[] memory none = new ChaserFactory.PoolConfig[](0);
        vm.expectRevert(ChaserFactory.InvalidParams.selector);
        new ChaserFactory(IPayable(payable(proxy)), posm, permit2, none);
    }

    function test_poolListIsReadable() public view {
        PoolId[] memory ids = factory.poolIds();
        assertEq(ids.length, 1);
        assertEq(PoolId.unwrap(ids[0]), PoolId.unwrap(poolId));
        assertEq(factory.poolConfig(poolId).reactive, rc);
    }

    function _expectBadFactory(ChaserFactory.PoolConfig memory p) internal {
        ChaserFactory.PoolConfig[] memory pools = new ChaserFactory.PoolConfig[](1);
        pools[0] = p;
        vm.expectRevert(ChaserFactory.InvalidParams.selector);
        new ChaserFactory(IPayable(payable(proxy)), posm, permit2, pools);
    }
}
