// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVaultAsset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IVaultCatalog {
    function isEnabled(address token) external view returns (bool);
}

interface ITradeAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amountOut);
}

contract StrategyVault {
    struct Strategy {
        address manager;
        bool active;
    }

    address public admin;
    IVaultCatalog public immutable catalog;
    ITradeAdapter public adapter;
    uint256 public nextStrategyId = 1;

    mapping(uint256 => Strategy) public strategies;
    mapping(uint256 => mapping(address => uint256)) public credit;

    event StrategyCreated(uint256 indexed strategyId, address indexed manager);
    event Deposited(uint256 indexed strategyId, address indexed token, uint256 amount);
    event Withdrawn(uint256 indexed strategyId, address indexed token, uint256 amount);
    event Traded(uint256 indexed strategyId, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    modifier onlyManager(uint256 strategyId) {
        require(strategies[strategyId].active, "inactive");
        require(strategies[strategyId].manager == msg.sender, "manager");
        _;
    }

    constructor(address catalog_) {
        require(catalog_ != address(0), "zero catalog");
        admin = msg.sender;
        catalog = IVaultCatalog(catalog_);
    }

    function setAdapter(address adapter_) external onlyAdmin {
        require(adapter_ != address(0), "zero adapter");
        adapter = ITradeAdapter(adapter_);
    }

    function createStrategy() external returns (uint256 strategyId) {
        strategyId = nextStrategyId++;
        strategies[strategyId] = Strategy(msg.sender, true);
        emit StrategyCreated(strategyId, msg.sender);
    }

    function deposit(uint256 strategyId, address token, uint256 amount) external onlyManager(strategyId) {
        require(catalog.isEnabled(token), "asset");
        require(amount > 0, "amount");
        require(IVaultAsset(token).transferFrom(msg.sender, address(this), amount), "deposit");
        credit[strategyId][token] += amount;
        emit Deposited(strategyId, token, amount);
    }

    function withdraw(uint256 strategyId, address token, uint256 amount) external onlyManager(strategyId) {
        credit[strategyId][token] -= amount;
        require(IVaultAsset(token).transfer(msg.sender, amount), "withdraw");
        emit Withdrawn(strategyId, token, amount);
    }

    function trade(
        uint256 strategyId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external onlyManager(strategyId) returns (uint256 amountOut) {
        require(address(adapter) != address(0), "adapter");
        require(credit[strategyId][tokenIn] >= amountIn, "credit");

        uint256 beforeIn = IVaultAsset(tokenIn).balanceOf(address(this));
        uint256 beforeOut = IVaultAsset(tokenOut).balanceOf(address(this));
        require(IVaultAsset(tokenIn).approve(address(adapter), 0), "approval");
        require(IVaultAsset(tokenIn).approve(address(adapter), amountIn), "approval");
        amountOut = adapter.swap(tokenIn, tokenOut, amountIn, amountOutMin, deadline, address(this));

        _applyDelta(strategyId, tokenIn, beforeIn, IVaultAsset(tokenIn).balanceOf(address(this)));
        _applyDelta(strategyId, tokenOut, beforeOut, IVaultAsset(tokenOut).balanceOf(address(this)));
        emit Traded(strategyId, tokenIn, tokenOut, amountIn, amountOut);
    }

    function accountValue(uint256 strategyId, address token) external view returns (uint256) {
        return credit[strategyId][token];
    }

    function _applyDelta(uint256 strategyId, address token, uint256 beforeBalance, uint256 afterBalance) internal {
        if (afterBalance >= beforeBalance) {
            credit[strategyId][token] += afterBalance - beforeBalance;
        } else {
            credit[strategyId][token] -= beforeBalance - afterBalance;
        }
    }
}
