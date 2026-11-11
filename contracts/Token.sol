// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Token {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public immutable issuer;
    address public feeRecipient;
    uint16 public transferFeeBps;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    modifier onlyIssuer() {
        require(msg.sender == issuer, "issuer");
        _;
    }

    constructor(string memory name_, string memory symbol_, address issuer_) {
        require(issuer_ != address(0), "zero issuer");
        name = name_;
        symbol = symbol_;
        decimals = 18;
        issuer = issuer_;
        feeRecipient = issuer_;
    }

    function setTransferFee(uint16 feeBps, address recipient) external onlyIssuer {
        require(feeBps <= 1_000, "fee too high");
        require(recipient != address(0), "zero recipient");
        transferFeeBps = feeBps;
        feeRecipient = recipient;
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        require(to != address(0), "zero recipient");
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero recipient");
        balanceOf[from] -= amount;
        uint256 fee = amount * transferFeeBps / 10_000;
        uint256 received = amount - fee;
        balanceOf[to] += received;
        emit Transfer(from, to, received);
        if (fee != 0) {
            balanceOf[feeRecipient] += fee;
            emit Transfer(from, feeRecipient, fee);
        }
    }
}
