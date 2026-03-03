// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FileMarket} from "../../src/Market.sol";
import {NodeStaking} from "../../src/NodeStaking.sol";
import {MarketStorage} from "../../src/market/MarketStorage.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";

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
    uint256 internal constant STAKE_PER_CHUNK = 10 ** 14;
    uint256 internal constant PERIOD = 7 days;
    uint256 internal constant CHALLENGE_WINDOW_BLOCKS = 50;

    uint256 internal constant FILE_ROOT = 0x123456789abcdef;
    string internal constant FILE_URI = "QmTestHash123";

    function setUp() public virtual {
        market = new FileMarket();
        nodeStaking = market.nodeStaking();

        // Mock FSP verifier to always succeed so existing tests don't need valid proofs
        vm.mockCall(
            address(market.fspVerifier()),
            abi.encodeWithSelector(FspVerifier.verifyProof.selector),
            abi.encode()
        );

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(node1, 100 ether);
        vm.deal(node2, 100 ether);
        vm.deal(node3, 100 ether);
    }

    function _fileMeta() internal pure returns (MarketStorage.FileMeta memory) {
        return MarketStorage.FileMeta({root: FILE_ROOT, uri: FILE_URI});
    }

    function _stakeNode(address node, uint64 capacity, uint256 key) internal {
        uint256 stake = uint256(capacity) * STAKE_PER_CHUNK;
        vm.deal(node, node.balance + stake);
        vm.prank(node);
        nodeStaking.stakeNode{value: stake}(capacity, key);
    }

    function _stakeDefaultNode(address node, uint256 key) internal {
        _stakeNode(node, TEST_CAPACITY, key);
    }

    function _emptyFspProof() internal pure returns (uint256[8] memory proof) {
        // Returns zeroed proof array — works with mocked FSP verifier
    }

    function _placeOrder(address owner_, uint32 numChunks, uint16 periods, uint8 replicas, uint256 price)
        internal
        returns (uint256 orderId, uint256 totalCost)
    {
        totalCost = uint256(numChunks) * uint256(periods) * price * uint256(replicas);
        vm.prank(owner_);
        orderId = market.placeOrder{value: totalCost}(_fileMeta(), numChunks, periods, replicas, price, _emptyFspProof());
    }

    function _placeDefaultOrder(address owner_, uint8 replicas) internal returns (uint256 orderId, uint256 totalCost) {
        return _placeOrder(owner_, 1024, 4, replicas, 1e12);
    }

    /// @notice Bootstrap a single slot challenge: stake node, place order, execute, activate slots.
    /// Returns the orderId and the challenged node address from slot 0.
    function _bootstrapSingleSlotChallenge() internal returns (uint256 orderId, address challengedNode) {
        _stakeDefaultNode(node1, 0x1234);
        (orderId,) = _placeDefaultOrder(user1, 1);

        vm.prank(node1);
        market.executeOrder(orderId);

        market.activateSlots();

        // Read slot 0 to get the challenged node
        (uint256 slotOrderId, address slotNode,,,) = market.getSlotInfo(0);
        require(slotOrderId != 0, "slot not activated");
        challengedNode = slotNode;
    }
}

contract BaseRevertingReceiver {
    FileMarket public market;

    constructor(FileMarket _market) {
        market = _market;
    }

    function placeOrderWithOverpayment(uint32 numChunks, uint16 periods, uint8 replicas, uint256 price, uint256 overpay)
        external
    {
        uint256 totalCost = uint256(numChunks) * uint256(periods) * price * uint256(replicas);
        MarketStorage.FileMeta memory meta = MarketStorage.FileMeta({root: 0x123, uri: "test"});
        uint256[8] memory fspProof;
        market.placeOrder{value: totalCost + overpay}(meta, numChunks, periods, replicas, price, fspProof);
    }

    receive() external payable {
        revert("I reject MURI");
    }
}
