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
        claimable = this.getClaimableRewards(_node);
        lastClaimPeriod = nodeLastClaimPeriod[_node];
    }

    /// @notice Get current challenge info
    function getCurrentChallengeInfo()
        external
        view
        returns (
            uint256 randomness,
            uint256 challengeStep,
            address primaryProver,
            address[] memory secondaryProvers,
            uint256[] memory challengedOrders,
            bool primarySubmitted,
            bool challengeActive
        )
    {
        randomness = currentRandomness;
        challengeStep = lastChallengeStep;
        primaryProver = currentPrimaryProver;
        secondaryProvers = currentSecondaryProvers;
        challengedOrders = currentChallengedOrders;
        primarySubmitted = primaryProofReceived;
        challengeActive = (currentStep() <= lastChallengeStep + 1) && challengeInitialized;
    }

    /// @notice Check if a node has submitted proof for current challenge
    function hasSubmittedProof(address _node) external view returns (bool) {
        return proofSubmitted[_node];
    }

    /// @notice Check if challenge period has expired
    function isChallengeExpired() external view returns (bool) {
        return currentStep() > lastChallengeStep + 1;
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

    /// @notice Get node's earnings from a specific order
    function getNodeOrderEarnings(address _node, uint256 _orderId) external view returns (uint256) {
        return nodeOrderEarnings[_orderId][_node];
    }

    // =============================================================================
    // NETWORK MONITORING FUNCTIONS FOR WEB DASHBOARD
    // =============================================================================

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
            uint256 currentRandomnessValue,
            uint256 lastHeartbeatStep,
            uint256 currentPeriod_,
            uint256 currentStep_,
            uint256 challengeableOrdersCount
        )
    {
        totalOrders = nextOrderId - 1;
        activeOrdersCount = activeOrders.length;
        challengeableOrdersCount = challengeableOrders.length;

        totalEscrowLocked = aggregateActiveEscrow - aggregateActiveWithdrawn;

        // Get node network statistics (O(1) via incremental aggregates)
        (totalNodes, totalCapacityStaked, totalCapacityUsed) = nodeStaking.getNetworkStats();

        currentRandomnessValue = currentRandomness;
        lastHeartbeatStep = lastChallengeStep;
        currentPeriod_ = currentPeriod();
        currentStep_ = currentStep();
    }

    /// @notice Get recent order activity for dashboard
    function getRecentOrders(uint256 count)
        external
        view
        returns (
            uint256[] memory orderIds,
            address[] memory owners,
            uint64[] memory sizes,
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
                new uint64[](0),
                new uint16[](0),
                new uint8[](0),
                new uint8[](0),
                new uint256[](0),
                new bool[](0)
            );
        }

        orderIds = new uint256[](returnCount);
        owners = new address[](returnCount);
        sizes = new uint64[](returnCount);
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
            sizes[idx] = order.maxSize;
            periods[idx] = order.periods;
            replicas[idx] = order.replicas;
            filled[idx] = order.filled;
            escrows[idx] = order.escrow;

            if (order.owner != address(0)) {
                uint256 endPeriod = order.startPeriod + order.periods;
                isActive[idx] = currentPer < endPeriod;
            }
        }
    }

    /// @notice Get proof system health and challenge statistics
    function getProofSystemStats()
        external
        view
        returns (
            uint256 totalChallengeRounds,
            uint256 currentStepValue,
            uint256 lastChallengeStepValue,
            bool challengeActive,
            address currentPrimaryProverAddress,
            uint256 challengedOrdersCount,
            uint256[] memory currentChallengedOrderIds,
            address[] memory secondaryProversList
        )
    {
        totalChallengeRounds = lastChallengeStep;
        currentStepValue = currentStep();
        lastChallengeStepValue = lastChallengeStep;
        challengeActive = (currentStepValue <= lastChallengeStep + 1) && challengeInitialized;
        currentPrimaryProverAddress = currentPrimaryProver;
        challengedOrdersCount = currentChallengedOrders.length;
        currentChallengedOrderIds = currentChallengedOrders;
        secondaryProversList = currentSecondaryProvers;
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
        totalStakeValue = totalCapacity * nodeStaking.STAKE_PER_BYTE();
    }

    /// @notice Get order core details by ID
    function getOrderDetails(uint256 _orderId)
        external
        view
        returns (
            address owner_,
            string memory uri_,
            uint256 root_,
            uint64 maxSize_,
            uint16 periods_,
            uint8 replicas_,
            uint8 filled_
        )
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        owner_ = order.owner;
        uri_ = order.file.uri;
        root_ = order.file.root;
        maxSize_ = order.maxSize;
        periods_ = order.periods;
        replicas_ = order.replicas;
        filled_ = order.filled;
    }

    /// @notice Get order financial and status details by ID
    function getOrderFinancials(uint256 _orderId)
        external
        view
        returns (uint256 escrow_, uint256 withdrawn_, uint64 startPeriod_, bool expired_, address[] memory nodes_)
    {
        require(_orderId > 0 && _orderId < nextOrderId, "invalid order id");
        FileOrder storage order = orders[_orderId];
        escrow_ = order.escrow;
        withdrawn_ = orderEscrowWithdrawn[_orderId];
        startPeriod_ = order.startPeriod;
        expired_ = isOrderExpired(_orderId);
        nodes_ = orderToNodes[_orderId];
    }
}
