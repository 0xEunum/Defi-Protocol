// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vault} from "src/Decentralized Vault/Vault.sol";
import {VaultERC20} from "src/Decentralized Vault/VaultERC20.sol";
import {DeployVault} from "script/Decentralized Vault/DeployVault.s.sol";

contract VaultFuzz is Test {
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

        // Transfer the ownership to the owner
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
                            FUZZ DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test deposit with random amounts - verifies shares calculation and balance changes
    function testFuzz_Deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= DEPOSIT_AMOUNT);

        vm.startPrank(user);
        uint256 vaultBalanceBefore = token.balanceOf(address(vault));
        uint256 userBalanceBefore = token.balanceOf(user);
        uint256 sharesBefore = vault.sharesOf(user);

        uint256 sharesMinted = vault.deposit(amount);

        uint256 vaultBalanceAfter = token.balanceOf(address(vault));
        uint256 userBalanceAfter = token.balanceOf(user);
        uint256 sharesAfter = vault.sharesOf(user);

        // Verify token transfer
        assertEq(vaultBalanceAfter, vaultBalanceBefore + amount);
        assertEq(userBalanceAfter, userBalanceBefore - amount);

        // Verify shares minted correctly (using current exchangeRate)
        uint256 expectedShares = vault.previewDeposit(amount);
        assertEq(sharesMinted, expectedShares);
        assertEq(sharesAfter, sharesBefore + sharesMinted);

        vm.stopPrank();
    }

    /// @notice Fuzz test multiple deposits by different users
    function testFuzz_MultipleDeposits(uint256 amount1, uint256 amount2) public {
        vm.assume(amount1 > 0 && amount1 <= DEPOSIT_AMOUNT / 2);
        vm.assume(amount2 > 0 && amount2 <= DEPOSIT_AMOUNT / 2);

        // User1 deposits
        vm.startPrank(user);
        uint256 shares1 = vault.deposit(amount1);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        uint256 shares2 = vault.deposit(amount2);
        vm.stopPrank();

        // Verify total shares and vault balance
        assertEq(vault.totalShares(), shares1 + shares2);
        assertEq(token.balanceOf(address(vault)), amount1 + amount2);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test withdraw with random share amounts
    function testFuzz_Withdraw(uint256 depositAmount, uint256 withdrawShares) public {
        vm.assume(depositAmount > 0 && depositAmount <= DEPOSIT_AMOUNT);

        vm.startPrank(user);
        // Deposit first
        uint256 mintedShares = vault.deposit(depositAmount);
        uint256 sharesDeposited = vault.sharesOf(user);
        assertEq(sharesDeposited, mintedShares);

        // Constrain withdrawShares to valid range based on actual minted shares
        uint256 sharesToWithdraw = bound(withdrawShares, 1, sharesDeposited);

        uint256 vaultBalanceBefore = token.balanceOf(address(vault));
        uint256 userBalanceBefore = token.balanceOf(user);
        uint256 sharesBefore = vault.sharesOf(user);

        uint256 assetsExpected = vault.previewWithdraw(sharesToWithdraw);
        uint256 assetsWithdrawn = vault.withdrawAssest(sharesToWithdraw);

        uint256 vaultBalanceAfter = token.balanceOf(address(vault));
        uint256 userBalanceAfter = token.balanceOf(user);
        uint256 sharesAfter = vault.sharesOf(user);

        // Verify withdrawal amount matches preview
        assertEq(assetsWithdrawn, assetsExpected);

        // Verify token transfer
        assertEq(vaultBalanceAfter, vaultBalanceBefore - assetsWithdrawn);
        assertEq(userBalanceAfter, userBalanceBefore + assetsWithdrawn);

        // Verify shares burned
        assertEq(sharesAfter, sharesBefore - sharesToWithdraw);
        vm.stopPrank();
    }

    /// @notice Fuzz test deposit then withdraw all (round trip)
    /// Principal safety: never loses principal; interest may be zero for small dt due to truncation.
    // function testFuzz_DepositWithdrawRoundtrip(uint256 amount, uint256 timeDelta) public {
    //     vm.assume(amount > 0 && amount <= DEPOSIT_AMOUNT);
    //     // Restrict timeDelta to realistic range and avoid 0
    //     timeDelta = bound(timeDelta, 1 hours, 365 days);

    //     vm.startPrank(user);
    //     uint256 userBalanceBefore = token.balanceOf(user);

    //     // Deposit
    //     uint256 sharesMinted = vault.deposit(amount);
    //     assertGt(sharesMinted, 0);
    //     assertEq(token.balanceOf(user), userBalanceBefore - amount);

    //     // Accrue some interest (warp time)
    //     vm.warp(block.timestamp + timeDelta);
    //     vault.accrue();

    //     // Withdraw all
    //     uint256 assetsWithdrawn = vault.withdrawAll();

    //     uint256 userBalanceAfter = token.balanceOf(user);
    //     assertEq(vault.sharesOf(user), 0);

    //     // Principal safety: never lose initial deposit
    //     assertGe(assetsWithdrawn, amount);

    //     // User balance increased by assetsWithdrawn relative to post-deposit state
    //     assertEq(userBalanceAfter, userBalanceBefore - amount + assetsWithdrawn);

    //     vm.stopPrank();
    // }

    /*//////////////////////////////////////////////////////////////
                            FUZZ INTEREST TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test interest accrual over random time periods
    /// Ensures exchangeRate is non-decreasing and principal is safe.
    function testFuzz_InterestAccrual(uint256 depositAmount, uint256 timeDelta) public {
        vm.assume(depositAmount > 0 && depositAmount <= DEPOSIT_AMOUNT);
        timeDelta = bound(timeDelta, 1 hours, 365 days);

        vm.startPrank(user);
        vault.deposit(depositAmount);
        uint256 initialShares = vault.sharesOf(user);
        uint256 initialExchangeRate = vault.getExchangeRate();

        // Warp time and accrue
        vm.warp(block.timestamp + timeDelta);
        vault.accrue();
        uint256 newExchangeRate = vault.getExchangeRate();

        // Exchange rate should be non-decreasing (truncation may keep it flat for small dt)
        assertGe(newExchangeRate, initialExchangeRate);

        // Preview withdraw should never give less than principal
        uint256 assetsWithInterest = vault.previewWithdraw(initialShares);
        assertGe(assetsWithInterest, depositAmount);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test maximum deposit amounts (within a practical bound)
    function testFuzz_MaxDeposit(uint256 amount) public {
        vm.assume(amount > 0);
        // Bound to a large but sane range so math doesn't overflow
        amount = bound(amount, 1, DEPOSIT_AMOUNT * 1000);

        // Mint enough tokens for large deposit
        vm.prank(owner);
        token.mint(user, amount);

        vm.startPrank(user);
        token.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);
        assertGt(shares, 0);
        assertEq(token.balanceOf(address(vault)), amount);

        vm.stopPrank();
    }

    /// @notice Deterministic dust test: configure high exchangeRate so tiny deposits revert with MINT_ZERO
    function test_DustDepositReverts() public {
        // Bump rate per second to push exchangeRate up fast
        vm.startPrank(owner);
        vault.setRatePerSecond(ratePerSecond * 1e9);
        vm.stopPrank();

        // Warp enough time so exchangeRate becomes huge, making 1 wei -> 0 shares
        vm.warp(block.timestamp + 365 days);
        vault.accrue();

        uint256 dust = 1; // 1 wei

        vm.startPrank(user);
        // Ensure user has at least dust and approval already set in setUp()
        vm.expectRevert("MINT_ZERO");
        vault.deposit(dust);
        vm.stopPrank();
    }
}
