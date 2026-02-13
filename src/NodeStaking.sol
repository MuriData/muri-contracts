// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract NodeStaking {
    // The only contract authorized to update node usage.
    address public immutable market;
    address payable public constant BURN_ADDRESS = payable(address(0));

    constructor(address _market) {
        require(_market != address(0), "invalid market");
        market = _market;
    }

    modifier onlyMarket() {
        require(msg.sender == market, "not market");
        _;
    }

    struct NodeInfo {
        uint256 stake; // locked native token (utility token on subnet)
        uint64 capacity; // bytes committed (≤ stake / stakePerByte)
        uint64 used; // active bytes
        uint256 publicKeyX; // EdDSA public key X coordinate for proof verification
        uint256 publicKeyY; // EdDSA public key Y coordinate for proof verification
    }

    mapping(address => NodeInfo) public nodes;
    address[] public nodeList; // List of all registered node addresses
    mapping(address => uint256) public nodeIndexInList; // index of node in nodeList for O(1) removal
    uint256 public constant STAKE_PER_BYTE = 10 ** 14; // configurable

    /// @dev BN254 scalar field order (Fr). EdDSA public key coordinates must be valid field elements.
    uint256 internal constant SNARK_SCALAR_FIELD = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    // ------------------------------------------------------------------
    // Reentrancy guard
    // ------------------------------------------------------------------
    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ------------------------------------------------------------------
    // Node staking logic
    // ------------------------------------------------------------------

    // Minimum capacity a node can register for in bytes (optional guard)
    uint64 public constant MIN_CAPACITY = 1; // can be updated with governance in future

    event NodeStaked(address indexed node, uint256 stake, uint64 capacity);
    event NodeCapacityIncreased(address indexed node, uint256 additionalStake, uint64 newCapacity);
    event NodeCapacityDecreased(address indexed node, uint256 releasedStake, uint64 newCapacity);
    event NodeUnstaked(address indexed node, uint256 stakeReturned);
    event NodeSlashed(address indexed node, uint256 slashAmount, uint64 newCapacity, bool forcedOrderExit);
    event ForcedOrderExit(address indexed node, uint256[] orderIds, uint256 additionalSlash);

    /// @notice Register a new storage node by locking native tokens proportional to the desired capacity.
    /// @param _capacity The number of bytes the node commits to serve. Must be > 0.
    /// @param _publicKeyX EdDSA public key X coordinate for proof verification
    /// @param _publicKeyY EdDSA public key Y coordinate for proof verification
    function stakeNode(uint64 _capacity, uint256 _publicKeyX, uint256 _publicKeyY) external payable nonReentrant {
        require(_capacity >= MIN_CAPACITY, "capacity too low");
        require(
            _publicKeyX != 0 && _publicKeyX < SNARK_SCALAR_FIELD && _publicKeyY != 0 && _publicKeyY < SNARK_SCALAR_FIELD,
            "public key not in field"
        );

        NodeInfo storage info = nodes[msg.sender];
        require(info.capacity == 0, "already staked");

        uint256 requiredStake = uint256(_capacity) * STAKE_PER_BYTE;
        require(msg.value == requiredStake, "incorrect stake amount");

        info.stake = requiredStake;
        info.capacity = _capacity;
        info.used = 0;
        info.publicKeyX = _publicKeyX;
        info.publicKeyY = _publicKeyY;

        // Add to node list for tracking
        nodeIndexInList[msg.sender] = nodeList.length;
        nodeList.push(msg.sender);

        emit NodeStaked(msg.sender, requiredStake, _capacity);
    }

    /// @notice Increase node capacity by staking additional native tokens.
    /// @param _additionalCapacity Additional bytes to add to the node's commitment.
    function increaseCapacity(uint64 _additionalCapacity) external payable nonReentrant {
        require(_additionalCapacity > 0, "invalid capacity");
        NodeInfo storage info = nodes[msg.sender];
        require(info.capacity > 0, "not a node");

        uint256 additionalStake = uint256(_additionalCapacity) * STAKE_PER_BYTE;
        require(msg.value == additionalStake, "incorrect stake amount");

        info.capacity += _additionalCapacity;
        info.stake += additionalStake;

        emit NodeCapacityIncreased(msg.sender, additionalStake, info.capacity);
    }

    /// @notice Decrease node capacity and unlock a proportion of the stake.
    /// @dev Node can only decrease capacity down to at least `used` bytes.
    /// @param _reduceCapacity Bytes to reduce from the current capacity.
    function decreaseCapacity(uint64 _reduceCapacity) external nonReentrant {
        NodeInfo storage info = nodes[msg.sender];
        require(info.capacity > 0, "not a node");
        require(_reduceCapacity > 0 && _reduceCapacity <= info.capacity - info.used, "cannot reduce below used");

        uint256 stakeToRelease = uint256(_reduceCapacity) * STAKE_PER_BYTE;
        info.capacity -= _reduceCapacity;
        info.stake -= stakeToRelease;

        // Transfer released stake back to node
        (bool success,) = msg.sender.call{value: stakeToRelease}("");
        require(success, "transfer failed");

        emit NodeCapacityDecreased(msg.sender, stakeToRelease, info.capacity);

        // If capacity reached zero, remove from nodeList to prevent stale/duplicate entries
        if (info.capacity == 0) {
            uint256 idx = nodeIndexInList[msg.sender];
            uint256 lastIdx = nodeList.length - 1;
            if (idx != lastIdx) {
                address lastNode = nodeList[lastIdx];
                nodeList[idx] = lastNode;
                nodeIndexInList[lastNode] = idx;
            }
            nodeList.pop();
            delete nodeIndexInList[msg.sender];
            delete nodes[msg.sender];
        }
    }

    /// @notice Fully exit as a storage node and withdraw all stake. Can only be called when no data is stored.
    function unstakeNode() external nonReentrant {
        NodeInfo storage info = nodes[msg.sender];
        require(info.capacity > 0, "not a node");
        require(info.used == 0, "cannot unstake while storing data");

        uint256 stakeToReturn = info.stake;

        // Remove node info mapping entry entirely
        delete nodes[msg.sender];

        // Remove from nodeList via swap-and-pop
        uint256 idx = nodeIndexInList[msg.sender];
        uint256 lastIdx = nodeList.length - 1;
        if (idx != lastIdx) {
            address lastNode = nodeList[lastIdx];
            nodeList[idx] = lastNode;
            nodeIndexInList[lastNode] = idx;
        }
        nodeList.pop();
        delete nodeIndexInList[msg.sender];

        (bool success,) = msg.sender.call{value: stakeToReturn}("");
        require(success, "transfer failed");

        emit NodeUnstaked(msg.sender, stakeToReturn);
    }

    /// @notice Get node information for external contracts
    /// @param node The address of the node
    /// @return stake The amount of stake locked
    /// @return capacity The total capacity in bytes
    /// @return used The currently used capacity in bytes
    /// @return publicKeyX The node's public key X coordinate
    /// @return publicKeyY The node's public key Y coordinate
    function getNodeInfo(address node)
        external
        view
        returns (uint256 stake, uint64 capacity, uint64 used, uint256 publicKeyX, uint256 publicKeyY)
    {
        NodeInfo storage info = nodes[node];
        return (info.stake, info.capacity, info.used, info.publicKeyX, info.publicKeyY);
    }

    /// @notice Update the used capacity for a node (only callable by the market contract)
    /// @param node The address of the node
    /// @param newUsed The new used capacity
    function updateNodeUsed(address node, uint64 newUsed) external onlyMarket {
        NodeInfo storage info = nodes[node];
        require(info.capacity > 0, "not a node");
        require(newUsed <= info.capacity, "used exceeds capacity");
        info.used = newUsed;
    }

    /// @notice Check if a node has sufficient available capacity
    /// @param node The address of the node
    /// @param requiredBytes The bytes needed
    /// @return true if the node has sufficient capacity
    function hasCapacity(address node, uint64 requiredBytes) external view returns (bool) {
        NodeInfo storage info = nodes[node];
        return (info.capacity - info.used) >= requiredBytes;
    }

    /// @notice Returns whether a node is currently valid (has available capacity).
    function isValidNode(address node) public view returns (bool) {
        NodeInfo storage info = nodes[node];
        return info.capacity > 0;
    }

    /// @notice Slash a node's stake and reduce capacity accordingly
    /// @param node The address of the node to slash
    /// @param slashAmount The amount of stake to slash (in wei)
    /// @return forcedOrderExit True if the capacity reduction forced order exits
    /// @return totalSlashed The total amount slashed (including any additional penalty)
    function slashNode(address node, uint256 slashAmount)
        external
        onlyMarket
        nonReentrant
        returns (bool forcedOrderExit, uint256 totalSlashed)
    {
        NodeInfo storage info = nodes[node];
        require(info.capacity > 0, "not a node");
        require(slashAmount > 0, "invalid slash amount");
        require(slashAmount <= info.stake, "slash exceeds stake");

        // Reduce stake
        info.stake -= slashAmount;

        // Calculate new capacity based on reduced stake
        uint64 newCapacity = uint64(info.stake / STAKE_PER_BYTE);

        // Check if capacity reduction forces order exits
        forcedOrderExit = newCapacity < info.used;

        uint256 actualAdditionalSlash = 0;

        if (forcedOrderExit) {
            // Severe slashing: additional penalty for forced order exits
            uint256 additionalSlash = slashAmount / 2; // 50% additional penalty
            if (additionalSlash > info.stake) {
                additionalSlash = info.stake;
            }
            actualAdditionalSlash = additionalSlash;

            if (additionalSlash > 0) {
                info.stake -= additionalSlash;
                newCapacity = uint64(info.stake / STAKE_PER_BYTE);
            }

            // Set used capacity to new capacity (will be updated by market when orders are quit)
            info.used = newCapacity;
            info.capacity = newCapacity;

            emit ForcedOrderExit(node, new uint256[](0), additionalSlash); // Market will populate order IDs
        } else {
            // Normal capacity reduction
            info.capacity = newCapacity;
        }

        // Send slashed funds to market contract (caller) for redistribution
        totalSlashed = slashAmount + actualAdditionalSlash;
        if (totalSlashed > 0) {
            payable(msg.sender).transfer(totalSlashed);
        }

        emit NodeSlashed(node, slashAmount, newCapacity, forcedOrderExit);

        // If capacity dropped to zero, burn any residual stake dust and remove node
        if (info.capacity == 0) {
            uint256 residual = info.stake;
            if (residual > 0) {
                info.stake = 0;
                BURN_ADDRESS.transfer(residual);
            }
            // Remove from nodeList (swap-and-pop)
            uint256 idx = nodeIndexInList[node];
            uint256 lastIdx = nodeList.length - 1;
            if (idx != lastIdx) {
                address lastNode = nodeList[lastIdx];
                nodeList[idx] = lastNode;
                nodeIndexInList[lastNode] = idx;
            }
            nodeList.pop();
            delete nodeIndexInList[node];
            delete nodes[node];
        }
    }

    /// @notice Emergency function to force reduce a node's used capacity (called by market after forced order exits)
    /// @param node The address of the node
    /// @param newUsed The new used capacity after order exits
    function forceReduceUsed(address node, uint64 newUsed) external onlyMarket {
        NodeInfo storage info = nodes[node];
        require(info.capacity > 0, "not a node");
        require(newUsed <= info.capacity, "new used exceeds capacity");
        info.used = newUsed;
    }

    /// @notice Get the maximum slashable amount for a node (leaving minimum viable stake)
    /// @param node The address of the node
    /// @return maxSlashable The maximum amount that can be slashed
    function getMaxSlashable(address node) external view returns (uint256 maxSlashable) {
        NodeInfo storage info = nodes[node];
        if (info.capacity == 0) return 0;

        // Ensure node retains enough stake for currently used capacity
        uint256 requiredStakeForUsed = uint256(info.used) * STAKE_PER_BYTE;
        if (info.stake <= requiredStakeForUsed) return 0;

        return info.stake - requiredStakeForUsed;
    }

    /// @notice Calculate capacity reduction from a slash amount
    /// @param node The address of the node
    /// @param slashAmount The proposed slash amount
    /// @return newCapacity The resulting capacity after slash
    /// @return willForceExit True if this slash would force order exits
    function simulateSlash(address node, uint256 slashAmount)
        external
        view
        returns (uint64 newCapacity, bool willForceExit)
    {
        NodeInfo storage info = nodes[node];
        if (info.capacity == 0 || slashAmount > info.stake) return (0, false);

        uint256 remainingStake = info.stake - slashAmount;
        newCapacity = uint64(remainingStake / STAKE_PER_BYTE);
        willForceExit = newCapacity < info.used;

        if (willForceExit) {
            // Account for additional slash penalty
            uint256 additionalSlash = slashAmount / 2;
            if (additionalSlash > remainingStake) {
                additionalSlash = remainingStake;
            }
            remainingStake -= additionalSlash;
            newCapacity = uint64(remainingStake / STAKE_PER_BYTE);
        }
    }

    /// @notice Get network-wide statistics for monitoring
    function getNetworkStats()
        external
        view
        returns (uint256 totalNodes, uint256 totalCapacityStaked, uint256 totalCapacityUsed)
    {
        // Note: This is a simplified O(n) implementation
        // In production, you'd want to maintain these counters incrementally
        for (uint256 i = 0; i < nodeList.length; i++) {
            address nodeAddr = nodeList[i];
            NodeInfo storage info = nodes[nodeAddr];
            if (info.capacity > 0) {
                totalNodes++;
                totalCapacityStaked += info.capacity;
                totalCapacityUsed += info.used;
            }
        }
    }
}
