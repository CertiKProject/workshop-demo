// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface ILiquidityAsset {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPortfolioStrategy {
    /// @notice Returns the current value of the complete managed position.
    function managedValue() external view returns (uint256);

    /// @notice Values the liquidity and idle inventory added by a deposit.
    function allocate(uint256 amount0, uint256 amount1)
        external
        returns (uint256 used0, uint256 used1, uint256 addedValue);

    /// @notice Removes a proportional slice and sends the assets to `receiver`.
    function release(uint256 shares, uint256 supply, address receiver)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @title LiquidityVault
/// @notice A two-asset vault with delegated portfolio management.
contract LiquidityVault {
    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error InvalidStrategy();
    error ReentrantCall();
    error InsufficientShares();
    error TransferFailed();

    ILiquidityAsset public immutable ASSET_A;
    ILiquidityAsset public immutable ASSET_B;
    IPortfolioStrategy public immutable STRATEGY;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 private _entered = 1;

    event Deposit(address indexed account, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed account, uint256 shares, uint256 amount0, uint256 amount1, address receiver);

    modifier nonReentrant() {
        if (_entered != 1) revert ReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address assetA, address assetB, address strategy) {
        if (assetA == address(0) || assetB == address(0)) revert ZeroAddress();
        if (strategy == address(0)) revert InvalidStrategy();
        ASSET_A = ILiquidityAsset(assetA);
        ASSET_B = ILiquidityAsset(assetB);
        STRATEGY = IPortfolioStrategy(strategy);
    }

    /// @notice Allocates assets to the portfolio and issues vault shares.
    function deposit(uint256 amount0, uint256 amount1)
        external
        nonReentrant
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        uint256 supplyBefore = totalSupply;
        uint256 valueBefore = 0;
        if (supplyBefore > 0) {
            valueBefore = STRATEGY.managedValue();
            if (valueBefore == 0) revert ZeroShares();
        }

        if (amount0 > 0) {
            _pull(ASSET_A, msg.sender, amount0);
            _push(ASSET_A, address(STRATEGY), amount0);
        }
        if (amount1 > 0) {
            _pull(ASSET_B, msg.sender, amount1);
            _push(ASSET_B, address(STRATEGY), amount1);
        }

        uint256 addedValue;
        (used0, used1, addedValue) = STRATEGY.allocate(amount0, amount1);

        if (supplyBefore == 0) {
            shares = addedValue;
        } else {
            shares = (addedValue * supplyBefore) / valueBefore;
        }
        if (shares == 0) revert ZeroShares();

        balanceOf[msg.sender] += shares;
        totalSupply = supplyBefore + shares;

        if (amount0 > used0) _push(ASSET_A, msg.sender, amount0 - used0);
        if (amount1 > used1) _push(ASSET_B, msg.sender, amount1 - used1);

        emit Deposit(msg.sender, used0, used1, shares);
    }

    /// @notice Burns shares and removes the matching slice of the managed position.
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < shares) revert InsufficientShares();

        uint256 supply = totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply = supply - shares;

        (amount0, amount1) = STRATEGY.release(shares, supply, receiver);
        emit Withdraw(msg.sender, shares, amount0, amount1, receiver);
    }

    function nav() external view returns (uint256) {
        return STRATEGY.managedValue();
    }

    function shareValue(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (STRATEGY.managedValue() * shares) / totalSupply;
    }

    function _pull(ILiquidityAsset token, address from, uint256 amount) internal {
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(ILiquidityAsset token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }
}
