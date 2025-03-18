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

    enum PositionType { NONE, LONG, SHORT }

    struct Position {
        PositionType posType;
        uint256 margin; 
        uint256 entryPrice; 
        uint256 leverage;
        bool isOpen;
    }

    mapping(address => Position) public positions;

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

    function openPosition(uint256 _margin, uint256 _leverage, bool _isLong) external {
        require(positions[msg.sender].isOpen == false, "Position already open");
        require(_leverage > 0 && _leverage <= MAX_LEVERAGE, "Invalid leverage");
        require(_margin > 0, "Margin must be > 0");

        stableCoin.transferFrom(msg.sender, address(this), _margin);

        uint256 price = getLatestPrice();

        positions[msg.sender] = Position({
            posType: _isLong ? PositionType.LONG : PositionType.SHORT,
            margin: _margin,
            entryPrice: price,
            leverage: _leverage,
            isOpen: true
        });
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

    function closePosition() external {
        Position memory pos = positions[msg.sender];
        require(pos.isOpen, "No open position");

        uint256 price = getLatestPrice();
        int256 pnl = getPositionValue(pos, price);
        int256 total = int256(pos.margin) + pnl;

        require(total >= 0, "Negative equity");

        stableCoin.transfer(msg.sender, uint256(total));

        delete positions[msg.sender];
    }

    function liquidate(address trader) external {
        require(checkLiquidation(trader), "Position not liquidatable");

        delete positions[trader];
        // In real system, liquidator might get a reward here
    }

    function withdrawFees(uint256 amount) external onlyAdmin {
        stableCoin.transfer(admin, amount);
    }
}
