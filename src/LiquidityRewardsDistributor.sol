// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

/**
 * @title LiquidityRewardsDistributor
 * @notice LP holder reward distribution contract.
 */
contract LiquidityRewardsDistributor {
    uint256 public constant MAG = 2 ** 128;

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;

    address public owner;
    address public rewardSource;

    uint256 public magnifiedDividendPerShare;
    uint256 public trackedRewardBalance;

    mapping(address => int256) public magnifiedDividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    mapping(address => uint256) public lpBalanceSnap;

    address[] public knownAccounts;
    mapping(address => bool) public isKnownAccount;

    event RewardDeposited(uint256 amount);
    event DividendClaimed(address indexed account, uint256 amount);
    event AccountSynced(address indexed account, uint256 lpBalance);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyRewardSource() {
        require(msg.sender == rewardSource, "not reward source");
        _;
    }

    constructor(address lpToken_, address rewardToken_) {
        require(lpToken_ != address(0), "zero lp token");
        require(rewardToken_ != address(0), "zero reward token");

        owner = msg.sender;
        lpToken = IERC20(lpToken_);
        rewardToken = IERC20(rewardToken_);
    }

    function configurePayoutOperator(address source) external onlyOwner {
        require(source != address(0), "zero source");
        rewardSource = source;
    }

    function enrollParticipant(address account) external {
        require(account != address(0), "zero account");

        if (!isKnownAccount[account]) {
            isKnownAccount[account] = true;
            knownAccounts.push(account);
        }
    }

    /**
     * The caller must first approve this contract for rewardAmount.
     * The reward index is increased for the full LP supply at this moment.
     */
    function fundDistribution(uint256 rewardAmount) external onlyRewardSource {
        require(rewardAmount > 0, "zero reward");

        uint256 totalShares = lpToken.totalSupply();
        require(totalShares > 0, "no lp supply");

        require(
            rewardToken.transferFrom(
                msg.sender,
                address(this),
                rewardAmount
            ),
            "reward transfer failed"
        );

        magnifiedDividendPerShare +=
            (rewardAmount * MAG) /
            totalShares;
        trackedRewardBalance += rewardAmount;

        emit RewardDeposited(rewardAmount);
    }

    function refreshPosition(address account) external {
        _refresh(account);
    }

    function accruedEntitlement(address account) public view returns (uint256) {
        uint256 current = lpToken.balanceOf(account);
        int256 magnified =
            int256(magnifiedDividendPerShare) * int256(current) +
            magnifiedDividendCorrections[account];

        if (magnified <= 0) {
            return 0;
        }

        return uint256(magnified) / MAG;
    }

    function claimableAmount(address account) public view returns (uint256) {
        uint256 accumulated = accruedEntitlement(account);
        uint256 withdrawn = withdrawnDividends[account];

        return accumulated > withdrawn
            ? accumulated - withdrawn
            : 0;
    }

    function redeemRewards() external returns (uint256 amount) {
        amount = _settle(msg.sender);
    }

    function settleParticipant(address account)
        external
        returns (uint256 amount)
    {
        amount = _settle(account);
    }

    function settleBatch(address[] calldata accounts)
        external
        returns (uint256 processed)
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            _settle(accounts[i]);
            processed++;
        }
    }

    function _settle(address account) internal returns (uint256 amount) {
        _refresh(account);

        amount = claimableAmount(account);
        require(amount > 0, "no dividend");

        withdrawnDividends[account] += amount;
        require(
            rewardToken.transfer(account, amount),
            "payout failed"
        );
        trackedRewardBalance -= amount;

        emit DividendClaimed(account, amount);
    }

    function _refresh(address account) internal {
        uint256 current = lpToken.balanceOf(account);
        uint256 previous = lpBalanceSnap[account];

        if (current != previous) {
            magnifiedDividendCorrections[account] -=
                int256(magnifiedDividendPerShare) *
                int256(current - previous);

            lpBalanceSnap[account] = current;
        }

        if (!isKnownAccount[account]) {
            isKnownAccount[account] = true;
            knownAccounts.push(account);
        }

        emit AccountSynced(account, current);
    }
}
