// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Chaser} from "../script/Chaser.s.sol";

// NETWORK is a process-wide env var and forge runs tests in parallel, so every case lives in one test
contract ChaserScriptTest is Test {
    function _script(string memory network, uint256 chainId) internal returns (Chaser s) {
        vm.setEnv("NETWORK", network);
        s = new Chaser();
        s.setUp();
        vm.chainId(chainId);
    }

    function test_scriptRefusesTheWrongChainAndTestStepsOnMainnet() public {
        Chaser s = _script("unichain-sepolia", 5318007);
        vm.expectRevert(bytes("rpc is not this network's chain"));
        s.factory(address(1));
        vm.expectRevert(bytes("rpc is not this network's chain"));
        s.create(address(1));
        vm.expectRevert(bytes("rpc is not this network's chain"));
        s.pool();

        s = _script("unichain-sepolia", 1301);
        vm.expectRevert(bytes("rpc is not this network's reactive chain"));
        s.reactive();
        vm.expectRevert(bytes("rpc is not this network's reactive chain"));
        s.linkFactory(address(1), address(2));

        s = _script("unichain", 130);
        vm.expectRevert(bytes("testnet-only step"));
        s.pool();
        vm.expectRevert(bytes("testnet-only step"));
        s.create(address(1));

        // mainnet has no pool yet: the right chain passes the guard and the empty pool stops it before deploying
        s = _script("unichain", 1597);
        try s.reactive() {
            fail();
        } catch (bytes memory err) {
            assertTrue(
                keccak256(err)
                    != keccak256(abi.encodeWithSignature("Error(string)", "rpc is not this network's reactive chain"))
            );
        }
    }
}
