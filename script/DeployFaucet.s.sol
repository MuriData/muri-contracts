// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MuriFaucet} from "../src/Faucet.sol";

/// @notice Deploys MuriFaucet with 10 MURI per claim and 1 hour cooldown.
///         Fund it after deployment by sending native tokens to the contract address.
///
/// Usage:
///   forge script script/DeployFaucet.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
contract DeployFaucetScript is Script {
    function run() external {
        vm.startBroadcast();

        uint256 claimAmount = 10 ether; // 10 MURI
        uint256 cooldown = 1 hours;

        MuriFaucet faucet = new MuriFaucet(claimAmount, cooldown);

        console.log("MuriFaucet deployed at:", address(faucet));
        console.log("Claim amount:", claimAmount);
        console.log("Cooldown:", cooldown);

        vm.stopBroadcast();
    }
}
