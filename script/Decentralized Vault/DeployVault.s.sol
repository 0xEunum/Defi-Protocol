// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vault} from "src/Decentralized Vault/Vault.sol";
import {VaultERC20} from "src/Decentralized Vault/VaultERC20.sol";

contract DeployVault is Script {
    Vault vault;
    VaultERC20 token;
    uint256 constant ANVIL_CHAIN_ID = 31337;

    function run() external returns (Vault, VaultERC20) {
        if (block.chainid == ANVIL_CHAIN_ID) {
            token = new VaultERC20();

            uint256 apr = 5e16;
            uint256 rps = apr / 31536000;

            vault = new Vault(address(token), rps);
            return (vault, token);
        }

        vm.startBroadcast();

        token = new VaultERC20();

        uint256 apr = 5e16;
        uint256 rps = apr / 31536000;

        vault = new Vault(address(token), rps);

        vm.stopBroadcast();

        return (vault, token);
    }
}
