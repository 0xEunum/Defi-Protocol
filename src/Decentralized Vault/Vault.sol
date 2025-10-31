// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is Ownable, ReentrancyGuard {
    IERC20 public immutable ASSET;

    // shares accounting
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    // exchangeRate: ASSET amount per 1 share, fixed point with 1e18 precision
    uint256 public exchangeRate; // starts at 1e18 = 1 ASSET per share
    uint256 public constant SCALE = 1e18;

    // interest rate as per-second multiplier increment in fixed-point
    // Example: for ~5% APR, ratePerSecond ~ 0.05 / (365*24*3600) in fixed point
    uint256 public ratePerSecond; // e.g., 1585489599180000 for small rates (1e18 base)

    uint256 public lastAccrualTimestamp;

    bool public paused;

    event Deposit(address indexed user, uint256 assetAmount, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 assetAmount, uint256 sharesBurned);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event Paused(bool isPaused);

    constructor(address _asset, uint256 _initialRatePerSecond) Ownable(msg.sender) {
        require(_asset != address(0), "ZERO_ASSET");
        ASSET = IERC20(_asset);
        exchangeRate = SCALE; // 1 ASSET per share initially
        ratePerSecond = _initialRatePerSecond;
        lastAccrualTimestamp = block.timestamp;
    }

    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /// @notice Accrue interest updating exchangeRate based on time delta
    function accrue() public {
        uint256 ts = block.timestamp;
        uint256 dt = ts - lastAccrualTimestamp;
        if (dt == 0) return;
        // linear approximation: exchangeRate += exchangeRate * ratePerSecond * dt / SCALE
        // exchangeRate = exchangeRate * (1 + ratePerSecond * dt / SCALE)
        // compute delta = exchangeRate * ratePerSecond * dt / SCALE
        uint256 delta = (exchangeRate * ratePerSecond * dt) / SCALE;
        exchangeRate = exchangeRate + delta;
        lastAccrualTimestamp = ts;
    }

    /// @notice Deposit `amount` tokens and receive shares
    function deposit(uint256 amount) external notPaused nonReentrant returns (uint256 sharesMinted) {
        require(amount > 0, "ZERO_AMOUNT");
        accrue();
        // shares = amount * SCALE / exchangeRate
        sharesMinted = (amount * SCALE) / exchangeRate;
        require(sharesMinted > 0, "MINT_ZERO");
        totalShares += sharesMinted;
        sharesOf[msg.sender] += sharesMinted;
        require(ASSET.transferFrom(msg.sender, address(this), amount), "TRANSFER_FAIL");
        emit Deposit(msg.sender, amount, sharesMinted);
    }

    /// @notice Withdraw `shareAmount` shares and receive underlying
    function withdrawAssest(uint256 shareAmount) public notPaused nonReentrant returns (uint256 assetsReturned) {
        require(shareAmount > 0, "ZERO_SHARES");
        require(sharesOf[msg.sender] >= shareAmount, "INSUFFICIENT_SHARES");
        accrue();
        assetsReturned = (shareAmount * exchangeRate) / SCALE;
        // update accounting
        sharesOf[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        require(ASSET.transfer(msg.sender, assetsReturned), "TRANSFER_FAIL");
        emit Withdraw(msg.sender, assetsReturned, shareAmount);
    }

    /// @notice Withdraw all shares
    function withdrawAll() external notPaused nonReentrant returns (uint256 assetsReturned) {
        uint256 s = sharesOf[msg.sender];
        require(s > 0, "NO_SHARES");
        assetsReturned = withdrawAssest(s);
    }

    /// @notice View function for user's current underlying assets (not modifying state)
    function previewWithdraw(uint256 shareAmount) external view returns (uint256) {
        return (shareAmount * exchangeRate) / SCALE;
    }

    /// @notice View function for how many shares minted for a given deposit (uses current exchangeRate, not accruing)
    function previewDeposit(uint256 amount) external view returns (uint256) {
        return (amount * SCALE) / exchangeRate;
    }

    /* -------------------- Admin functions -------------------- */

    function setRatePerSecond(uint256 newRate) external onlyOwner {
        accrue();
        emit RateUpdated(ratePerSecond, newRate);
        ratePerSecond = newRate;
    }

    function setPaused(bool isPaused) external onlyOwner {
        paused = isPaused;
        emit Paused(isPaused);
    }

    /// @notice rescue stuck ERC20s EXCEPT the ASSET token
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(ASSET), "NO_RESERVE_ASSET");
        IERC20(token).transfer(to, amount);
    }

    /// @notice Return assets balance of vault
    function totalAssets() external view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /// @notice Exchange rate getter (updates not allowed in view)
    function getExchangeRate() external view returns (uint256) {
        // note: not accruing to avoid state change in view
        return exchangeRate;
    }
}
