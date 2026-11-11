// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract RoundCoordinator {
    struct Request {
        uint256 campaignId;
        bytes32 commitment;
        uint256 word;
        uint256 result;
        bool opened;
        bool fulfilled;
        bool finalized;
    }

    address public admin;
    address public oracle;
    uint256 public nextRequestId = 1;
    uint256 public activeRequestId;

    mapping(uint256 => address) public campaignManager;
    mapping(uint256 => Request) public requests;

    event CampaignConfigured(uint256 indexed campaignId, address indexed manager);
    event RequestOpened(uint256 indexed requestId, uint256 indexed campaignId);
    event RequestFulfilled(uint256 indexed requestId, uint256 word);
    event RequestFinalized(uint256 indexed requestId, uint256 result);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "oracle");
        _;
    }

    constructor(address oracle_) {
        require(oracle_ != address(0), "zero oracle");
        admin = msg.sender;
        oracle = oracle_;
    }

    function configureCampaign(uint256 campaignId, address manager) external onlyAdmin {
        require(manager != address(0), "zero manager");
        campaignManager[campaignId] = manager;
        emit CampaignConfigured(campaignId, manager);
    }

    function open(uint256 campaignId, bytes32 commitment) external returns (uint256 requestId) {
        require(campaignManager[campaignId] == msg.sender, "manager");
        require(commitment != bytes32(0), "commitment");
        requestId = nextRequestId++;
        requests[requestId] = Request(campaignId, commitment, 0, 0, true, false, false);
        activeRequestId = requestId;
        emit RequestOpened(requestId, campaignId);
    }

    function fulfill(uint256 requestId, uint256 word) external onlyOracle {
        require(requestId == activeRequestId, "inactive");
        Request storage request = requests[requestId];
        require(request.opened && !request.fulfilled, "request");
        request.word = word;
        request.fulfilled = true;
        emit RequestFulfilled(requestId, word);
    }

    function finalize(uint256 requestId, bytes32 secret) external returns (uint256 result) {
        Request storage request = requests[requestId];
        require(request.opened && request.fulfilled && !request.finalized, "request");
        require(campaignManager[request.campaignId] == msg.sender, "manager");
        require(keccak256(abi.encodePacked(secret)) == request.commitment, "secret");
        result = uint256(keccak256(abi.encode(request.word, secret, request.campaignId)));
        request.result = result;
        request.finalized = true;
        emit RequestFinalized(requestId, result);
    }

    function resultOf(uint256 requestId) external view returns (uint256) {
        require(requests[requestId].finalized, "not final");
        return requests[requestId].result;
    }
}
