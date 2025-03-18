// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @notice A simplified pool-based, cash-settled European options contract.
 * Liquidity providers deposit stablecoins, and option buyers purchase calls or puts.
 * At expiration, buyer may exercise (if in-the-money) to receive the payoff in stablecoins.
 */
contract Options {
    IERC20 public stable;
    AggregatorV3Interface public priceFeed;

    address public admin;
    uint256 public totalLiquidity;      // total stablecoins in pool (unlocked + locked)
    uint256 public lockedCollateral;    // portion of totalLiquidity locked as collateral

    // Liquidity provider tracking
    mapping(address => uint256) public lpShares;
    uint256 public totalLpShares;

    enum OptionType { CALL, PUT }

    struct Option {
        address buyer;
        OptionType optType;
        uint256 strike;      // strike price (1e18 decimals)
        uint256 expiry;      // unix timestamp
        uint256 amount;      // size of option (number of "units"), for payoff calculation
        uint256 premiumPaid; // stablecoins paid as premium
        uint256 collateral;  // maximum payoff locked
        bool isExercised;
        bool isActive;
    }

    // Store all options
    Option[] public options;

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

    constructor(address _stable, address _priceFeed) {
        stable = IERC20(_stable);
        priceFeed = AggregatorV3Interface(_priceFeed);
        admin = msg.sender;
    }

    //--------------------------------------------------------------------------------
    // 1) LIQUIDITY PROVISION
    //--------------------------------------------------------------------------------

    /**
     * @notice Provide stablecoins as liquidity to the pool in exchange for LP shares.
     */
    function provideLiquidity(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        // Transfer stables to contract
        stable.transferFrom(msg.sender, address(this), amount);

        // Mint shares
        uint256 shares;
        if (totalLpShares == 0) {
            shares = amount;
        } else {
            // shares minted proportionally to deposit/totalLiquidity
            shares = (amount * totalLpShares) / (totalLiquidity);
        }

        lpShares[msg.sender] += shares;
        totalLpShares += shares;
        totalLiquidity += amount;

        emit ProvidedLiquidity(msg.sender, amount, shares);
    }

    /**
     * @notice Withdraw stables by burning LP shares. Pro rata share of pool’s free (unlocked) liquidity is returned.
     */
    function withdrawLiquidity(uint256 shareAmount) external {
        require(lpShares[msg.sender] >= shareAmount, "Not enough shares");
        // The fraction of the entire pool that these shares represent
        uint256 fraction = (shareAmount * 1e18) / totalLpShares;

        // Pro rata portion of total liquidity
        uint256 poolPortion = (fraction * totalLiquidity) / 1e18;

        // But must ensure we don’t withdraw lockedCollateral
        uint256 unlocked = totalLiquidity - lockedCollateral;
        require(poolPortion <= unlocked, "Not enough unlocked liquidity to withdraw");

        // Burn shares
        lpShares[msg.sender] -= shareAmount;
        totalLpShares -= shareAmount;

        // Adjust total liquidity
        totalLiquidity -= poolPortion;

        // Transfer stables out
        stable.transfer(msg.sender, poolPortion);

        emit WithdrewLiquidity(msg.sender, shareAmount, poolPortion);
    }

    //--------------------------------------------------------------------------------
    // 2) BUYING OPTIONS
    //--------------------------------------------------------------------------------

    /**
     * @notice Buy a European call or put option with a certain strike and expiry.
     * This function calculates a simplistic premium and locks collateral in the pool.
     * @param optType 0 for CALL, 1 for PUT
     * @param strike Price at which option can be settled (1e18 decimals)
     * @param expiry Unix time after which option can be exercised
     * @param amount Number of units to buy. (Used to compute payoff.)
     */
    function buyOption(
        OptionType optType,
        uint256 strike,
        uint256 expiry,
        uint256 amount
    ) external {
        require(expiry > block.timestamp, "Expiry must be in future");
        require(amount > 0, "Amount must be > 0");
        require(strike > 0, "Strike must be > 0");

        // Premium calculation with proper scaling
        // We know both strike and amount are scaled by 1e18
        // To calculate 2% of strike*amount, we need to:
        // 1. Divide amount by 1e18 to get back to normal units
        // 2. Calculate strike * (amount/1e18) * 0.02
        uint256 normalizedAmount = amount / 1e18;
        if (normalizedAmount == 0) normalizedAmount = 1;  // Ensure minimum of 1 unit
        uint256 premium = (strike * normalizedAmount * 200) / 10000;

        // The rest of the function stays the same
        uint256 collateralNeeded = strike * amount;

        uint256 unlocked = totalLiquidity - lockedCollateral;
        require(unlocked >= collateralNeeded, "Not enough liquidity to cover max payoff");

        stable.transferFrom(msg.sender, address(this), premium);

        lockedCollateral += collateralNeeded;

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

    //--------------------------------------------------------------------------------
    // 3) EXERCISE OR EXPIRE
    //--------------------------------------------------------------------------------

    /**
     * @notice Exercise option if in-the-money AND time >= expiry.
     * European style => can only exercise on or after expiry.
     */
    function exerciseOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option not active");
        require(opt.buyer == msg.sender, "Not your option");
        require(block.timestamp >= opt.expiry, "Not expired yet");

        // Determine if in the money
        uint256 currentPrice = getLatestPrice();

        uint256 payoff;
        if (opt.optType == OptionType.CALL && currentPrice > opt.strike) {
            // FIX HERE: Normalize the calculation by dividing amount by 1e18 first
            // payoff = (currentPrice - strike) * normalizedAmount
            uint256 normalizedAmount = opt.amount / 1e18;
            if (normalizedAmount == 0) normalizedAmount = 1;  // Ensure minimum of 1 unit
            payoff = (currentPrice - opt.strike) * normalizedAmount;
        } else if (opt.optType == OptionType.PUT && currentPrice < opt.strike) {
            // FIX HERE: Same fix for PUT options
            uint256 normalizedAmount = opt.amount / 1e18;
            if (normalizedAmount == 0) normalizedAmount = 1;  // Ensure minimum of 1 unit
            payoff = (opt.strike - currentPrice) * normalizedAmount;
        } else {
            payoff = 0;
        }

        opt.isActive = false;
        opt.isExercised = true;

        if (payoff > 0) {
            // Bounded by the locked collateral
            if (payoff > opt.collateral) {
                payoff = opt.collateral;
            }

            // The pool pays the buyer
            stable.transfer(msg.sender, payoff);

            // Release leftover locked collateral
            lockedCollateral -= opt.collateral;

            // But we only effectively used "payoff" from that locked portion,
            // the rest is still in the pool
            // However, totalLiquidity remains the same; we effectively "spent" payoff out.
        } else {
            // No payoff => entire collateral is released
            lockedCollateral -= opt.collateral;
        }

        emit OptionExercised(optionId, payoff);
    }

    /**
     * @notice If option is not in-the-money at expiry, or buyer fails to exercise,
     * anyone can call expireOption after expiry to release collateral.
     */
    function expireOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option not active");
        require(block.timestamp >= opt.expiry, "Not expired yet");

        // Check if in the money
        uint256 currentPrice = getLatestPrice();
        bool inTheMoney;
        if (opt.optType == OptionType.CALL) {
            inTheMoney = (currentPrice > opt.strike);
        } else {
            inTheMoney = (currentPrice < opt.strike);
        }

        // If in the money, the buyer should have exercised
        // But if they didn't, it expires worthless to them.
        // Collateral is fully released
        opt.isActive = false;
        opt.isExercised = false;

        lockedCollateral -= opt.collateral;

        emit OptionExpiredWorthless(optionId);
    }

    //--------------------------------------------------------------------------------
    // 4) PRICE FEED + ADMIN
    //--------------------------------------------------------------------------------

    /**
     * @notice Retrieve latest chainlink price, scaled to 1e18 if aggregator is 8 decimals
     */
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        // If aggregator has 8 decimals, multiply by 1e10 => 18 decimals total
        return uint256(price) * 1e10;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    /**
     * @notice Admin can update aggregator or stable token if needed
     */
    function updatePriceFeed(address newFeed) external onlyAdmin {
        priceFeed = AggregatorV3Interface(newFeed);
    }
}
