// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketTestBase} from "./MarketBase.t.sol";

contract MarketViewsTest is MarketTestBase {
    function test_GetGlobalStats_ReflectsOrderAndNodeState() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        _placeDefaultOrder(user1, 1);

        (
            uint256 totalOrders,
            uint256 activeOrdersCount,
            uint256 totalEscrowLocked,
            uint256 totalNodes,
            uint256 totalCapacityStaked,
            uint256 totalCapacityUsed,
            uint256 currentRandomnessValue,
            uint256 lastHeartbeatStep,
            uint256 currentPeriod_,
            uint256 currentStep_,
            uint256 challengeableOrdersCount
        ) = market.getGlobalStats();

        assertEq(totalOrders, 1);
        assertEq(activeOrdersCount, 1);
        assertGt(totalEscrowLocked, 0);
        assertEq(totalNodes, 1);
        assertEq(totalCapacityStaked, TEST_CAPACITY);
        assertEq(totalCapacityUsed, 0);
        assertEq(challengeableOrdersCount, 0);
        assertEq(lastHeartbeatStep, 0);
        assertEq(currentPeriod_, market.currentPeriod());
        assertEq(currentStep_, market.currentStep());
        assertEq(currentRandomnessValue, 0);
    }

    function test_GetRecentOrders_Empty() public view {
        (
            uint256[] memory ids,
            address[] memory owners,
            uint64[] memory sizes,
            uint16[] memory periods,
            uint8[] memory replicas,
            uint8[] memory filled,
            uint256[] memory escrows,
            bool[] memory isActive
        ) = market.getRecentOrders(5);

        assertEq(ids.length, 0);
        assertEq(owners.length, 0);
        assertEq(sizes.length, 0);
        assertEq(periods.length, 0);
        assertEq(replicas.length, 0);
        assertEq(filled.length, 0);
        assertEq(escrows.length, 0);
        assertEq(isActive.length, 0);
    }

    function test_GetRecentOrders_ReturnsMostRecentFirst() public {
        _placeDefaultOrder(user1, 1);
        _placeDefaultOrder(user1, 1);
        _placeDefaultOrder(user1, 1);

        (uint256[] memory ids,,,,,,,) = market.getRecentOrders(2);

        assertEq(ids.length, 2);
        assertEq(ids[0], 3);
        assertEq(ids[1], 2);
    }

    function test_GetOrderDetails_RevertInvalidId() public {
        vm.expectRevert("invalid order id");
        market.getOrderDetails(0);
    }

    function test_GetOrderDetails_ReturnsPlacedValues() public {
        (uint256 orderId,) = _placeOrder(user1, 512, 3, 2, 1e12);

        (address owner_, string memory uri_, uint256 root_, uint64 size_, uint16 periods_, uint8 replicas_, uint8 filled_)
        = market.getOrderDetails(orderId);

        assertEq(owner_, user1);
        assertEq(uri_, FILE_URI);
        assertEq(root_, FILE_ROOT);
        assertEq(size_, 512);
        assertEq(periods_, 3);
        assertEq(replicas_, 2);
        assertEq(filled_, 0);
    }

    function test_GetOrderFinancials_ReturnsAssignedNodes() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        (, uint256 withdrawn, uint64 startPeriod, bool expired, address[] memory nodes) = market.getOrderFinancials(orderId);

        assertEq(withdrawn, 0);
        assertEq(startPeriod, market.currentPeriod());
        assertFalse(expired);
        assertEq(nodes.length, 1);
        assertEq(nodes[0], node1);
    }

    function test_GetFinancialStats_UpdatesAfterRewardClaim() public {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (uint256 orderId, uint256 totalCost) = _placeOrder(user1, 256, 1, 1, 1e12);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(node1);
        market.claimRewards();

        (, uint256 totalEscrowHeld, uint256 totalRewardsPaid, uint256 averageOrderValue,) = market.getFinancialStats();

        assertEq(totalRewardsPaid, totalCost);
        assertEq(totalEscrowHeld, 0);
        assertEq(averageOrderValue, totalCost);
    }

    function test_GetProofSystemStats_ChallengeActiveFlag() public {
        _bootstrapSingleOrderChallenge();

        (, uint256 currentStepValue, uint256 lastStep, bool challengeActive, address primary,,,) = market.getProofSystemStats();

        assertTrue(primary != address(0));
        assertTrue(challengeActive);
        assertTrue(currentStepValue <= lastStep + 1);
    }
}
