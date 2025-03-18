// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Futures {

    IERC20 public stableCoin;
    AggregatorV3Interface public priceFeed;
    address public admin;

    uint256 public constant MAX_LEVERAGE = 5; // 5x leverage
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 10; // 10%

    // Add fee variables
    uint256 public tradingFeeBps = 10; // 0.1% trading fee
    uint256 public accumulatedFees;

    enum PositionType { NONE, LONG, SHORT }

    struct Position {
        PositionType posType;
        uint256 margin;
        uint256 entryPrice;
        uint256 leverage;
        bool isOpen;
    }

    mapping(address => Position) public positions;

    // Add liquidity provider tracking
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;

    // Track total position sizes for counterparty balancing
    uint256 public totalLongSize;
    uint256 public totalShortSize;

    constructor(address _stableCoin, address _priceFeed) {
        stableCoin = IERC20(_stableCoin);
        priceFeed = AggregatorV3Interface(_priceFeed);
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    function getLatestPrice() public view returns (uint256) {
        (, int price, , ,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price) * 1e10; // Adjust to 18 decimals
    }

    // Add function for users to provide liquidity
    function provideLiquidity(uint256 amount) external {
        require(amount > 0, "Amount must be positive");

        // Transfer stablecoins from provider to contract
        stableCoin.transferFrom(msg.sender, address(this), amount);

        // Calculate shares based on current liquidity
        uint256 shares;
        uint256 contractBalance = stableCoin.balanceOf(address(this)) - accumulatedFees;

        if (totalLpShares == 0) {
            shares = amount;
        } else {
            // Proportional to existing shares
            shares = (amount * totalLpShares) / (contractBalance - amount);
        }

        // Update provider's shares
        lpShares[msg.sender] += shares;
        totalLpShares += shares;
    }

    // Add function to withdraw liquidity
    function withdrawLiquidity(uint256 shareAmount) external {
        require(lpShares[msg.sender] >= shareAmount, "Not enough shares");

        uint256 contractBalance = stableCoin.balanceOf(address(this)) - accumulatedFees;
        uint256 withdrawAmount = (shareAmount * contractBalance) / totalLpShares;

        // Update shares
        lpShares[msg.sender] -= shareAmount;
        totalLpShares -= shareAmount;

        // Transfer stablecoins to provider
        stableCoin.transfer(msg.sender, withdrawAmount);
    }

    // Modify openPosition to include fees and tracking
    function openPosition(uint256 _margin, uint256 _leverage, bool _isLong) external {
        require(positions[msg.sender].isOpen == false, "Position already open");
        require(_leverage > 0 && _leverage <= MAX_LEVERAGE, "Invalid leverage");
        require(_margin > 0, "Margin must be > 0");

        // Calculate position size
        uint256 positionSize = _margin * _leverage;

        // Check if there's enough liquidity in the contract
        uint256 availableLiquidity = stableCoin.balanceOf(address(this)) - accumulatedFees;
        require(availableLiquidity >= _margin, "Not enough liquidity");

        // Calculate and take fee
        uint256 fee = (_margin * tradingFeeBps) / 10000;
        uint256 actualMargin = _margin - fee;
        accumulatedFees += fee;

        // Transfer margin from user to contract
        stableCoin.transferFrom(msg.sender, address(this), _margin);

        uint256 price = getLatestPrice();

        positions[msg.sender] = Position({
            posType: _isLong ? PositionType.LONG : PositionType.SHORT,
            margin: actualMargin,
            entryPrice: price,
            leverage: _leverage,
            isOpen: true
        });

        // Update total position sizes
        if (_isLong) {
            totalLongSize += positionSize;
        } else {
            totalShortSize += positionSize;
        }
    }

    function getPositionValue(Position memory pos, uint256 currentPrice) public pure returns (int256) {
        int256 priceDiff = int256(currentPrice) - int256(pos.entryPrice);
        int256 leveragedDiff = (priceDiff * int256(pos.margin) * int256(pos.leverage)) / int256(pos.entryPrice);
        return (pos.posType == PositionType.LONG) ? leveragedDiff : -leveragedDiff;
    }

    function checkLiquidation(address trader) public view returns (bool) {
        Position memory pos = positions[trader];
        require(pos.isOpen, "No open position");

        uint256 price = getLatestPrice();
        int256 pnl = getPositionValue(pos, price);
        int256 equity = int256(pos.margin) + pnl;

        uint256 maintenanceMargin = (pos.margin * MAINTENANCE_MARGIN_RATIO) / 100;

        return equity < int256(maintenanceMargin);
    }

    // Modify closePosition to update position tracking
    function closePosition() external {
        Position memory pos = positions[msg.sender];
        require(pos.isOpen, "No open position");

        uint256 price = getLatestPrice();
        int256 pnl = getPositionValue(pos, price);
        int256 total = int256(pos.margin) + pnl;

        // Update total position sizes
        uint256 positionSize = pos.margin * pos.leverage;
        if (pos.posType == PositionType.LONG) {
            totalLongSize -= positionSize;
        } else {
            totalShortSize -= positionSize;
        }

        // Delete position first to prevent reentrancy
        delete positions[msg.sender];

        // If positive balance, transfer to user
        if (total > 0) {
            stableCoin.transfer(msg.sender, uint256(total));
        }
    }

    function liquidate(address trader) external {
        require(checkLiquidation(trader), "Position not liquidatable");

        // Update total position sizes
        Position memory pos = positions[trader];
        uint256 positionSize = pos.margin * pos.leverage;
        if (pos.posType == PositionType.LONG) {
            totalLongSize -= positionSize;
        } else {
            totalShortSize -= positionSize;
        }

        // Take liquidation fee (could go to liquidator or platform)
        uint256 liquidationFee = (pos.margin * 5) / 100; // 5% fee
        accumulatedFees += liquidationFee;

        delete positions[trader];
        // In real system, liquidator might get a reward here
    }

    // Add function to distribute fees to LPs
    function distributeFees() external onlyAdmin {
        require(accumulatedFees > 0, "No fees to distribute");
        require(totalLpShares > 0, "No liquidity providers");

        // Admin takes 20% of fees
        uint256 adminFee = (accumulatedFees * 20) / 100;
        uint256 lpFee = accumulatedFees - adminFee;

        // Send admin fee
        stableCoin.transfer(admin, adminFee);

        // Add LP fees to pool (implicitly distributed by share value)
        accumulatedFees = 0;
    }

    function withdrawFees(uint256 amount) external onlyAdmin {
        require(amount <= accumulatedFees, "Amount exceeds available fees");
        accumulatedFees -= amount;
        stableCoin.transfer(admin, amount);
    }

    // Add view function to get platform stats
    function getPlatformStats() external view returns (
        uint256 longSize,
        uint256 shortSize,
        uint256 availableLiquidity,
        uint256 fees
    ) {
        return (
            totalLongSize,
            totalShortSize,
            stableCoin.balanceOf(address(this)) - accumulatedFees,
            accumulatedFees
        );
    }
}