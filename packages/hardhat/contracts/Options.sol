// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title American-Style Options (Proof of Concept)
 * @notice A pool-based, cash-settled American options contract.
 * Liquidity providers deposit stablecoins, and option buyers purchase calls or puts.
 * Buyer may exercise at any time up to expiry if in-the-money.
 */
contract Options {
    // ------------------------------------------------------------------------
    // STATE VARIABLES
    // ------------------------------------------------------------------------
    IERC20 public stable;                      // The stablecoin (ERC20) used for premiums & settlements
    AggregatorV3Interface public priceFeed;    // Chainlink price feed for the underlying asset

    address public admin;                      // Contract admin
    uint256 public totalLiquidity;             // Total stablecoins in pool (unlocked + locked)
    uint256 public lockedCollateral;           // Portion of totalLiquidity locked as collateral

    // LP shares
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;

    // Option types
    enum OptionType { CALL, PUT }

    // Represents an option purchased by a user
    struct Option {
        address buyer;
        OptionType optType;
        uint256 strike;      // strike price (scaled 1e18)
        uint256 expiry;      // unix timestamp of expiry
        uint256 amount;      // quantity (scaled 1e18)
        uint256 premiumPaid; // stablecoins paid as premium
        uint256 collateral;  // maximum payoff locked
        bool isExercised;
        bool isActive;
    }

    // All options created by buyers
    Option[] public options;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------
    event ProvidedLiquidity(address indexed provider, uint256 amount, uint256 shares);
    event WithdrewLiquidity(address indexed provider, uint256 shareAmount, uint256 stableOut);
    event OptionPurchased(
        uint256 indexed optionId,
        address indexed buyer,
        OptionType optType,
        uint256 strike,
        uint256 expiry,
        uint256 amount,
        uint256 premium,
        uint256 collateralLocked
    );
    event OptionExercised(uint256 indexed optionId, uint256 payout);
    event OptionExpiredWorthless(uint256 indexed optionId);

    // ------------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------------
    constructor(address _stable, address _priceFeed) {
        stable = IERC20(_stable);
        priceFeed = AggregatorV3Interface(_priceFeed);
        admin = msg.sender;
    }

    // ------------------------------------------------------------------------
    // 1) LIQUIDITY PROVISION
    // ------------------------------------------------------------------------

    /**
     * @notice Provide stablecoins as liquidity to the pool in exchange for LP shares.
     */
    function provideLiquidity(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        // Transfer stables to this contract
        stable.transferFrom(msg.sender, address(this), amount);

        // Mint LP shares
        uint256 shares;
        if (totalLpShares == 0) {
            // If first time providing, 1 share = 1 stablecoin
            shares = amount;
        } else {
            // Otherwise, proportionally to deposit vs existing liquidity
            shares = (amount * totalLpShares) / totalLiquidity;
        }

        lpShares[msg.sender] += shares;
        totalLpShares += shares;
        totalLiquidity += amount;

        emit ProvidedLiquidity(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw stables by burning LP shares. A pro rata share of the pool’s
     * free (unlocked) liquidity is returned.
     */
    function withdrawLiquidity(uint256 shareAmount) external {
        require(lpShares[msg.sender] >= shareAmount, "Not enough shares");

        // Fraction of total LP
        uint256 fraction = (shareAmount * 1e18) / totalLpShares;

        // Amount of liquidity those shares represent
        uint256 poolPortion = (fraction * totalLiquidity) / 1e18;

        // Cannot withdraw locked collateral
        uint256 unlocked = totalLiquidity - lockedCollateral;
        require(poolPortion <= unlocked, "Not enough unlocked liquidity");

        // Burn shares
        lpShares[msg.sender] -= shareAmount;
        totalLpShares -= shareAmount;

        // Update totals
        totalLiquidity -= poolPortion;

        // Transfer stables to LP
        stable.transfer(msg.sender, poolPortion);

        emit WithdrewLiquidity(msg.sender, shareAmount, poolPortion);
    }

    // ------------------------------------------------------------------------
    // 2) BUYING OPTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Buy an American call or put option with a certain strike and expiry.
     * Locks collateral in the pool equal to max possible payoff, and charges a simple premium.
     * @param optType 0 for CALL, 1 for PUT
     * @param strike Price at which option can be settled (1e18 scaling)
     * @param expiry Unix time by which the option expires
     * @param amount Number of units (1e18 scaling)
     */
    function buyOption(
        OptionType optType,
        uint256 strike,
        uint256 expiry,
        uint256 amount
    ) external {
        require(expiry > block.timestamp, "Expiry must be future");
        require(amount > 0, "Amount must be > 0");
        require(strike > 0, "Strike must be > 0");

        // Simple 2% premium on (strike * amount)
        // Both strike and amount are 1e18 scaled, so we handle that carefully:
        //   normalizedAmount = amount / 1e18
        //   premium = 2% * strike * normalizedAmount
        uint256 normalizedAmount = amount / 1e18;
        if (normalizedAmount == 0) {
            // Avoid losing all precision if amount < 1e18
            normalizedAmount = 1;
        }
        uint256 premium = (strike * normalizedAmount * 200) / 10000;

        // Full collateral is strike * amount for calls, or strike * amount for puts
        // (Given it's a cash-settled payoff with max (strike - price, 0) or vice versa.)
        uint256 collateralNeeded = strike * amount;

        // Check pool has enough free liquidity
        uint256 unlocked = totalLiquidity - lockedCollateral;
        require(unlocked >= collateralNeeded, "Not enough pool liquidity");

        // Transfer premium from buyer
        stable.transferFrom(msg.sender, address(this), premium);

        // Lock collateral in the pool
        lockedCollateral += collateralNeeded;

        // Create Option record
        options.push(
            Option({
                buyer: msg.sender,
                optType: optType,
                strike: strike,
                expiry: expiry,
                amount: amount,
                premiumPaid: premium,
                collateral: collateralNeeded,
                isExercised: false,
                isActive: true
            })
        );
        uint256 optionId = options.length - 1;

        emit OptionPurchased(
            optionId,
            msg.sender,
            optType,
            strike,
            expiry,
            amount,
            premium,
            collateralNeeded
        );
    }

    // ------------------------------------------------------------------------
    // 3) EXERCISE (American-style) OR EXPIRE
    // ------------------------------------------------------------------------

    /**
     * @notice For American-style: The buyer can exercise at any time <= expiry if in-the-money.
     */
    function exerciseOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option not active");
        require(opt.buyer == msg.sender, "Not your option");
        require(block.timestamp <= opt.expiry, "Option expired");

        // Determine if in the money
        uint256 currentPrice = getLatestPrice();
        uint256 payoff = 0;

        if (opt.optType == OptionType.CALL && currentPrice > opt.strike) {
            uint256 normalizedAmount = opt.amount / 1e18;
            if (normalizedAmount == 0) {
                normalizedAmount = 1;
            }
            payoff = (currentPrice - opt.strike) * normalizedAmount;
        }
        else if (opt.optType == OptionType.PUT && currentPrice < opt.strike) {
            uint256 normalizedAmount = opt.amount / 1e18;
            if (normalizedAmount == 0) {
                normalizedAmount = 1;
            }
            payoff = (opt.strike - currentPrice) * normalizedAmount;
        }

        opt.isActive = false;
        opt.isExercised = true;

        if (payoff > 0) {
            // Do not exceed locked collateral
            if (payoff > opt.collateral) {
                payoff = opt.collateral;
            }
            stable.transfer(msg.sender, payoff);
            lockedCollateral -= opt.collateral;
        } else {
            // No payoff => entire collateral is freed
            lockedCollateral -= opt.collateral;
        }

        emit OptionExercised(optionId, payoff);
    }

    /**
     * @notice If option was never exercised and is now past expiry, anyone can call expireOption
     * to release the locked collateral back to the pool.
     */
    function expireOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option not active");
        require(block.timestamp > opt.expiry, "Not past expiry yet");

        // If buyer didn't exercise in time, the option is worthless.
        opt.isActive = false;
        opt.isExercised = false;

        // Free the collateral
        lockedCollateral -= opt.collateral;

        emit OptionExpiredWorthless(optionId);
    }

    // ------------------------------------------------------------------------
    // 4) PRICE FEED + ADMIN
    // ------------------------------------------------------------------------

    /**
     * @notice Retrieve the latest Chainlink price, scaled to 1e18 if aggregator is 8 decimals.
     */
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid feed price");
        // e.g. if aggregator has 8 decimals, multiply by 1e10 => 18 decimals
        return uint256(price) * 1e10;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    /**
     * @notice Admin can update the Chainlink price feed if needed.
     */
    function updatePriceFeed(address newFeed) external onlyAdmin {
        priceFeed = AggregatorV3Interface(newFeed);
    }
}
