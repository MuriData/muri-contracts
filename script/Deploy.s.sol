// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FileMarket} from "../src/Market.sol";
import {NodeStaking} from "../src/NodeStaking.sol";
import {Verifier} from "muri-artifacts/poi/poi_verifier.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";
import {PlonkVerifier as KeyLeakVerifier} from "muri-artifacts/keyleak/keyleak_verifier.sol";

/// @notice Deploys the full MuriData contract suite behind UUPS proxies.
/// Two-step deployment resolves circular FileMarket ↔ NodeStaking reference:
///   1. Deploy verifiers (stateless, no proxy needed)
///   2. Deploy NodeStaking impl + proxy (uninitialized)
///   3. Deploy FileMarket impl + proxy (initialized with staking proxy addr)
///   4. Initialize NodeStaking proxy with market proxy addr
contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy stateless verifiers (no proxy needed)
        Verifier poiVerifier = new Verifier();
        FspVerifier fspVerifier = new FspVerifier();
        KeyLeakVerifier keyleakVerifier = new KeyLeakVerifier();

        console.log("PoI Verifier:", address(poiVerifier));
        console.log("FSP Verifier:", address(fspVerifier));
        console.log("KeyLeak Verifier:", address(keyleakVerifier));

        // 2. Deploy NodeStaking implementation + proxy (uninitialized)
        NodeStaking stakingImpl = new NodeStaking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), "");

        console.log("NodeStaking Impl:", address(stakingImpl));
        console.log("NodeStaking Proxy:", address(stakingProxy));

        // 3. Deploy FileMarket implementation + proxy (initialized with staking proxy addr)
        FileMarket marketImpl = new FileMarket();
        bytes memory marketInitData = abi.encodeCall(
            FileMarket.initialize,
            (deployer, address(stakingProxy), address(poiVerifier), address(fspVerifier), address(keyleakVerifier))
        );
        ERC1967Proxy marketProxy = new ERC1967Proxy(address(marketImpl), marketInitData);

        console.log("FileMarket Impl:", address(marketImpl));
        console.log("FileMarket Proxy:", address(marketProxy));

        // 4. Initialize NodeStaking proxy with market proxy addr
        NodeStaking(address(stakingProxy)).initialize(address(marketProxy));

        console.log("Deployment complete!");
        console.log("Use FileMarket at:", address(marketProxy));
        console.log("Use NodeStaking at:", address(stakingProxy));

        vm.stopBroadcast();
    }
}
