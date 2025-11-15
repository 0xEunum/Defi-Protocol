// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vault} from "src/Decentralized Vault/Vault.sol";
import {VaultERC20} from "src/Decentralized Vault/VaultERC20.sol";
import {DeployVault} from "script/Decentralized Vault/DeployVault.s.sol";

contract VaultUnit is Test {
    Vault vault;
    VaultERC20 token;
    DeployVault deployer;

    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    address owner = address(1);
    address user = address(2);
    address user2 = address(3);

    // Used to calculate the 5% APR rate per second
    uint256 constant APR = 5e16; // 5% = 0.05 * 1e18
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 ratePerSecond = APR / SECONDS_PER_YEAR;

    function setUp() external {
        vm.startPrank(owner);
        deployer = new DeployVault();
        (vault, token) = deployer.run();
        vm.stopPrank();

        // Transfer the ownership to the owner!
        vm.prank(address(deployer));
        vault.transferOwnership(owner);

        // Give test users some tokens
        token.mint(user, DEPOSIT_AMOUNT);
        token.mint(user2, DEPOSIT_AMOUNT);

        // Users approve vault
        vm.startPrank(user);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function testDepositMintsShares() public {
        vm.startPrank(user);
        uint256 amount = 100 ether;
        uint256 sharesBefore = vault.sharesOf(user);
        vault.deposit(amount);
        uint256 sharesAfter = vault.sharesOf(user);
        vm.stopPrank();

        assertGt(sharesAfter, sharesBefore);
        assertEq(vault.totalShares(), sharesAfter);
        assertEq(token.balanceOf(address(vault)), amount);
    }

    function testDepositZeroReverts() public {
        vm.startPrank(user);
        vm.expectRevert("ZERO_AMOUNT");
        vault.deposit(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testWithdrawReturnsAssets() public {
        vm.startPrank(user);
        token.transfer(address(vault), 5e18);
        vault.deposit(5 ether);
        uint256 shares = vault.sharesOf(user);

        // simulate some time passing to accrue interest
        vm.warp(block.timestamp + 365 days);
        vault.accrue();

        uint256 expectedAssets = vault.previewWithdraw(shares);
        uint256 userBalanceBefore = token.balanceOf(user);
        vault.withdrawAssest(shares);
        uint256 userBalanceAfter = token.balanceOf(user);
        vm.stopPrank();

        assertApproxEqAbs(userBalanceAfter - userBalanceBefore, expectedAssets, 1e9);
        assertEq(vault.sharesOf(user), 0);
    }

    function testWithdrawAllWorks() public {
        vm.startPrank(user);
        token.transfer(address(vault), 5e18);
        vault.deposit(5 ether);
        vm.warp(block.timestamp + 100 days);
        vm.roll(100);
        vault.accrue();
        vault.withdrawAll();
        vm.stopPrank();

        assertEq(vault.sharesOf(user), 0);
    }

    function testWithdrawMoreThanSharesReverts() public {
        vm.startPrank(user);
        vault.deposit(10 ether);
        vm.expectRevert("INSUFFICIENT_SHARES");
        vault.withdrawAssest(20 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                ACCRUE
    //////////////////////////////////////////////////////////////*/

    function testAccrueIncreasesExchangeRate() public {
        uint256 beforeRate = vault.exchangeRate();
        vm.warp(block.timestamp + 30 days);
        vault.accrue();
        uint256 afterRate = vault.exchangeRate();

        assertGt(afterRate, beforeRate);
    }

    function testAccrueNoChangeIfCalledSameBlock() public {
        vault.accrue();
        uint256 rate1 = vault.exchangeRate();
        vault.accrue();
        uint256 rate2 = vault.exchangeRate();

        assertEq(rate1, rate2);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE / ADMIN
    //////////////////////////////////////////////////////////////*/

    function testPauseBlocksDeposit() public {
        vm.startPrank(owner);
        vault.setPaused(true);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert("PAUSED");
        vault.deposit(10 ether);
        vm.stopPrank();
    }

    function testOnlyOwnerCanPause() public {
        vm.startPrank(user);
        vm.expectRevert(); // standard Ownable revert
        vault.setPaused(true);
        vm.stopPrank();
    }

    function testOwnerCanChangeRate() public {
        vm.startPrank(owner);
        uint256 newRate = 2e12;
        vault.setRatePerSecond(newRate);
        vm.stopPrank();

        assertEq(vault.ratePerSecond(), newRate);
    }

    /*//////////////////////////////////////////////////////////////
                            MULTI USER BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function testMultipleDepositorsGetProportionalShares() public {
        vm.startPrank(user);
        vault.deposit(100 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vault.deposit(200 ether);
        vm.stopPrank();

        uint256 user1Shares = vault.sharesOf(user);
        uint256 user2Shares = vault.sharesOf(user2);

        // Bob (user2) should have double shares
        assertEq(user2Shares, user1Shares * 2);
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    function testDepositEmitsEvent() public {
        vm.startPrank(user);
        vm.expectEmit(true, false, false, true);
        emit Vault.Deposit(user, 50 ether, 50 ether);
        vault.deposit(50 ether);
        vm.stopPrank();
    }
}
