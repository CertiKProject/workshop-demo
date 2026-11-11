// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IShareToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract SharePool {
    uint256 public constant SCALE = 1e18;

    IShareToken public immutable shareToken;
    IShareToken public immutable rewardToken;
    address public admin;
    address public treasury;
    address public positionRouter;

    uint256 public totalShares;
    uint256 public rewardIndex;
    uint256 public reserve;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public pending;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event Moved(address indexed from, address indexed to, uint256 amount);
    event Funded(uint256 amount, uint256 index);
    event Claimed(address indexed account, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, "treasury");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == positionRouter, "router");
        _;
    }

    constructor(address shareToken_, address rewardToken_, address treasury_) {
        require(shareToken_ != address(0) && rewardToken_ != address(0), "zero token");
        require(treasury_ != address(0), "zero treasury");
        admin = msg.sender;
        shareToken = IShareToken(shareToken_);
        rewardToken = IShareToken(rewardToken_);
        treasury = treasury_;
    }

    function setPositionRouter(address router) external onlyAdmin {
        require(router != address(0), "zero router");
        positionRouter = router;
    }

    function setTreasury(address treasury_) external onlyAdmin {
        require(treasury_ != address(0), "zero treasury");
        treasury = treasury_;
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "amount");
        _checkpoint(msg.sender);
        require(shareToken.transferFrom(msg.sender, address(this), amount), "share transfer");
        shares[msg.sender] += amount;
        totalShares += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        _checkpoint(msg.sender);
        shares[msg.sender] -= amount;
        totalShares -= amount;
        require(shareToken.transfer(msg.sender, amount), "share transfer");
        emit Withdrawn(msg.sender, amount);
    }

    function move(address from, address to, uint256 amount) external onlyRouter {
        require(to != address(0), "zero recipient");
        _checkpoint(from);
        shares[from] -= amount;
        shares[to] += amount;
        emit Moved(from, to, amount);
    }

    function fund(uint256 amount) external onlyTreasury {
        require(amount > 0 && totalShares > 0, "inactive pool");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "reward transfer");
        reserve += amount;
        rewardIndex += amount * SCALE / totalShares;
        emit Funded(amount, rewardIndex);
    }

    function checkpoint(address account) external {
        _checkpoint(account);
    }

    function claim(address account) external onlyRouter returns (uint256 amount) {
        _checkpoint(account);
        amount = pending[account];
        require(amount > 0, "nothing due");
        pending[account] = 0;
        reserve -= amount;
        require(rewardToken.transfer(account, amount), "reward transfer");
        emit Claimed(account, amount);
    }

    function pendingReward(address account) external view returns (uint256 amount) {
        amount = pending[account];
        if (rewardIndex > userIndex[account]) {
            amount += shares[account] * (rewardIndex - userIndex[account]) / SCALE;
        }
    }

    function _checkpoint(address account) internal {
        uint256 index = rewardIndex;
        uint256 previous = userIndex[account];
        if (index > previous) {
            pending[account] += shares[account] * (index - previous) / SCALE;
            userIndex[account] = index;
        }
    }
}
