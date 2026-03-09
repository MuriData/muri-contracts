// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketChallenge} from "./MarketChallenge.sol";

/// @notice Read-focused APIs and dashboard view aggregations.
abstract contract MarketViews is MarketChallenge {
    /// @notice Get node earnings info
    function getNodeEarningsInfo(address _node)
        external
        view
        returns (uint256 totalEarned, uint256 withdrawn, uint256 claimable, uint256 lastClaimPeriod)
    {
        totalEarned = nodeEarnings[_node];
        withdrawn = nodeWithdrawn[_node];
        claimable = _getClaimableRewards(_node);
        lastClaimPeriod = nodeLastClaimPeriod[_node];
    }

    /// @notice Get info for a single challenge slot
    function getSlotInfo(uint256 _slotIndex)
        external
        view
        returns (uint256 orderId, address challengedNode, uint256 randomness, uint256 deadlineBlock, bool isExpired)
    {
        require(_slotIndex < numChallengeSlots, "invalid slot index");
        ChallengeSlot storage slot = challengeSlots[_slotIndex];
        orderId = slot.orderId;
        challengedNode = slot.challengedNode;
        randomness = slot.randomness;
        deadlineBlock = slot.deadlineBlock;
        isExpired = slot.orderId != 0 && block.number > slot.deadlineBlock;
    }

    /// @notice Get info for all challenge slots
    function getAllSlotInfo()
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory challengedNodes,
            uint256[] memory randomnesses,
            uint256[] memory deadlineBlocks,
            bool[] memory isExpired
        )
    {
        uint256 slotCount = numChallengeSlots;
        orderIds = new uint256[](slotCount);
        challengedNodes = new address[](slotCount);
        randomnesses = new uint256[](slotCount);
        deadlineBlocks = new uint256[](slotCount);
        isExpired = new bool[](slotCount);
        for (uint256 i = 0; i < slotCount; i++) {
            ChallengeSlot storage slot = challengeSlots[i];
            orderIds[i] = slot.orderId;
            challengedNodes[i] = slot.challengedNode;
            randomnesses[i] = slot.randomness;
            deadlineBlocks[i] = slot.deadlineBlock;
            isExpired[i] = slot.orderId != 0 && block.number > slot.deadlineBlock;
        }
    }

    /// @notice Get the number of active challenge obligations for a node
    function getNodeChallengeStatus(address _node) external view returns (uint256 activeChallenges) {
        return nodeActiveChallengeCount[_node];
    }

    /// @notice Get order escrow info
    function getOrderEscrowInfo(uint256 _orderId)
        external
        view
        returns (uint256 totalEscrow, uint256 paidToNodes, uint256 remainingEscrow)
    {
        FileOrder storage order = orders[_orderId];
        totalEscrow = order.escrow;
        paidToNodes = orderEscrowWithdrawn[_orderId];
        remainingEscrow = totalEscrow > paidToNodes ? totalEscrow - paidToNodes : 0;
    }

    /// @notice Get node's earnings from a specific order (computed on-the-fly from assignment and watermark)
    function getNodeOrderEarnings(address _node, uint256 _orderId) external view returns (uint256) {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return 0;

        (uint32 nodeStartPeriod, bool found) = _getNodeStartPeriod(_orderId, _node);
        if (!found) return 0;

        uint256 endPeriod = uint256(order.startPeriod) + uint256(order.periods);
        uint256 currentPer = currentPeriod();
        uint256 toPeriod = currentPer > endPeriod ? endPeriod : currentPer;
        if (toPeriod <= uint256(nodeStartPeriod)) return 0;

        return uint256(order.numChunks) * _orderPrice(order) * (toPeriod - uint256(nodeStartPeriod));
    }

    /// @notice Get the per-chunk-per-period price for an order (derived from escrow)
    function getOrderPrice(uint256 _orderId) external view returns (uint256) {
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        return _orderPrice(order);
    }
}
