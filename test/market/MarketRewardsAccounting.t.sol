// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase, BaseRevertingReceiver} from "./MarketBase.t.sol";

contract MarketRewardsAccountingTest is MarketTestBase {
    function test_ClaimRewards_AfterOnePeriod() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, 1024, 1, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);

        assertEq(market.getClaimableRewards(node1), totalCost);

        uint256 balanceBefore = node1.balance;
        vm.prank(node1);
        market.claimRewards();
        assertEq(node1.balance - balanceBefore, totalCost);
        assertEq(market.getClaimableRewards(node1), 0);
    }

    function test_RevertWhen_ClaimRewards_NoRewards() public {
        vm.prank(node1);
        vm.expectRevert("no rewards to claim");
        market.claimRewards();
    }

    function test_CancelOrder_WithEligibleNode_AppliesPenalty() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId, uint256 totalCost) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD);

        vm.prank(user1);
        market.cancelOrder(orderId);

        uint256 reward = uint256(1024) * 1e12;
        uint256 remainingEscrow = totalCost - reward;
        uint256 penalty = remainingEscrow / 10;
        uint256 refund = remainingEscrow - penalty;

        assertEq(market.nodePendingRewards(node1), reward + penalty);
        assertEq(market.pendingRefunds(user1), refund);
        assertEq(market.totalCancellationPenalties(), penalty);
    }

    function test_Overpayment_QueuesRefund() public {
        uint256 totalCost = uint256(512) * 2 * 1e12;

        vm.prank(user1);
        market.placeOrder{value: totalCost + 1 ether}(_fileMeta(), 512, 2, 1, 1e12);

        assertEq(market.pendingRefunds(user1), 1 ether);

        uint256 beforeBalance = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        assertEq(user1.balance - beforeBalance, 1 ether);
    }

    function test_WithdrawRefund_RevertWhenNone() public {
        vm.prank(user1);
        vm.expectRevert("no refund");
        market.withdrawRefund();
    }

    function test_SetReporterRewardBps_Success() public {
        market.setReporterRewardBps(2500);
        assertEq(market.reporterRewardBps(), 2500);
    }

    function test_SetReporterRewardBps_RevertNotOwner() public {
        vm.prank(user1);
        vm.expectRevert("not owner");
        market.setReporterRewardBps(1000);
    }

    function test_SetReporterRewardBps_RevertExceedsMax() public {
        vm.expectRevert("exceeds max bps");
        market.setReporterRewardBps(5001);
    }

    function test_ClaimReporterRewards_AfterSlotExpiry() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _stakeDefaultNode(node2, 0xABCD, 0xEF01);

        (uint256 orderId,) = _placeDefaultOrder(user1, 1);
        vm.prank(node1);
        market.executeOrder(orderId);

        // Activate challenge slots
        market.activateSlots();

        // Move past deadline
        vm.roll(block.number + CHALLENGE_WINDOW_BLOCKS + 1);

        // node2 processes expired slots as reporter
        vm.prank(node2);
        market.processExpiredSlots();

        uint256 pending = market.reporterPendingRewards(node2);
        assertGt(pending, 0);

        uint256 beforeBalance = node2.balance;
        vm.prank(node2);
        market.claimReporterRewards();
        assertEq(node2.balance - beforeBalance, pending);
        assertEq(market.reporterPendingRewards(node2), 0);
    }

    function test_ClaimReporterRewards_RevertWhenNone() public {
        vm.prank(user1);
        vm.expectRevert("no reporter rewards");
        market.claimReporterRewards();
    }

    function test_RefundQueue_DoSResistantAgainstRevertingReceiver() public {
        BaseRevertingReceiver receiver = new BaseRevertingReceiver(market);
        vm.deal(address(receiver), 10 ether);

        vm.prank(address(receiver));
        receiver.placeOrderWithOverpayment(256, 2, 1, 1e12, 1 ether);

        assertEq(market.pendingRefunds(address(receiver)), 1 ether);
    }
}
