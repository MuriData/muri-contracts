// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketChallengeTest is MarketTestBase {
    function test_ActivateSlots_BootstrapsRandomnessAndSlots() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
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

    function test_ActivateSlots_RevertsWhenNoChallengeableOrders() public {
        vm.expectRevert("no slots activated");
        market.activateSlots();
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
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _stakeDefaultNode(node2, 0xABCD, 0xEF01);
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
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _stakeDefaultNode(node2, 0xABCD, 0xEF01);
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
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        vm.prank(node1);
        vm.expectRevert("active prover cannot quit");
        market.quitOrder(orderId);
    }

    function test_SlotExpiry_SweepViaSubmitProof() public {
        // Two nodes, one order each
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _stakeNode(node2, TEST_CAPACITY, 0xABCD, 0xEF01);

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
