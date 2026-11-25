// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// Checks that every dependency the contracts rely on resolves and keeps the action ids we build on.
contract DependenciesTest is Test {
    function test_positionManagerActionIds() public pure {
        assertEq(Actions.BURN_POSITION, 0x03);
        assertEq(Actions.MINT_POSITION_FROM_DELTAS, 0x05);
        assertEq(Actions.TAKE_PAIR, 0x11);
    }

    function test_singleTokenRangeNeedsOnlyOneToken() public pure {
        uint160 price = TickMath.getSqrtPriceAtTick(0);
        uint160 lower = TickMath.getSqrtPriceAtTick(60);
        uint160 upper = TickMath.getSqrtPriceAtTick(120);
        // a range fully above the price is filled with currency0 alone
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(price, lower, upper, 1e18, 0);
        assertGt(liquidity, 0);
    }
}
