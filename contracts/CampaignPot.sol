// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPrizeToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IRoundCoordinator {
    function open(uint256 campaignId, bytes32 commitment) external returns (uint256);
    function finalize(uint256 requestId, bytes32 secret) external returns (uint256);
}

contract CampaignPot {
    IRoundCoordinator public immutable coordinator;
    IPrizeToken public immutable prizeToken;
    address public admin;

    mapping(uint256 => address) public manager;
    mapping(uint256 => uint256) public pot;
    mapping(uint256 => address[]) private entrants;
    mapping(uint256 => bool) public settled;

    event CampaignCreated(uint256 indexed campaignId, address indexed manager);
    event Entered(uint256 indexed campaignId, address indexed account);
    event Funded(uint256 indexed campaignId, uint256 amount);
    event Settled(uint256 indexed campaignId, uint256 indexed requestId, address winner, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    modifier onlyManager(uint256 campaignId) {
        require(manager[campaignId] == msg.sender, "manager");
        _;
    }

    constructor(address coordinator_, address prizeToken_) {
        require(coordinator_ != address(0) && prizeToken_ != address(0), "zero address");
        admin = msg.sender;
        coordinator = IRoundCoordinator(coordinator_);
        prizeToken = IPrizeToken(prizeToken_);
    }

    function createCampaign(uint256 campaignId, address manager_) external onlyAdmin {
        require(manager[campaignId] == address(0), "exists");
        require(manager_ != address(0), "zero manager");
        manager[campaignId] = manager_;
        emit CampaignCreated(campaignId, manager_);
    }

    function fund(uint256 campaignId, uint256 amount) external onlyManager(campaignId) {
        require(prizeToken.transferFrom(msg.sender, address(this), amount), "fund");
        pot[campaignId] += amount;
        emit Funded(campaignId, amount);
    }

    function enter(uint256 campaignId) external {
        require(manager[campaignId] != address(0), "campaign");
        entrants[campaignId].push(msg.sender);
        emit Entered(campaignId, msg.sender);
    }

    function startDraw(uint256 campaignId, bytes32 commitment)
        external
        onlyManager(campaignId)
        returns (uint256 requestId)
    {
        require(entrants[campaignId].length > 0 && pot[campaignId] > 0, "empty");
        requestId = coordinator.open(campaignId, commitment);
    }

    function settle(uint256 campaignId, uint256 requestId, bytes32 secret)
        external
        onlyManager(campaignId)
        returns (address winner)
    {
        require(!settled[campaignId], "settled");
        uint256 random = coordinator.finalize(requestId, secret);
        address[] storage list = entrants[campaignId];
        winner = list[random % list.length];
        uint256 amount = pot[campaignId];
        pot[campaignId] = 0;
        settled[campaignId] = true;
        require(prizeToken.transfer(winner, amount), "prize");
        emit Settled(campaignId, requestId, winner, amount);
    }

    function entrantCount(uint256 campaignId) external view returns (uint256) {
        return entrants[campaignId].length;
    }

    function entrantAt(uint256 campaignId, uint256 index) external view returns (address) {
        return entrants[campaignId][index];
    }
}
