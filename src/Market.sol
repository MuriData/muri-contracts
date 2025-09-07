// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Verifier} from "./utils/poi_verifier.sol";
import {NodeStaking} from "./NodeStaking.sol";

contract FileMarket {
    uint256 constant PERIOD = 7 days; // single billing unit
    uint256 constant EPOCH = 4 * PERIOD;
    uint256 constant STEP = 30 seconds; // proof submission period
    uint256 immutable GENESIS_TS; // contract deploy timestamp

    constructor() {
        GENESIS_TS = block.timestamp;
        nodeStaking = new NodeStaking(address(this));
        poiVerifier = new Verifier();
    }

    function currentPeriod() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / PERIOD;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / EPOCH;
    }

    function currentStep() public view returns (uint256) {
        return (block.timestamp - GENESIS_TS) / STEP;
    }

    struct FileMeta {
        uint256 root;
        string uri;
    }

    struct FileOrder {
        address owner;
        FileMeta file;
        uint64 maxSize; // bytes the client is willing to pay for
        uint16 periods; // billing periods to store
        uint8 replicas; // desired redundancy
        uint256 price; // wei / byte / period (quoting module can update global price curves)
        uint8 filled; // replica slots already taken
        uint64 startPeriod; // when storage begins
        uint256 escrow; // prepaid funds held in contract
    }

    // Staking contract for managing node stakes and capacity
    NodeStaking public immutable nodeStaking;

    // Proof of Integrity verifier contract
    Verifier public immutable poiVerifier;
}
