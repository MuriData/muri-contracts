// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FileMarket} from "../../src/Market.sol";
import {NodeStaking} from "../../src/NodeStaking.sol";
import {MarketStorage} from "../../src/market/MarketStorage.sol";

abstract contract MarketTestBase is Test {
    event OrderUnderReplicated(uint256 indexed orderId, uint8 currentFilled, uint8 desiredReplicas);

    FileMarket internal market;
    NodeStaking internal nodeStaking;

    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);
    address internal node1 = address(0x3333);
    address internal node2 = address(0x4444);
    address internal node3 = address(0x5555);

    uint64 internal constant TEST_CAPACITY = 1024;
    uint256 internal constant STAKE_PER_BYTE = 10 ** 14;
    uint256 internal constant PERIOD = 7 days;
    uint256 internal constant STEP = 30 seconds;

    uint256 internal constant FILE_ROOT = 0x123456789abcdef;
    string internal constant FILE_URI = "QmTestHash123";

    function setUp() public virtual {
        market = new FileMarket();
        nodeStaking = market.nodeStaking();

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(node1, 100 ether);
        vm.deal(node2, 100 ether);
        vm.deal(node3, 100 ether);
    }

    function _fileMeta() internal pure returns (MarketStorage.FileMeta memory) {
        return MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
    }

    function _stakeNode(address node, uint64 capacity, uint256 keyX, uint256 keyY) internal {
        uint256 stake = uint256(capacity) * STAKE_PER_BYTE;
        vm.deal(node, node.balance + stake);
        vm.prank(node);
        nodeStaking.stakeNode{value: stake}(capacity, keyX, keyY);
    }

    function _stakeDefaultNode(address node, uint256 keyX, uint256 keyY) internal {
        _stakeNode(node, TEST_CAPACITY, keyX, keyY);
    }

    function _placeOrder(address owner_, uint64 maxSize, uint16 periods, uint8 replicas, uint256 price)
        internal
        returns (uint256 orderId, uint256 totalCost)
    {
        totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);
        vm.prank(owner_);
        orderId = market.placeOrder{value: totalCost}(_fileMeta(), maxSize, periods, replicas, price);
    }

    function _placeDefaultOrder(address owner_, uint8 replicas) internal returns (uint256 orderId, uint256 totalCost) {
        return _placeOrder(owner_, 1024, 4, replicas, 1e12);
    }

    function _bootstrapSingleOrderChallenge() internal returns (uint256 orderId, address primaryProver) {
        _stakeDefaultNode(node1, 0x1234, 0x5678);
        (orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        vm.warp(block.timestamp + STEP + 1);
        market.triggerHeartbeat();

        (,, primaryProver,,,,) = market.getCurrentChallengeInfo();
    }
}

contract BaseRevertingReceiver {
    FileMarket public market;

    constructor(FileMarket _market) {
        market = _market;
    }

    function placeOrderWithOverpayment(
        uint64 maxSize,
        uint16 periods,
        uint8 replicas,
        uint256 price,
        uint256 overpay
    ) external {
        uint256 totalCost = uint256(maxSize) * uint256(periods) * price * uint256(replicas);
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: 0x123, uri: "test"});
        market.placeOrder{value: totalCost + overpay}(meta, maxSize, periods, replicas, price);
    }

    receive() external payable {
        revert("I reject ETH");
    }
}
