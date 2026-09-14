// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice WETH9-shaped wrapper of the native coin, for coordinator tests and the Rust e2e.
contract MockWRBTC is ERC20 {
    error TransferFailed();

    constructor() ERC20("Wrapped RBTC", "WRBTC") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
