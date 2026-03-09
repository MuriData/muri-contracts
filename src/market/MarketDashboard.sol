// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketHelpers} from "./MarketHelpers.sol";

/// @notice Heavy dashboard and order-detail view functions, split from MarketViews
/// to keep FileMarketExtension under the EIP-170 size limit.
/// Reached via chained fallback: FileMarket → Extension → Extension2.
abstract contract MarketDashboard is MarketHelpers {
    /// @notice Get comprehensive global marketplace statistics
    function getGlobalStats()
        external
        view
        returns (
            uint256 totalOrders,
            uint256 activeOrdersCount,
            uint256 totalEscrowLocked,
            uint256 totalNodes,
            uint256 totalCapacityStaked,
            uint256 totalCapacityUsed,
            uint256 activeChallengeSlots,
            uint256 currentPeriod_,
            uint256 currentBlock_,
            uint256 challengeableOrdersCount
        )
    {
        totalOrders = nextOrderId - 1;
        activeOrdersCount = activeOrders.length;
        challengeableOrdersCount = challengeableOrders.length;

        totalEscrowLocked = aggregateActiveEscrow - aggregateActiveWithdrawn;

        (totalNodes, totalCapacityStaked, totalCapacityUsed) = nodeStaking.getNetworkStats();

        // Count active slots
        for (uint256 i = 0; i < numChallengeSlots; i++) {
            if (challengeSlots[i].orderId != 0) {
                activeChallengeSlots++;
            }
        }

        currentPeriod_ = currentPeriod();
        currentBlock_ = block.number;
    }

    /// @notice Get recent order activity for dashboard
    function getRecentOrders(uint256 count)
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory owners,
            uint32[] memory numChunks,
            uint16[] memory periods,
            uint8[] memory replicas,
            uint8[] memory filled,
            uint256[] memory escrows,
            bool[] memory isActive
        )
    {
        uint256 totalOrders = nextOrderId - 1;
        uint256 returnCount = count > totalOrders ? totalOrders : count;
        if (returnCount == 0) {
            return (
                new uint256[](0),
                new address[](0),
                new uint32[](0),
                new uint16[](0),
                new uint8[](0),
                new uint8[](0),
                new uint256[](0),
                new bool[](0)
            );
        }

        orderIds = new uint256[](returnCount);
        owners = new address[](returnCount);
        numChunks = new uint32[](returnCount);
        periods = new uint16[](returnCount);
        replicas = new uint8[](returnCount);
        filled = new uint8[](returnCount);
        escrows = new uint256[](returnCount);
        isActive = new bool[](returnCount);

        uint256 currentPer = currentPeriod();

        for (uint256 idx = 0; idx < returnCount; idx++) {
            uint256 orderId = totalOrders - idx;
            FileOrder storage order = orders[orderId];

            orderIds[idx] = orderId;
            owners[idx] = order.owner;
            numChunks[idx] = order.numChunks;
            periods[idx] = order.periods;
            replicas[idx] = order.replicas;
            filled[idx] = order.filled;
            escrows[idx] = order.escrow;

            if (order.owner != address(0)) {
                uint256 endPeriod = uint256(order.startPeriod) + uint256(order.periods);
                isActive[idx] = currentPer < endPeriod;
            }
        }
    }

    /// @notice Get proof system health and challenge statistics
    function getProofSystemStats()
        external
        view
        returns (
            uint256 activeSlotsCount,
            uint256 idleSlotsCount,
            uint256 expiredSlotsCount,
            uint256 currentBlockNumber,
            uint256 challengeWindowBlocks,
            uint256 challengeableOrdersCount,
            uint256 totalSlotsCount
        )
    {
        currentBlockNumber = block.number;
        challengeWindowBlocks = CHALLENGE_WINDOW_BLOCKS;
        challengeableOrdersCount = challengeableOrders.length;
        totalSlotsCount = numChallengeSlots;

        for (uint256 i = 0; i < numChallengeSlots; i++) {
            if (challengeSlots[i].orderId == 0) {
                idleSlotsCount++;
            } else if (block.number > challengeSlots[i].deadlineBlock) {
                expiredSlotsCount++;
            } else {
                activeSlotsCount++;
            }
        }
    }

    /// @notice Get financial overview for the marketplace
    function getFinancialStats()
        external
        view
        returns (
            uint256 totalContractBalance,
            uint256 totalEscrowHeld,
            uint256 totalRewardsPaid,
            uint256 averageOrderValue,
            uint256 totalStakeValue
        )
    {
        totalContractBalance = address(this).balance;

        totalEscrowHeld = aggregateActiveEscrow - aggregateActiveWithdrawn;
        totalRewardsPaid = lifetimeRewardsPaid;

        uint256 totalOrders = nextOrderId - 1;
        averageOrderValue = totalOrders > 0 ? lifetimeEscrowDeposited / totalOrders : 0;

        (, uint256 totalCapacity,) = nodeStaking.getNetworkStats();
        totalStakeValue = totalCapacity * STAKE_PER_CHUNK;
    }

    /// @notice Get order core details by ID
    function getOrderDetails(uint256 _orderId)
        external
        view
        returns (
            address owner_,
            string memory uri_,
            uint256 root_,
            uint32 numChunks_,
            uint16 periods_,
            uint8 replicas_,
            uint8 filled_
        )
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        owner_ = order.owner;
        uri_ = orderUri[_orderId];
        root_ = order.fileRoot;
        numChunks_ = order.numChunks;
        periods_ = order.periods;
        replicas_ = order.replicas;
        filled_ = order.filled;
    }

    /// @notice Get order financial and status details by ID
    function getOrderFinancials(uint256 _orderId)
        external
        view
        returns (uint256 escrow_, uint256 withdrawn_, uint32 startPeriod_, bool expired_, address[] memory nodes_)
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        escrow_ = order.escrow;
        withdrawn_ = orderEscrowWithdrawn[_orderId];
        startPeriod_ = order.startPeriod;
        expired_ = isOrderExpired(_orderId);

        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        nodes_ = new address[](assignments.length);
        for (uint256 i = 0; i < assignments.length; i++) {
            nodes_[i] = assignments[i].node;
        }
    }
}
