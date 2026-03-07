// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FileMarket} from "../../src/Market.sol";
import {Verifier} from "muri-artifacts/poi/poi_verifier.sol";
import {Verifier as FspVerifier} from "muri-artifacts/fsp/fsp_verifier.sol";
import {PlonkVerifier as KeyLeakVerifier} from "muri-artifacts/keyleak/keyleak_verifier.sol";

/// @notice Minimal V2 mock for upgrade testing. Appends storage after inherited __gap.
contract FileMarketV2 is FileMarket {
    uint256 public v2ExampleParam;

    constructor(address _ext) FileMarket(_ext) {}

    function initializeV2(uint256 _param) external reinitializer(2) {
        v2ExampleParam = _param;
    }

    function initializeV2WithVerifiers(
        uint256 _param,
        address _poiVerifier,
        address _fspVerifier,
        address _keyleakVerifier
    ) external reinitializer(2) {
        v2ExampleParam = _param;
        poiVerifier = Verifier(_poiVerifier);
        fspVerifier = FspVerifier(_fspVerifier);
        keyleakVerifier = KeyLeakVerifier(_keyleakVerifier);
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
