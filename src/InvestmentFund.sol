// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Fund {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2FundRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract InvestmentFund {
    IUniswapV2FundRouter public immutable router;
    uint256 public fundCount;
    mapping(uint256 => address) public manager;
    mapping(uint256 => mapping(address => uint256)) public balance;

    constructor(IUniswapV2FundRouter router_) {
        router = router_;
    }

    modifier onlyManager(uint256 fundId) {
        require(manager[fundId] == msg.sender, "not manager");
        _;
    }

    function createFund() external returns (uint256 fundId) {
        fundId = ++fundCount;
        manager[fundId] = msg.sender;
    }

    function deposit(uint256 fundId, IERC20Fund token, uint256 amount) external onlyManager(fundId) {
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        balance[fundId][address(token)] += amount;
    }

    function swap(
        uint256 fundId,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external onlyManager(fundId) {
        require(path.length >= 2, "invalid path");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        require(balance[fundId][tokenIn] >= amountIn, "insufficient fund balance");

        uint256 beforeIn = IERC20Fund(tokenIn).balanceOf(address(this));
        uint256 beforeOut = IERC20Fund(tokenOut).balanceOf(address(this));
        require(IERC20Fund(tokenIn).approve(address(router), 0), "approval failed");
        require(IERC20Fund(tokenIn).approve(address(router), amountIn), "approval failed");
        router.swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), deadline);

        _applyChange(fundId, tokenIn, beforeIn, IERC20Fund(tokenIn).balanceOf(address(this)));
        _applyChange(fundId, tokenOut, beforeOut, IERC20Fund(tokenOut).balanceOf(address(this)));
    }

    function withdraw(uint256 fundId, IERC20Fund token, uint256 amount) external onlyManager(fundId) {
        balance[fundId][address(token)] -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
    }

    function _applyChange(uint256 fundId, address token, uint256 beforeBalance, uint256 afterBalance) internal {
        if (afterBalance >= beforeBalance) {
            balance[fundId][token] += afterBalance - beforeBalance;
        } else {
            balance[fundId][token] -= beforeBalance - afterBalance;
        }
    }
}
