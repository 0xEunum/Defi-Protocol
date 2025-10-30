// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VaultERC20 is ERC20 {
    constructor() ERC20("VaultERC20", "VT") {}
}
