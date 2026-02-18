// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketCoreTest is MarketTestBase {
    function test_BasicMarketDeployment() public view {
        assertEq(address(market.nodeStaking()), address(nodeStaking));
        assertEq(market.nextOrderId(), 1);
        assertEq(market.getActiveOrdersCount(), 0);
        assertEq(market.getChallengeableOrdersCount(), 0);
    }

    function test_NodeRegistration() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);

        (uint256 stake, uint64 capacity, uint64 used, uint256 pubX, uint256 pubY) = nodeStaking.getNodeInfo(node1);
        assertEq(stake, uint256(TEST_CAPACITY) * STAKE_PER_BYTE);
        assertEq(capacity, TEST_CAPACITY);
        assertEq(used, 0);
        assertEq(pubX, 0x1234);
        assertEq(pubY, 0x5678);
        assertTrue(nodeStaking.isValidNode(node1));
    }

    function test_PlaceOrder_TracksEscrowAndActiveOrder() public {
        (uint256 orderId, uint256 totalCost) = _placeDefaultOrder(user1, 1);

        assertEq(orderId, 1);
        assertEq(market.nextOrderId(), 2);
        assertEq(market.getActiveOrdersCount(), 1);

        (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow) = market.getOrderEscrowInfo(orderId);
        assertEq(totalEscrow, totalCost);
        assertEq(paidToNodes, 0);
        assertEq(remainingEscrow, totalCost);
        assertFalse(market.isOrderExpired(orderId));
    }

    function test_ExecuteOrder_AssignsNodeAndConsumesCapacity() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 1024);

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 1);
        assertEq(orderNodes[0], node1);

        uint256[] memory nodeOrders = market.getNodeOrders(node1);
        assertEq(nodeOrders.length, 1);
        assertEq(nodeOrders[0], orderId);

        assertEq(market.getChallengeableOrdersCount(), 1);
    }

    function test_RevertWhen_ExecuteOrder_NotValidNode() public {
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(user2);
        vm.expectRevert("not a valid node");
        market.executeOrder(orderId);
    }

    function test_RevertWhen_ExecuteOrder_DuplicateAssignment() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeOrder(user1, 256, 4, 2, 1e12);

        vm.startPrank(node1);
        market.executeOrder(orderId);
        vm.expectRevert("already assigned to this order");
        market.executeOrder(orderId);
        vm.stopPrank();
    }

    function test_CancelOrder_QueuesAndPaysRefund() public {
        (uint256 orderId, uint256 totalCost) = _placeDefaultOrder(user1, 1);

        vm.prank(user1);
        market.cancelOrder(orderId);

        assertEq(market.pendingRefunds(user1), totalCost);
        assertEq(market.getActiveOrdersCount(), 0);

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        market.withdrawRefund();
        assertEq(user1.balance - balanceBefore, totalCost);
    }

    function test_CompleteExpiredOrder_ReleasesCapacityAndQueuesRefund() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, 1024, 1, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(address(0xBEEF));
        market.completeExpiredOrder(orderId);

        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 0);

        assertEq(market.getActiveOrdersCount(), 0);
        assertEq(market.pendingRefunds(user1), 0);

        uint256 nodeReward = uint256(1024) * 1e12;
        assertEq(market.nodePendingRewards(node1), nodeReward);
        assertEq(market.nodePendingRewards(node1), totalCost);
    }

    function test_QuitOrder_RemovesNodeAndEmitsUnderReplicated() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.expectEmit(true, false, false, true);
        emit OrderUnderReplicated(orderId, 0, 1);

        vm.prank(node1);
        market.quitOrder(orderId);

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 0);

        (,, uint64 used,,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, 0);
    }

    function test_SlashNode_RevertUnauthorized() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);

        vm.prank(user1);
        vm.expectRevert("not authorized");
        market.slashNode(node1, 1, "unauthorized");
    }

    function test_SlashAuthority_ForcedExit_RemovesNodeFromOrder() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.setSlashAuthority(user2, true);

        vm.prank(user2);
        market.slashNode(node1, nodeStaking.STAKE_PER_BYTE(), "challenge failure");

        address[] memory orderNodes = market.getOrderNodes(orderId);
        assertEq(orderNodes.length, 0);
    }
}
