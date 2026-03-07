// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketAdmin} from "./MarketAdmin.sol";

/// @notice Shared internal helpers used by both MarketOrders (main) and MarketChallenge (extension).
/// Both inheritance branches include this contract, so each gets its own compiled copy of these
/// internal functions — no cross-contract calls needed.
abstract contract MarketHelpers is MarketAdmin {
    // Check if an order is expired (periods have passed)
    function isOrderExpired(uint256 _orderId) public view returns (bool) {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return true; // non-existent order
        uint256 endPeriod = order.startPeriod + order.periods;
        return currentPeriod() >= endPeriod;
    }

    /// @notice Check if a node has an unresolved proof obligation (used by NodeStaking to block withdrawals)
    function hasUnresolvedProofObligation(address _node) external view returns (bool) {
        return _isUnresolvedProver(_node);
    }

    /// @notice O(1) check: node has active challenge slot(s)
    function _isUnresolvedProver(address _node) internal view returns (bool) {
        return nodeActiveChallengeCount[_node] > 0;
    }

    /// @notice O(1) check: order is currently under active challenge
    function _isOrderUnderActiveChallenge(uint256 _orderId) internal view returns (bool) {
        return orderActiveChallengeCount[_orderId] > 0;
    }

    /// @notice Calculate claimable earnings for a node/order pair up to a target period
    function _calculateOrderClaimableUpTo(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        view
        returns (uint256)
    {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return 0;

        uint256 startTs = nodeOrderStartTimestamp[_node][_orderId];
        uint256 elapsed = startTs - genesisTs;
        uint256 nodeStartPeriod = (elapsed + PERIOD - 1) / PERIOD;

        uint256 orderEndPeriod = order.startPeriod + order.periods;
        uint256 storageEndPeriod = _settlePeriod > orderEndPeriod ? orderEndPeriod : _settlePeriod;
        if (storageEndPeriod <= nodeStartPeriod) return 0;

        uint256 storagePeriods = storageEndPeriod - nodeStartPeriod;
        uint256 totalEarnable = uint256(order.numChunks) * order.price * storagePeriods;
        uint256 alreadyEarned = nodeOrderEarnings[_orderId][_node];
        if (totalEarnable <= alreadyEarned) return 0;

        uint256 newEarnings = totalEarnable - alreadyEarned;
        uint256 availableEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        return newEarnings > availableEscrow ? availableEscrow : newEarnings;
    }

    /// @notice Internal view to check claimable rewards (avoids external self-call in MarketViews)
    function _getClaimableRewards(address _node) internal view returns (uint256 claimable) {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256 currentPer = currentPeriod();

        for (uint256 i = 0; i < nodeOrders.length; i++) {
            claimable += _calculateOrderClaimableUpTo(_node, nodeOrders[i], currentPer);
        }

        claimable += nodePendingRewards[_node];
    }

    /// @notice View function to check claimable rewards from order escrows
    function getClaimableRewards(address _node) external view returns (uint256 claimable) {
        return _getClaimableRewards(_node);
    }

    /// @notice Apply reward settlement for a node/order pair and return the credited amount
    function _settleOrderReward(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint256 claimableFromOrder)
    {
        claimableFromOrder = _calculateOrderClaimableUpTo(_node, _orderId, _settlePeriod);
        if (claimableFromOrder == 0) {
            return 0;
        }

        nodeOrderEarnings[_orderId][_node] += claimableFromOrder;
        orderEscrowWithdrawn[_orderId] += claimableFromOrder;
        aggregateActiveWithdrawn += claimableFromOrder;
        lifetimeRewardsPaid += claimableFromOrder;
        nodeEarnings[_node] += claimableFromOrder;
    }

    // Internal function to remove order from active orders array
    function _removeFromActiveOrders(uint256 _orderId) internal {
        uint256 index = orderIndexInActive[_orderId];
        uint256 lastIndex = activeOrders.length - 1;

        if (index != lastIndex) {
            uint256 lastOrderId = activeOrders[lastIndex];
            activeOrders[index] = lastOrderId;
            orderIndexInActive[lastOrderId] = index;
        }

        activeOrders.pop();
        delete orderIndexInActive[_orderId];

        // Also remove from challengeable orders if present
        if (isChallengeable[_orderId]) {
            _removeFromChallengeableOrders(_orderId);
        }
    }

    // Internal function to add order to challengeable orders (called when first node is assigned)
    function _addToChallengeableOrders(uint256 _orderId) internal {
        challengeableOrders.push(_orderId);
        orderIndexInChallengeable[_orderId] = challengeableOrders.length - 1;
        isChallengeable[_orderId] = true;
    }

    // Internal function to remove order from challengeable orders
    function _removeFromChallengeableOrders(uint256 _orderId) internal {
        uint256 index = orderIndexInChallengeable[_orderId];
        uint256 lastIndex = challengeableOrders.length - 1;

        if (index != lastIndex) {
            uint256 lastOrderId = challengeableOrders[lastIndex];
            challengeableOrders[index] = lastOrderId;
            orderIndexInChallengeable[lastOrderId] = index;
        }

        challengeableOrders.pop();
        delete orderIndexInChallengeable[_orderId];
        isChallengeable[_orderId] = false;
    }

    // Internal helper to remove order from node's order list
    function _removeOrderFromNode(address _node, uint256 _orderId) internal {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        for (uint256 i = 0; i < nodeOrders.length; i++) {
            if (nodeOrders[i] == _orderId) {
                if (i != nodeOrders.length - 1) {
                    nodeOrders[i] = nodeOrders[nodeOrders.length - 1];
                }
                nodeOrders.pop();
                break;
            }
        }
    }

    // Helper function to remove node from a single order
    function _removeNodeFromOrder(address _node, uint256 _orderId, uint256 _nodeIndex) internal {
        FileOrder storage order = orders[_orderId];
        address[] storage assignedNodes = orderToNodes[_orderId];
        uint256 settlePeriod = currentPeriod();

        uint256 settledReward = _settleOrderReward(_node, _orderId, settlePeriod);
        if (settledReward > 0) {
            nodePendingRewards[_node] += settledReward;
        }
        delete nodeOrderStartTimestamp[_node][_orderId];
        delete nodeOrderEarnings[_orderId][_node];

        // Remove node from order assignments
        if (_nodeIndex != assignedNodes.length - 1) {
            assignedNodes[_nodeIndex] = assignedNodes[assignedNodes.length - 1];
        }
        assignedNodes.pop();
        order.filled--;

        // Last node removed — order no longer challengeable
        if (assignedNodes.length == 0 && isChallengeable[_orderId]) {
            _removeFromChallengeableOrders(_orderId);
        }

        if (order.filled < order.replicas) {
            emit OrderUnderReplicated(_orderId, order.filled, order.replicas);
        }

        // Free up node capacity
        (,, uint64 used,) = nodeStaking.getNodeInfo(_node);
        nodeStaking.updateNodeUsed(_node, used - order.numChunks);

        // Remove order from node's order list
        _removeOrderFromNode(_node, _orderId);
    }

    function _settleAndReleaseNodes(FileOrder storage order, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint256 totalSettled, uint256 initialAssignments)
    {
        address[] storage assignedNodes = orderToNodes[_orderId];
        initialAssignments = assignedNodes.length;
        while (assignedNodes.length > 0) {
            address node = assignedNodes[assignedNodes.length - 1];
            uint256 settledReward = _settleOrderReward(node, _orderId, _settlePeriod);
            if (settledReward > 0) {
                nodePendingRewards[node] += settledReward;
                totalSettled += settledReward;
            }
            delete nodeOrderStartTimestamp[node][_orderId];
            delete nodeOrderEarnings[_orderId][node];

            (, uint64 capacity, uint64 used,) = nodeStaking.getNodeInfo(node);
            if (capacity > 0) {
                nodeStaking.updateNodeUsed(node, used - order.numChunks);
            }

            assignedNodes.pop();
            if (order.filled > 0) {
                order.filled--;
            }
            _removeOrderFromNode(node, _orderId);
        }
    }

    /// @notice Distribute slashed funds: reporter gets a percentage, client gets compensation, rest is burned
    function _distributeSlashFunds(address reporter, address slashedNode, uint256 totalSlashed, uint256 affectedOrderId)
        internal
    {
        if (totalSlashed == 0) return;

        totalSlashedReceived += totalSlashed;

        uint256 reporterReward = 0;
        if (reporter != address(0) && reporter != slashedNode) {
            reporterReward = totalSlashed * reporterRewardBps / 10000;
            if (reporterReward > 0) {
                reporterPendingRewards[reporter] += reporterReward;
                reporterEarnings[reporter] += reporterReward;
                totalReporterRewards += reporterReward;
                emit ReporterRewardAccrued(reporter, reporterReward, totalSlashed);
            }
        }

        uint256 clientComp = 0;
        if (affectedOrderId != 0) {
            address client = orders[affectedOrderId].owner;
            if (client != address(0) && clientCompensationBps > 0) {
                clientComp = totalSlashed * clientCompensationBps / 10000;
                if (clientComp > 0) {
                    pendingRefunds[client] += clientComp;
                    totalClientCompensation += clientComp;
                    emit ClientCompensationAccrued(client, clientComp, affectedOrderId);
                }
            }
        }

        uint256 burnAmount = totalSlashed - reporterReward - clientComp;
        totalBurnedFromSlash += burnAmount;
        if (burnAmount > 0) {
            payable(address(0)).transfer(burnAmount);
        }
    }

    /// @notice Distribute early-cancellation penalty to the nodes that were serving the order
    function _distributeCancellationPenalty(uint256 _orderId, uint256 _penalty, address[] memory _nodes) internal {
        uint256 count = _nodes.length;
        uint256 perNode = _penalty / count;
        uint256 distributed = 0;

        for (uint256 i = 0; i < count; i++) {
            uint256 share = (i == count - 1) ? _penalty - distributed : perNode;
            nodePendingRewards[_nodes[i]] += share;
            nodeEarnings[_nodes[i]] += share;
            distributed += share;
        }

        totalCancellationPenalties += _penalty;
        emit CancellationPenaltyDistributed(_orderId, _penalty, count);
    }

    // Internal function to handle forced order exits due to capacity reduction
    function _handleForcedOrderExits(address _node) internal {
        uint256[] storage nodeOrders = nodeToOrders[_node];
        uint256[] memory exitedOrders = new uint256[](nodeOrders.length);
        uint256 exitCount = 0;

        (, uint64 newCapacity, uint64 usedBefore,) = nodeStaking.getNodeInfo(_node);
        uint64 totalFreed = 0;
        uint256 settlePeriod = currentPeriod();

        uint256 i = nodeOrders.length;
        while (i > 0) {
            i--;
            uint256 exitOrderId = nodeOrders[i];
            uint64 freed = _removeAssignmentDuringForcedExit(_node, exitOrderId, settlePeriod);

            if (freed > 0) {
                totalFreed += freed;
                exitedOrders[exitCount++] = exitOrderId;
            }
        }

        delete nodeToOrders[_node];

        uint64 newUsed = usedBefore > totalFreed ? usedBefore - totalFreed : 0;
        if (newUsed > newCapacity) {
            newUsed = newCapacity;
        }

        if (newCapacity > 0 || nodeStaking.isValidNode(_node)) {
            nodeStaking.forceReduceUsed(_node, newUsed);
        }

        assembly {
            mstore(exitedOrders, exitCount)
        }

        emit ForcedOrderExits(_node, exitedOrders, totalFreed);
    }

    function _removeAssignmentDuringForcedExit(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        returns (uint64 freed)
    {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) {
            return 0;
        }

        address[] storage assignedNodes = orderToNodes[_orderId];
        for (uint256 j = 0; j < assignedNodes.length; j++) {
            if (assignedNodes[j] == _node) {
                uint256 settledReward = _settleOrderReward(_node, _orderId, _settlePeriod);
                if (settledReward > 0) {
                    nodePendingRewards[_node] += settledReward;
                }
                delete nodeOrderStartTimestamp[_node][_orderId];
                delete nodeOrderEarnings[_orderId][_node];

                if (j != assignedNodes.length - 1) {
                    assignedNodes[j] = assignedNodes[assignedNodes.length - 1];
                }
                assignedNodes.pop();
                order.filled--;

                if (assignedNodes.length == 0 && isChallengeable[_orderId]) {
                    _removeFromChallengeableOrders(_orderId);
                }

                if (order.filled < order.replicas) {
                    emit OrderUnderReplicated(_orderId, order.filled, order.replicas);
                }

                return order.numChunks;
            }
        }

        return 0;
    }
}
