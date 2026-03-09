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
        uint256 endPeriod = uint256(order.startPeriod) + uint256(order.periods);
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

    /// @notice Derive price per chunk per period from the order's escrow.
    /// Always exact division since placeOrder enforces escrow = numChunks * periods * price * replicas.
    function _orderPrice(FileOrder storage order) internal view returns (uint256) {
        return order.escrow / (uint256(order.numChunks) * uint256(order.periods) * uint256(order.replicas));
    }

    /// @notice Find the start period for a node's assignment to an order.
    function _getNodeStartPeriod(uint256 _orderId, address _node)
        internal
        view
        returns (uint32 startPeriod, bool found)
    {
        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        for (uint256 i = 0; i < assignments.length; i++) {
            if (assignments[i].node == _node) {
                return (assignments[i].startPeriod, true);
            }
        }
        return (0, false);
    }

    /// @notice Find a node's index in the assignment array.
    function _getNodeAssignmentIndex(uint256 _orderId, address _node)
        internal
        view
        returns (uint256 index, bool found)
    {
        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        for (uint256 i = 0; i < assignments.length; i++) {
            if (assignments[i].node == _node) {
                return (i, true);
            }
        }
        return (0, false);
    }

    /// @notice Calculate claimable earnings for a node/order pair up to a target period.
    /// Uses nodeLastClaimPeriod as the settlement watermark to avoid per-(order,node) earnings tracking.
    function _calculateOrderClaimableUpTo(address _node, uint256 _orderId, uint256 _settlePeriod)
        internal
        view
        returns (uint256)
    {
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) return 0;

        (uint32 nodeStartPeriod, bool found) = _getNodeStartPeriod(_orderId, _node);
        if (!found) return 0;

        uint256 lastClaim = nodeLastClaimPeriod[_node];
        uint256 fromPeriod = uint256(nodeStartPeriod) > lastClaim ? uint256(nodeStartPeriod) : lastClaim;

        uint256 orderEndPeriod = uint256(order.startPeriod) + uint256(order.periods);
        uint256 toPeriod = _settlePeriod > orderEndPeriod ? orderEndPeriod : _settlePeriod;
        if (toPeriod <= fromPeriod) return 0;

        uint256 earnablePeriods = toPeriod - fromPeriod;
        uint256 earnings = uint256(order.numChunks) * _orderPrice(order) * earnablePeriods;

        uint256 availableEscrow = order.escrow - orderEscrowWithdrawn[_orderId];
        return earnings > availableEscrow ? availableEscrow : earnings;
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
        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        uint256 settlePeriod = currentPeriod();

        uint256 settledReward = _settleOrderReward(_node, _orderId, settlePeriod);
        if (settledReward > 0) {
            nodePendingRewards[_node] += settledReward;
        }

        // Remove node from order assignments (swap-and-pop)
        if (_nodeIndex != assignments.length - 1) {
            assignments[_nodeIndex] = assignments[assignments.length - 1];
        }
        assignments.pop();
        order.filled--;

        // Last node removed — order no longer challengeable
        if (assignments.length == 0 && isChallengeable[_orderId]) {
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
        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        initialAssignments = assignments.length;
        while (assignments.length > 0) {
            address node = assignments[assignments.length - 1].node;
            uint256 settledReward = _settleOrderReward(node, _orderId, _settlePeriod);
            if (settledReward > 0) {
                nodePendingRewards[node] += settledReward;
                totalSettled += settledReward;
            }

            (, uint64 capacity, uint64 used,) = nodeStaking.getNodeInfo(node);
            if (capacity > 0) {
                nodeStaking.updateNodeUsed(node, used - order.numChunks);
            }

            assignments.pop();
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
            (bool burned,) = payable(address(0)).call{value: burnAmount}("");
            require(burned, "burn failed");
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

        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        for (uint256 j = 0; j < assignments.length; j++) {
            if (assignments[j].node == _node) {
                uint256 settledReward = _settleOrderReward(_node, _orderId, _settlePeriod);
                if (settledReward > 0) {
                    nodePendingRewards[_node] += settledReward;
                }

                if (j != assignments.length - 1) {
                    assignments[j] = assignments[assignments.length - 1];
                }
                assignments.pop();
                order.filled--;

                if (assignments.length == 0 && isChallengeable[_orderId]) {
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
