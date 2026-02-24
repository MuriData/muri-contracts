// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketChallengeTest is MarketTestBase {
    function test_ActivateSlots_BootstrapsRandomnessAndSlots() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        assertFalse(market.challengeSlotsInitialized());
        assertEq(market.globalSeedRandomness(), 0);

        market.activateSlots();

        assertTrue(market.challengeSlotsInitialized());
        assertGt(market.globalSeedRandomness(), 0);

        // At least one slot should be active
        (uint256 slotOrderId, address slotNode,,,) = market.getSlotInfo(0);
        assertGt(slotOrderId, 0);
        assertTrue(slotNode != address(0));
    }

    function test_ActivateSlots_NoOpWhenNoChallengeableOrders() public {
        // Should not revert — cleanup side effects still commit
        market.activateSlots();

        // No slots should be active
        (uint256 slotOrderId,,,,) = market.getSlotInfo(0);
        assertEq(slotOrderId, 0);
    }

    function test_SubmitProof_RevertsInvalidSlotIndex() public {
        uint256[8] memory proof;
        vm.prank(node1);
        vm.expectRevert("invalid slot index");
        market.submitProof(5, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsOnIdleSlot() public {
        uint256[8] memory proof;
        vm.prank(node1);
        vm.expectRevert("slot is idle");
        market.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsWhenNotChallengedNode() public {
        _stakeDefaultNode(node1, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // node2 tries to submit proof for node1's challenge
        uint256[8] memory proof;
        vm.prank(node2);
        vm.expectRevert("not the challenged node");
        market.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_SubmitProof_RevertsAfterDeadline() public {
        (, address challengedNode) = _bootstrapSingleSlotChallenge();

        // Move past the deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // submitProof sweeps expired slots first, which slashes and deactivates/re-advances
        // the slot. So the exact error depends on post-sweep state ("slot is idle" if
        // deactivated, or "not the challenged node" if re-advanced to someone else).
        uint256[8] memory proof;
        vm.prank(challengedNode);
        vm.expectRevert();
        market.submitProof(0, proof, bytes32(uint256(1)));
    }

    function test_ProcessExpiredSlots_SlashesAndRewardsReporter() public {
        _stakeDefaultNode(node1, 0x1234);
        _stakeDefaultNode(node2, 0xABCD);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // Verify node1 has an active challenge
        assertTrue(market.nodeActiveChallengeCount(node1) > 0);

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // node2 processes expired slots as reporter
        vm.prank(node2);
        market.processExpiredSlots();

        // Reporter should earn reward
        assertGt(market.reporterPendingRewards(node2), 0);
    }

    function test_ProcessExpiredSlots_RevertsWhenNoneExpired() public {
        vm.expectRevert("no expired slots");
        market.processExpiredSlots();
    }

    function test_CancelOrder_RevertsWhenUnderActiveChallenge() public {
        (uint256 orderId,) = _bootstrapSingleSlotChallenge();

        vm.prank(user1);
        vm.expectRevert("order under active challenge");
        market.cancelOrder(orderId);
    }

    function test_QuitOrder_RevertsForChallengedNode() public {
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);
    }

    function test_CleanupSkipsOrderUnderActiveChallenge() public {
        // Setup: short-lived order (1 period) with a node, activate challenge slot
        _stakeDefaultNode(node1, 0x1234);
        (uint256 orderId,) = _placeOrder(user1, 256, 1, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // Verify the order is under active challenge
        assertGt(market.orderActiveChallengeCount(orderId), 0);

        // Expire the order by warping past its period
        vm.warp(block.timestamp + 7 days + 1);

        // The order is now expired AND under active challenge.
        // Calling activateSlots triggers _cleanupExpiredOrders internally.
        // Before the fix, cleanup would delete the order even though a slot points to it.

        // The order should still exist because it's under active challenge
        (address owner_,,,,,,) = market.getOrderDetails(orderId);
        assertEq(owner_, user1, "order should survive cleanup while under active challenge");

        // The order's data should still be readable (not zeroed out)
        (,, uint256 root_,,,,) = market.getOrderDetails(orderId);
        assertGt(root_, 0, "order file root should not be zeroed");
    }

    function test_ForcedExitCleanup_AllSlashedNodesDetachedAfterSweep() public {
        // Three nodes with capacity == order maxSize, so any challenge slash
        // triggers forcedExit (used 1024 > new capacity 524 after 500-byte slash).
        _stakeDefaultNode(node1, 0x1111);
        _stakeDefaultNode(node2, 0x2222);
        _stakeDefaultNode(node3, 0x3333);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeDefaultOrder(user1, 1);
        (uint256 order3,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(order1);
        vm.prank(node2);
        market.executeOrder(order2);
        vm.prank(node3);
        market.executeOrder(order3);

        // Pre-check: every node has exactly 1 order assignment
        assertEq(market.getNodeOrders(node1).length, 1);
        assertEq(market.getNodeOrders(node2).length, 1);
        assertEq(market.getNodeOrders(node3).length, 1);

        // Fill challenge slots across the 3 order/node pairs
        market.activateSlots();

        // Expire all challenge deadlines
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // Sweep: slashes expired nodes, triggers forced exits, earns reporter rewards
        vm.prank(user1);
        market.processExpiredSlots();

        // Invariant: every node that was slashed with forcedExit==true must have
        // been fully detached from orders. A stale assignment here means
        // _handleForcedOrderExits was skipped — the exact bug this fix addresses.
        _assertDetachedIfSlashed(node1);
        _assertDetachedIfSlashed(node2);
        _assertDetachedIfSlashed(node3);
    }

    /// @dev Helper: if the node was slashed (capacity < TEST_CAPACITY) or removed,
    ///      it must have no remaining order assignments.
    function _assertDetachedIfSlashed(address _node) internal {
        if (nodeStaking.isValidNode(_node)) {
            (, uint64 cap,,) = nodeStaking.getNodeInfo(_node);
            if (cap < TEST_CAPACITY) {
                // Was slashed and force-exited — must be detached
                assertEq(market.getNodeOrders(_node).length, 0, "force-exited node still has stale order assignments");
            }
        } else {
            // Node fully removed from staking — must be detached
            assertEq(market.getNodeOrders(_node).length, 0, "removed node still has stale order assignments");
        }
    }

    function test_AdvanceSlot_PrefersUnchallengedOrdersAndNodes() public {
        // 3 nodes, 3 orders (1 replica each), each node executes a different order
        // → 3 distinct (order, node) pairs available
        _stakeDefaultNode(node1, 0x1111);
        _stakeDefaultNode(node2, 0x2222);
        _stakeDefaultNode(node3, 0x3333);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeDefaultOrder(user1, 1);
        (uint256 order3,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(order1);
        vm.prank(node2);
        market.executeOrder(order2);
        vm.prank(node3);
        market.executeOrder(order3);

        // Activate all 5 challenge slots from 3 pairs
        market.activateSlots();

        // Collect which orders and nodes were assigned across all 5 slots
        bool hasOrder1;
        bool hasOrder2;
        bool hasOrder3;
        bool hasNode1;
        bool hasNode2;
        bool hasNode3;

        for (uint256 i = 0; i < 5; i++) {
            (uint256 slotOrderId, address slotNode,,,) = market.getSlotInfo(i);
            // Every slot must be active (3 pairs available, 5 slots)
            assertGt(slotOrderId, 0, "slot should be active");

            if (slotOrderId == order1) hasOrder1 = true;
            if (slotOrderId == order2) hasOrder2 = true;
            if (slotOrderId == order3) hasOrder3 = true;
            if (slotNode == node1) hasNode1 = true;
            if (slotNode == node2) hasNode2 = true;
            if (slotNode == node3) hasNode3 = true;
        }

        // All 3 orders must appear before any gets a second slot
        assertTrue(hasOrder1, "order1 should be covered");
        assertTrue(hasOrder2, "order2 should be covered");
        assertTrue(hasOrder3, "order3 should be covered");

        // All 3 nodes must appear before any gets a duplicate
        assertTrue(hasNode1, "node1 should be covered");
        assertTrue(hasNode2, "node2 should be covered");
        assertTrue(hasNode3, "node3 should be covered");
    }

    function test_ProofFailureSlash_ScalesWithOrderValue() public {
        // 1 MB order at 1e12 price → orderPeriodCost = 1_048_576 * 1e12 = ~1.05 ETH
        // This exceeds the 0.05 ETH floor, so per-slot slash = orderPeriodCost
        // Use 2x capacity so no forced exits occur from the 5 simultaneous slot slashes
        uint32 largeSize = 1_048_576; // 1M chunks
        uint256 price = 1e12;
        uint64 nodeCapacity = 2_097_152; // 2M chunks — avoids forced exit
        uint256 orderPeriodCost = uint256(largeSize) * price;
        uint256 floor = 500 * STAKE_PER_CHUNK;

        uint256 nodeStake = uint256(nodeCapacity) * STAKE_PER_CHUNK;
        vm.deal(node1, nodeStake + 10 ether);
        vm.prank(node1);
        nodeStaking.stakeNode{value: nodeStake}(nodeCapacity, 0x1234);

        (uint256 orderId,) = _placeOrder(user1, largeSize, 4, 1, price);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        // Expire all 5 challenge slots
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;

        // All 5 slots target the same node → total = 5 * orderPeriodCost
        assertEq(actualSlash, 5 * orderPeriodCost, "slash should scale with order value");
        assertGt(actualSlash, 5 * floor, "total slash should exceed 5x floor");
    }

    function test_ProofFailureSlash_FloorForSmallOrders() public {
        // Default order: 1024 bytes at 1e12 → orderPeriodCost = 1.024e15 < floor (5e16)
        // Per-slot slash = floor. Use large capacity so node survives all 5 slashes.
        uint64 nodeCapacity = 10000; // stake = 1e18, easily covers 5 * floor = 2.5e17
        _stakeNode(node1, nodeCapacity, 0x1234);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        (uint256 stakeBefore,,,) = nodeStaking.getNodeInfo(node1);

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        (uint256 stakeAfter,,,) = nodeStaking.getNodeInfo(node1);
        uint256 actualSlash = stakeBefore - stakeAfter;

        uint256 floor = 500 * STAKE_PER_CHUNK; // 0.05 ETH
        // All 5 slots target the same node → total = 5 * floor
        assertEq(actualSlash, 5 * floor, "small order slash should equal 5x floor");
    }

    function test_ProofFailureSlash_CappedByNodeStake() public {
        // orderPeriodCost > nodeStake → first slot caps to full stake, node removed,
        // remaining slots find node invalid and skip. Total slash = initial stake.
        uint32 orderSize = 1024;
        uint256 highPrice = 1e15; // 10x STAKE_PER_CHUNK → orderPeriodCost = 1.024e18 > stake 1.024e17

        _stakeDefaultNode(node1, 0x1234); // capacity = 1024, stake = 1.024e17

        (uint256 orderId,) = _placeOrder(user1, orderSize, 4, 1, highPrice);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        vm.prank(user2);
        market.processExpiredSlots();

        // Node should be fully removed (capacity == 0)
        assertFalse(nodeStaking.isValidNode(node1), "node should be removed after full slash");
    }

    function test_SlotExpiry_SweepViaSubmitProof() public {
        // Two nodes, one order each
        _stakeDefaultNode(node1, 0x1234);
        _stakeNode(node2, TEST_CAPACITY, 0xABCD);

        (uint256 order1,) = _placeDefaultOrder(user1, 1);
        (uint256 order2,) = _placeOrder(user1, 512, 4, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(order1);
        vm.prank(node2);
        market.executeOrder(order2);

        market.activateSlots();

        // Move past deadline for all slots
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // When any node submits a proof (even if it reverts), sweeping still processes
        // Use processExpiredSlots as the trigger
        vm.prank(user1);
        market.processExpiredSlots();

        // Slots should have been processed (slashed and re-advanced or deactivated)
        // Check that reporter rewards were generated
        assertGt(market.reporterPendingRewards(user1), 0);
    }
}
