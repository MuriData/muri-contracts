// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../../src/Market.sol";
import {NodeStaking} from "../../src/NodeStaking.sol";
import {MarketStorage} from "../../src/market/MarketStorage.sol";
import {Verifier} from "muri-artifacts/poi/poi_verifier.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";
import {PlonkVerifier as KeyLeakVerifier} from "muri-artifacts/keyleak/keyleak_verifier.sol";

/// @notice FSP (File Size Proof) integration tests using real proof fixture.
/// These tests do NOT mock the FSP verifier — they use the actual Groth16 verifier
/// with the deterministic fixture from `fsp_proof_fixture.json`.
contract MarketFSPTest is Test {
    FileMarket internal market;
    NodeStaking internal nodeStaking;

    address internal user1 = address(0x1111);
    address internal node1 = address(0x3333);

    uint256 internal constant STAKE_PER_CHUNK = 10 ** 14;

    // --- Fixture values from fsp_proof_fixture.json ---
    uint256 constant FSP_ROOT = 0x1ad3120e4d04d62860e924470a1c4cae995677cc4d20852125939be6b1341459;
    uint32 constant FSP_NUM_CHUNKS = 8;

    function _fspProof() internal pure returns (uint256[8] memory proof) {
        proof[0] = 0x23f822715db54d5ba8c8b9d55bc670319b814eb738c87d502d4bc61f90ac7e9b;
        proof[1] = 0x248b77e5fd5541e0265b46b5c3d7cd48b7fb80c4867eb677b0c492ef784b013f;
        proof[2] = 0x128bc19b3a965d2bb1ee8a0f951f468e31c3e9638416bbcd977b59a57465fb6a;
        proof[3] = 0x2b0df41e241293067659061b11e169ea4966c0796e438fd11a6fffcc027e5699;
        proof[4] = 0x0865238d6f67abca86f1a1fabfac792666be9318ae358a481e9cca9a15f15079;
        proof[5] = 0x172ee2cde62167b8554f64ef767224307ba8c8d8b0b691786e6a116585208953;
        proof[6] = 0x134f3085f0228c010887efd2f0b828ff49b56cff1323c7e20fdc93ff93c6213e;
        proof[7] = 0x14abf311ab8ae35c4878d9058ff85b0e0060fc6fe795465d1fef30af7aae6e87;
    }

    function _fspFileMeta() internal pure returns (MarketStorage.FileMeta memory) {
        return MarketStorage.FileMeta({root: FSP_ROOT, uri: "QmFSPTestHash"});
    }

    function setUp() public {
        // Deploy verifiers
        Verifier poiVerifier = new Verifier();
        FspVerifier fspVerifierContract = new FspVerifier();
        KeyLeakVerifier keyleakVerifier = new KeyLeakVerifier();

        // Deploy NodeStaking impl + proxy (uninitialized)
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        // Deploy FileMarket impl + proxy (initialized)
        FileMarket marketImpl = new FileMarket();
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (
                address(this),
                address(stakingProxy),
                address(poiVerifier),
                address(fspVerifierContract),
                address(keyleakVerifier)
            )
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        // Initialize NodeStaking with market proxy
        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        market = FileMarket(payable(address(marketProxy)));
        nodeStaking = NodeStaking(address(stakingProxy));

        // Mock PoI verifier to always succeed (FSP tests don't test PoI proofs)
        vm.mockCall(
            address(market.poiVerifier()), abi.encodeWithSelector(Verifier.verifyProof.selector), abi.encode()
        );

        vm.deal(user1, 100 ether);
        vm.deal(node1, 100 ether);
    }

    function _emptyPoiProof() internal pure returns (uint256[8] memory proof) {}


    function test_ValidFSPProof_PlacesOrder() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());
        assertGt(orderId, 0);
    }

    function test_ValidFSPProof_EscrowCorrect() public {
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());
        assertEq(market.aggregateActiveEscrow(), totalCost);
    }

    function test_InvalidFSPProof_Reverts() public {
        uint256[8] memory badProof = _fspProof();
        badProof[0] ^= 1; // flip one bit

        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, badProof);
    }

    function test_WrongNumChunks_Reverts() public {
        uint32 wrongChunks = 16; // proof was generated for 8 chunks
        uint256 totalCost = uint256(wrongChunks) * 4 * 1e12 * 1;

        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(_fspFileMeta(), wrongChunks, 4, 1, 1e12, _fspProof());
    }

    function test_WrongRootHash_Reverts() public {
        MarketStorage.FileMeta memory wrongMeta = MarketStorage.FileMeta({
            root: 0x1111111111111111111111111111111111111111111111111111111111111111, uri: "QmWrongRoot"
        });
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;

        vm.prank(user1);
        vm.expectRevert();
        market.placeOrder{value: totalCost}(wrongMeta, FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());
    }

    function test_ValidFSPProof_FullOrderLifecycle() public {
        // Stake a node
        uint256 stake = uint256(1024) * STAKE_PER_CHUNK;
        vm.prank(node1);
        nodeStaking.stakeNode{value: stake}(1024, 0x1234);

        // Place order with valid FSP proof
        uint256 totalCost = uint256(FSP_NUM_CHUNKS) * 4 * 1e12 * 1;
        vm.prank(user1);
        uint256 orderId = market.placeOrder{value: totalCost}(_fspFileMeta(), FSP_NUM_CHUNKS, 4, 1, 1e12, _fspProof());

        // Execute order
        vm.prank(node1);
        market.executeOrder(orderId, _emptyPoiProof(), bytes32(0));

        // Verify node capacity updated by numChunks
        (, uint64 capacity, uint64 used,) = nodeStaking.getNodeInfo(node1);
        assertEq(used, FSP_NUM_CHUNKS);
        assertEq(capacity, 1024);
    }
}
