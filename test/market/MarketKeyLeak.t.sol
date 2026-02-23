// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketKeyLeakTest is MarketTestBase {
    // Deterministic fixture values from `go run ./cmd/export keyleak` (sk=12345, reporter=0xDEAD)
    uint256 constant KL_PUB_KEY = 0x259115f2259ea0923f1e3a18a4122a606d88ea1c25f49f8766df1aba7864efd1;
    address constant KL_REPORTER = address(0xDEAD);

    bytes constant KL_PROOF =
        hex"1cdaaeacd7cb7adc2cf7d11407946bb7e87ba738c66e8bdcdef7ff60cdab9750127c120e1887f97b948be27c879ee0e1925a491f840de93d4166c10c754744dc0637647fa50cff59fd5eafad4c53ff5a0d50ee1520daabb5a5ba80987fdae72a21d5e873ea17f63d36802824164d908be94bcce9d61568f04dd294c6fb4d31ec01e8cd1584953fa229fc7c8ce3ca781edfc04d340dd8723dc79d5dd8dfdc71910c73f1ae373fdb3bc4618f1c7bd91cd523abc2279803acfc037d0bd1037ef3e91fab59a5959f80bbce53ba3235927fe893d77bd3763f5975f38b81927e4de0431cc5418a4768bcde9eda10c375ec7c8f19bb657d666c7668e94c7ef3e661f3110bf125e7c68f02e3e7de7cd531feded8bbf9b8d0a0ab213f39b08fccf03f485b21897b1fe6b243eebca332428e3a7adac41049bdc00f5f89fa9ee7b8219574be2ae15e0f835baa903c2f32c13d405fd551a3d6838b0b746b6ca82f23c170da412ce8efddda433d6f29654dd23d140a1bf227bbf2c8fe32367e62d4fd2395f5620358b5328ece81d5cbd2a7e1138126598aed9f6fda8d9d73c70887a9c45457de1ee31d74666e7fe7a18f3808c6f27b0d8fcdcdc259263e684309c746d888e5ee168e9d257718c16b6c50da875938a9ef9056859a482c8372f02e4df318551d4b0ee718bd24f9ded532fddf888b09fa7775eddb2964f73cc0414c3aec0cb2abb12a257077b2f5fc287801ef81347b0313b53e416abd3850874b8b0c5333774a430a1846ae0331f822785f9b6d6a7a88414eed35b0a80665ba6ea5375124a48b12029239a0ae18d3f5dd6d5135d94cd2db9fe8bbe8af2e98492ffdc610a983dc1e0e77abdeca71e011f49634ed44f350401eda3f37d9f57d5b0c4318806b5d39d50c72b8a542d6b652ea2c2855e3a987a5f81f6291a46585b9ec359b98bcc8ef4727d520c8d5a9fa9c1f54e5f3e0cf5552421a2182ffdde8294572457f9a559a27066277c06c566e54d723fd2ee91b86b413809c406a8434b85048f9eefa9bd77c195b672e856d59475ca8a62cc57f15477374492e187e0e6f41420fb3ce4c233c";

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
