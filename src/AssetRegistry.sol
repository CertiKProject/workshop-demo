// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AssetRegistry
contract AssetRegistry {
	struct Entry {
		address token;
		bool depositEnabled;
	}

	event EntryIncluded(address indexed token, bool depositEnabled);
	event EntryExcluded(address indexed token);
	event BalanceRecorded(address indexed token, uint256 amount);
	event GuardAssigned(address indexed token, address guard);

	error NotAdmin();
	error ZeroAddress();
	error AssetRejected();
	error MissingEntry();

	address public admin;

	Entry[] public assetEntries;
	mapping(address => uint256) public entrySlot;

	mapping(address => bool) public tradable;
	mapping(address => uint256) public recordedBalance;
	mapping(address => address) public guardOf;

	modifier onlyAdmin() {
		if (msg.sender != admin) revert NotAdmin();
		_;
	}

	constructor(address _admin, Entry[] memory seed) {
		if (_admin == address(0)) revert ZeroAddress();
		admin = _admin;

		for (uint256 i; i < seed.length; ++i) {
			address token = seed[i].token;
			if (token == address(0)) revert ZeroAddress();
			tradable[token] = true;
			_include(seed[i]);
		}
	}

	function approveAsset(address token, bool allowed) external onlyAdmin {
		if (token == address(0)) revert ZeroAddress();
		tradable[token] = allowed;
	}

	function recordBalance(address token, uint256 amount) external onlyAdmin {
		recordedBalance[token] = amount;
		emit BalanceRecorded(token, amount);
	}

	function assignGuard(address token, address guard) external onlyAdmin {
		guardOf[token] = guard;
		emit GuardAssigned(token, guard);
	}

	/// @notice Membership is the slot map, not a scan of `assetEntries`.
	function contains(address token) public view returns (bool) {
		return entrySlot[token] != 0;
	}

	/// @notice Excludes first, then includes. Both passes run in this call.
	function applyChanges(Entry[] calldata incoming, address[] calldata outgoing) external onlyAdmin {
		for (uint256 i; i < outgoing.length; ++i) {
			_exclude(outgoing[i]);
		}

		for (uint256 i; i < incoming.length; ++i) {
			_include(incoming[i]);
		}
	}

	function _include(Entry memory item) internal {
		address token = item.token;
		bool depositEnabled = item.depositEnabled;

		if (!tradable[token]) revert AssetRejected();

		if (contains(token)) {
			uint256 idx = entrySlot[token] - 1;
			assetEntries[idx].depositEnabled = depositEnabled;
		} else {
			uint256 len = assetEntries.length;
			assetEntries.push(Entry({token: token, depositEnabled: depositEnabled}));
			entrySlot[token] = len + 1;
		}

		emit EntryIncluded(token, depositEnabled);
	}

	function _exclude(address token) internal {
		if (!contains(token)) revert MissingEntry();

		address guard = guardOf[token];
		if (guard != address(0)) {
			require(recordedBalance[token] == 0, "balance left");
		}

		uint256 idx = entrySlot[token] - 1;
		uint256 len = assetEntries.length;

		for (uint256 i = idx; i + 1 < len; ++i) {
			assetEntries[i] = assetEntries[i + 1];
			entrySlot[assetEntries[i].token] = i + 1;
		}

		entrySlot[assetEntries[len - 1].token] = 0;
		assetEntries.pop();

		emit EntryExcluded(token);
	}
}
