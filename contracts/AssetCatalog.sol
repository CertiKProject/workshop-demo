// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract AssetCatalog {
    struct Asset {
        bool enabled;
        uint8 decimals;
        address guard;
    }

    address public admin;
    uint256 public revision;
    mapping(address => Asset) public assets;

    event AssetUpdated(address indexed token, bool enabled, uint8 decimals, address guard);

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    constructor(address admin_) {
        require(admin_ != address(0), "zero admin");
        admin = admin_;
    }

    function setAsset(address token, bool enabled, uint8 decimals_, address guard) external onlyAdmin {
        require(token != address(0), "zero token");
        require(decimals_ <= 36, "decimals");
        assets[token] = Asset(enabled, decimals_, guard);
        revision++;
        emit AssetUpdated(token, enabled, decimals_, guard);
    }

    function isEnabled(address token) external view returns (bool) {
        return assets[token].enabled;
    }

    function decimalsOf(address token) external view returns (uint8) {
        return assets[token].decimals;
    }
}
