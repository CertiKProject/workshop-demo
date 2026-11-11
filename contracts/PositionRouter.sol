// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPositionPool {
    function move(address from, address to, uint256 amount) external;
    function claim(address account) external returns (uint256);
}

contract PositionRouter {
    IPositionPool public immutable pool;

    constructor(address pool_) {
        require(pool_ != address(0), "zero pool");
        pool = IPositionPool(pool_);
    }

    function movePosition(address recipient, uint256 amount) external {
        pool.move(msg.sender, recipient, amount);
    }

    function claim() external returns (uint256) {
        return pool.claim(msg.sender);
    }
}
