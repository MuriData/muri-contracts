// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MarketHelpers} from "./MarketHelpers.sol";
import {PrecompileVerifiers} from "../verifiers/PrecompileVerifiers.sol";

/// @notice On-demand challenge and key-leak reporting functions.
/// Split from MarketChallenge to keep FileMarketExtension under EIP-170 size limit.
/// Reached via chained fallback: FileMarket → Extension → Extension2.
abstract contract MarketOnDemandChallenge is MarketHelpers {
    /// @notice Issue an on-demand challenge for a specific (order, node) pair.
    /// Anyone can call. Separate from the automated slot system.
    function challengeNode(uint256 _orderId, address _node) external nonReentrant {
        FileOrder storage order = orders[_orderId];
        require(order.owner != address(0), "order does not exist");
        require(!isOrderExpired(_orderId), "order expired");

        // Verify node is assigned to this order
        NodeAssignment[] storage assignments = orderAssignments[_orderId];
        bool found = false;
        for (uint256 i = 0; i < assignments.length; i++) {
            if (assignments[i].node == _node) {
                found = true;
                break;
            }
        }
        require(found, "node not assigned to this order");

        bytes32 key = keccak256(abi.encodePacked(_orderId, _node));
        OnDemandChallenge storage challenge = onDemandChallenges[key];

        // Cooldown: cannot re-challenge within CHALLENGE_WINDOW_BLOCKS * 3 after last deadline
        require(
            challenge.deadlineBlock == 0 || block.number > challenge.deadlineBlock + CHALLENGE_WINDOW_BLOCKS * 2,
            "on-demand challenge cooldown"
        );

        uint64 deadline = uint64(block.number + CHALLENGE_WINDOW_BLOCKS);
        uint256 randomness =
            uint256(keccak256(abi.encodePacked(block.prevrandao, block.number, _orderId, _node))) % SNARK_SCALAR_FIELD;
        if (randomness == 0) randomness = 1;

        challenge.deadlineBlock = deadline;
        challenge.randomness = randomness;
        challenge.challenger = msg.sender;
        challenge.fileRoot = order.fileRoot;
        challenge.numChunks = order.numChunks;

        emit OnDemandChallengeIssued(_orderId, _node, msg.sender, deadline);
    }

    /// @notice Submit proof for an on-demand challenge. Only the challenged node can call.
    function submitOnDemandProof(uint256 _orderId, uint256[4] calldata _proof, bytes32 _commitment)
        external
        nonReentrant
    {
        bytes32 key = keccak256(abi.encodePacked(_orderId, msg.sender));
        OnDemandChallenge storage challenge = onDemandChallenges[key];
        require(challenge.randomness != 0, "no active on-demand challenge");
        require(block.number <= challenge.deadlineBlock, "on-demand challenge expired");

        // Verify ZK proof using the file root snapshot stored at challenge time
        // (order may have been cancelled, but the challenge remains valid)
        (,,, uint256 publicKey) = nodeStaking.getNodeInfo(msg.sender);
        require(publicKey != 0, "node public key not set");

        uint256[5] memory publicInputs =
            [uint256(_commitment), challenge.randomness, publicKey, challenge.fileRoot, uint256(challenge.numChunks)];
        PrecompileVerifiers.verifyPoiProof(_proof, publicInputs);

        // Clear active fields but preserve deadlineBlock for cooldown enforcement
        challenge.randomness = 0;
        challenge.challenger = address(0);
        challenge.fileRoot = 0;
        challenge.numChunks = 0;

        emit OnDemandProofSubmitted(_orderId, msg.sender, _commitment);
    }

    /// @notice Process an expired on-demand challenge. Anyone can call after deadline.
    function processExpiredOnDemandChallenge(uint256 _orderId, address _node) external nonReentrant {
        bytes32 key = keccak256(abi.encodePacked(_orderId, _node));
        OnDemandChallenge storage challenge = onDemandChallenges[key];
        require(challenge.randomness != 0, "no active on-demand challenge");
        require(block.number > challenge.deadlineBlock, "on-demand challenge not expired");

        address challenger = challenge.challenger;

        // Clear active fields but preserve deadlineBlock for cooldown enforcement (CEI pattern)
        challenge.randomness = 0;
        challenge.challenger = address(0);
        challenge.fileRoot = 0;
        challenge.numChunks = 0;

        // If the order was cancelled/deleted, the node cannot be faulted — skip slashing.
        FileOrder storage order = orders[_orderId];
        if (order.owner == address(0)) {
            emit OnDemandChallengeExpired(_orderId, _node, 0);
            return;
        }

        // Apply same slash formula as slot-based challenges
        uint256 scaledSlash = uint256(order.numChunks) * _orderPrice(order) * proofFailureSlashMultiplier;
        uint256 slashAmount = scaledSlash > MIN_PROOF_FAILURE_SLASH ? scaledSlash : MIN_PROOF_FAILURE_SLASH;

        if (nodeStaking.isValidNode(_node)) {
            (uint256 nodeStake,,,) = nodeStaking.getNodeInfo(_node);
            if (slashAmount > nodeStake) {
                slashAmount = nodeStake;
            }

            if (slashAmount > 0) {
                (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(_node, slashAmount);
                _distributeSlashFunds(challenger, _node, totalSlashed, _orderId);
                if (forcedExit) {
                    _handleForcedOrderExits(_node);
                }
                emit NodeSlashed(_node, slashAmount, "failed on-demand challenge");
            }
        }

        emit OnDemandChallengeExpired(_orderId, _node, slashAmount);
    }

    /// @notice Report a compromised node key. Anyone who knows the node's secret key
    /// can submit a PLONK proof that H(sk) == pk, slashing the node's full stake.
    /// The proof binds to msg.sender as reporterAddress, preventing front-running.
    function reportKeyLeak(address _node, bytes calldata _proof) external nonReentrant {
        require(nodeStaking.isValidNode(_node), "not a valid node");

        (uint256 nodeStake,,, uint256 publicKey) = nodeStaking.getNodeInfo(_node);
        require(publicKey != 0, "node public key not set");
        require(nodeStake > 0, "node has no stake");

        // Verify PLONK proof: public inputs = [publicKey, reporterAddress]
        // reporterAddress = msg.sender — binds proof to caller, preventing front-running
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = publicKey;
        publicInputs[1] = uint256(uint160(msg.sender));
        PrecompileVerifiers.verifyKeyLeakProof(_proof, publicInputs);

        // Slash full stake — compromised key means node can no longer prove data integrity
        (bool forcedExit, uint256 totalSlashed) = nodeStaking.slashNode(_node, nodeStake);
        _distributeSlashFunds(msg.sender, _node, totalSlashed, 0); // key leak is node-level, not order-specific

        if (forcedExit) {
            _handleForcedOrderExits(_node);
        }

        emit KeyLeakReported(_node, msg.sender, totalSlashed);
    }
}
