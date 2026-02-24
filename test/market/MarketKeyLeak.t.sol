// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketKeyLeakTest is MarketTestBase {
    // Deterministic fixture values from `go run ./cmd/export keyleak` (sk=12345, reporter=0xDEAD)
    uint256 constant KL_PUB_KEY = 0x259115f2259ea0923f1e3a18a4122a606d88ea1c25f49f8766df1aba7864efd1;
    address constant KL_REPORTER = address(0xDEAD);

    bytes constant KL_PROOF =
        hex"2c956e7cdf76d454f41135ce99880b8f1cfa47c1a3fb8623c5fc548e2fbacdff28803dacdee363811db870313ebe6711ca204cefcda48a974728eb49c827375e021f4ff28a87707d6f3b3eefd6f7f4f986fc4c2a0e6e6ee1c70e9c707630383a09010d38dd6c712a168def1b9cafcefc7cdb685b6e969b04f984a7b2f87e1870283fc8f5c672a50d8ab5399c84e317e9418ac3b7ab3bb36fa29665809e3867601e464f99c6833f3e40f5c153ccf73bc435c0212f665075603f4411bfb949bdaa0580aa03fd33c48faf3d6a67340cbcdd549ed445f90f64990dac20a8670b0d0e087c7d7d12a9c516e1c203b0c8e63691dbc1cbfa9c3e036c7b66d0da2c828e0e1a7731af35ced890d9573e3b8c8b59ef7c5824e4e7cb9bf1ea135798c29ca4250af6b753b91e673eb70767da66bb1664f9c219b882173b91e95f9c85ad890770095c83f10d5c4ad70be8d274c5593c25965ec285502821138b31fbf87ddb2676127f24cc12689cb02bb4233f06aff140d2a206f8c18ace01abc8e4107a19720308213ffa286b9fb7b616527bab050c20f92ddda563d5094e3285fc5bacbd64642e93599e18942530de35aea760e4b0cbcf47f14d34389b21adb896a12b7941d61764915d769199de7b78c8068e3ecce0335d5ce49ca7b9526657864a05760a470111dfc9f3902981bfeb2a4f711f7cfe8fb72cb40efe1913baff0115b2008d030c5f6924afa1a14fbd523c576f352f3431d0ae7551fb56036ad4b88494d5a0f11958c7a63b2399ced62e20ff10432d45ca12b993ea64698324be38b48d47c34805b8bf895b781d98e4e011cf38071dd41fd310d82fe9664a4010d544d2cffb0323a3c8128a45f25985212e278ed09908ca12bdd0c1b4b50270f28cf50683dd58034e4575b9682c5962431d95a224df249d0e85e23753d41f27b1774246931e0822bb0ae2dbd5842ff59b520a07f83b4e7169a1fc51ee84850447e3b01486310403c88599db891c6f2467f1aef0cab8bd80f88ec4ba75875b91b1a8833a0ea48e0b6ac46a27b51a037409070c07daf4149b150b0b5105d992765280056b132dc3";

    function _stakeNodeWithLeakedKey(address node) internal {
        _stakeNode(node, TEST_CAPACITY, KL_PUB_KEY);
    }

    function test_ReportKeyLeak_Success() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        assertTrue(market.keyCompromised(node1));
    }

    function test_ReportKeyLeak_SlashesFullStake() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);
        assertGt(stakeBefore, 0);

        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        // Node should be removed (no longer valid)
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_ReportKeyLeak_ReporterGetsReward() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        uint256 reward = market.reporterPendingRewards(KL_REPORTER);
        assertGt(reward, 0, "reporter should have pending reward");
    }

    function test_ReportKeyLeak_ForcedExitOnActiveOrders() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Place and execute an order so node1 has an active assignment
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        vm.prank(node1);
        market.executeOrder(orderId);

        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        // Node should be fully removed — no active orders
        assertTrue(market.keyCompromised(node1));
        assertFalse(nodeStaking.isValidNode(node1));
    }

    function test_ReportKeyLeak_RevertDoubleReport() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);

        vm.expectRevert("key already reported");
        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);
    }

    function test_ReportKeyLeak_RevertInvalidProof() public {
        _stakeNodeWithLeakedKey(node1);
        vm.deal(KL_REPORTER, 1 ether);

        // Corrupt the proof by flipping some bytes
        bytes memory badProof = KL_PROOF;
        badProof[0] = bytes1(uint8(badProof[0]) ^ 0xFF);
        badProof[1] = bytes1(uint8(badProof[1]) ^ 0xFF);

        vm.prank(KL_REPORTER);
        vm.expectRevert();
        market.reportKeyLeak(node1, badProof);
    }

    function test_ReportKeyLeak_RevertNotANode() public {
        vm.deal(KL_REPORTER, 1 ether);

        vm.expectRevert("not a valid node");
        vm.prank(KL_REPORTER);
        market.reportKeyLeak(node1, KL_PROOF);
    }

    function test_ReportKeyLeak_RevertWrongReporter() public {
        _stakeNodeWithLeakedKey(node1);

        // Call from user1 instead of KL_REPORTER — proof was generated for 0xDEAD
        vm.prank(user1);
        vm.expectRevert();
        market.reportKeyLeak(node1, KL_PROOF);
    }
}
