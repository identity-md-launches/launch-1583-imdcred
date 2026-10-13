// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IMDCred} from "../src/IMDCred.sol";

/// @title DeployIMDCred
/// @notice Reviewable deployment entry point for local forks and testnets.
/// @dev The production launch on Robinhood Chain is performed by IMD's ProjectFactory from the
/// attested creation code, not by this script. The token takes no constructor arguments, so
/// there is nothing to configure: `deploy` is a pure function of the caller, who receives the
/// whole supply. Tests call `deploy` directly; `run` only wraps it in a broadcast.
contract DeployIMDCred is Script {
    /// @notice Deploys the token. The whole supply is minted to `msg.sender` of the creation,
    /// which under `run` is the broadcasting account.
    function deploy() public returns (IMDCred token) {
        token = new IMDCred();
    }

    function run() external returns (IMDCred token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
