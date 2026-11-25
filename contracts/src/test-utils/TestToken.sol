// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Testnet-only token with open minting, used to create demo pools. Never deploy on mainnet.
contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
