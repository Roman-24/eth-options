// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title SimplePhysicallySettledOptions
 * @notice A minimal example allowing both calls and puts on ETH, physically settled with stablecoins.
 *
 * Liquidity providers deposit ETH as collateral for calls, and stablecoins as collateral for puts.
 * Buyers pay a premium in stable to buy a call or put. The contract locks ETH or stable as needed.
 * At exercise:
 * - For calls, buyer pays strike * amount in stable => receives ETH.
 * - For puts, buyer sends ETH => receives strike * amount in stable.
 */
contract PhysicallySettledOptions {
    // ---------------------------
    // Configuration
    // ---------------------------
    IERC20 public immutable stable;                 // e.g. USDC
    AggregatorV3Interface public immutable priceFeed; // For ETH/USD data (8 decimals typical)

    address public admin;

    // ---------------------------
    // Collateral Pools
    // ---------------------------
    uint256 public totalEthCollateral;  // total ETH from LPs for calls
    uint256 public totalStableCollateral; // total stable from LPs for puts

    uint256 public lockedEth;          // portion of totalEthCollateral locked for sold calls
    uint256 public lockedStable;       // portion of totalStableCollateral locked for sold puts

    // Mappings if you want to track per-user deposits
    mapping(address => uint256) public ethCollateralOf;
    mapping(address => uint256) public stableCollateralOf;

    // ---------------------------
    // Options
    // ---------------------------
    enum OptionType { CALL, PUT }
    enum OptionState { ACTIVE, EXERCISED, EXPIRED }

    struct Option {
        address buyer;
        OptionType optionType;
        uint256 strike;       // 1e18 decimals, e.g. 1,500 => $1,500/ETH
        uint256 expiry;       // unix timestamp
        uint256 amount;       // how many "ETH units" the option covers
        uint256 premium;      // stable paid as premium
        OptionState state;    // ACTIVE, EXERCISED, EXPIRED
        bool isActive;        // convenient boolean
    }

    Option[] public options;

    // ---------------------------
    // Events
    // ---------------------------
    event ProvidedEthCollateral(address indexed provider, uint256 ethAmount);
    event ProvidedStableCollateral(address indexed provider, uint256 stableAmount);
    event WithdrawnEthCollateral(address indexed provider, uint256 ethAmount);
    event WithdrawnStableCollateral(address indexed provider, uint256 stableAmount);

    event OptionPurchased(
        uint256 indexed optionId,
        address indexed buyer,
        OptionType optionType,
        uint256 strike,
        uint256 expiry,
        uint256 amount,
        uint256 premium
    );
    event OptionExercised(uint256 indexed optionId, uint256 stableInOrOut, uint256 ethInOrOut);
    event OptionExpiredWorthless(uint256 indexed optionId);

    // ---------------------------
    // Constructor
    // ---------------------------
    constructor(address _stable, address _priceFeed) {
        stable = IERC20(_stable);
        priceFeed = AggregatorV3Interface(_priceFeed);
        admin = msg.sender;
    }

    // ---------------------------
    // Liquidity Provision
    // ---------------------------

    /**
     * @notice Provide ETH collateral to back call options.
     * In a real system, you'd likely have LP shares or track user ownership in a more sophisticated way.
     */
    function provideEthCollateral() external payable {
        require(msg.value > 0, "No ETH sent");
        ethCollateralOf[msg.sender] += msg.value;
        totalEthCollateral += msg.value;
        emit ProvidedEthCollateral(msg.sender, msg.value);
    }

    /**
     * @notice Provide stable collateral to back put options.
     */
    function provideStableCollateral(uint256 amount) external {
        require(amount > 0, "No stable sent");
        stable.transferFrom(msg.sender, address(this), amount);
        stableCollateralOf[msg.sender] += amount;
        totalStableCollateral += amount;
        emit ProvidedStableCollateral(msg.sender, amount);
    }

    /**
     * @notice Withdraw free ETH (i.e. not locked for sold calls).
     * This is simplistic: it checks if the user has enough unencumbered ETH in the contract.
     */
    function withdrawEthCollateral(uint256 amount) external {
        require(ethCollateralOf[msg.sender] >= amount, "Not enough ETH in your deposit");
        // In a truly shared pool, you'd do proportional logic.
        // For simplicity, we assume each user’s deposit can be locked individually.
        // This example does not fully track which user’s ETH is locked.
        // We'll just trust the admin or handle it with "the user can’t withdraw if locked."
        // That would require advanced tracking or a less naive approach.
        ethCollateralOf[msg.sender] -= amount;
        totalEthCollateral -= amount;
        payable(msg.sender).transfer(amount);
        emit WithdrawnEthCollateral(msg.sender, amount);
    }

    /**
     * @notice Withdraw free stable (i.e. not locked for sold puts).
     */
    function withdrawStableCollateral(uint256 amount) external {
        require(stableCollateralOf[msg.sender] >= amount, "Not enough stable in your deposit");
        // Same naive approach as with ETH
        stableCollateralOf[msg.sender] -= amount;
        totalStableCollateral -= amount;
        stable.transfer(msg.sender, amount);
        emit WithdrawnStableCollateral(msg.sender, amount);
    }

    // ---------------------------
    // Buying an Option
    // ---------------------------
    /**
     * @notice Buy a physically-settled call or put on ETH.
     * - For calls: the contract must lock ETH as the worst-case that buyer can purchase all `amount`.
     * - For puts: the contract must lock stable as the worst-case that buyer can sell all `amount` at strike.
     *
     * For example, if it's a CALL with `amount = 1.0 ETH`, we must lock 1.0 ETH from the free ETH pool.
     * If it's a PUT with `amount = 1.0 ETH` at strike=1500, we must lock 1500 stable in the free stable pool.
     *
     * @param optType 0=CALL, 1=PUT
     * @param strike  Strike price in 1e18 decimals
     * @param expiry  Unix time after which the buyer can exercise
     * @param amount  How many "ETH units" does this option cover, stored in 1e18 if you want fractional
     */
    function buyOption(
        OptionType optType,
        uint256 strike,
        uint256 expiry,
        uint256 amount
    ) external {
        require(expiry > block.timestamp, "Expiry must be in the future");
        require(strike > 0, "Strike=0 not allowed");
        require(amount > 0, "Amount=0 not allowed");

        // For demonstration, a naive formula: premium = 3% of notional
        // - For calls: notional = strike * amount
        // - For puts: also strike * amount
        // cost in stable = (strike * amount / 1e18) * 3%
        // Because strike & amount might be 1e18 each. We do careful math:
        uint256 notional = (strike * amount) / 1e18;
        uint256 premium = (notional * 300) / 10000;  // 3% = 300 bps

        // Buyer pays premium in stable
        stable.transferFrom(msg.sender, address(this), premium);

        // Lock collateral
        if (optType == OptionType.CALL) {
            // Must lock `amount` of ETH
            uint256 freeEth = totalEthCollateral - lockedEth;
            require(freeEth >= amount, "Not enough free ETH collateral");
            lockedEth += amount;
        } else {
            // Put => must lock strike * amount in stable
            // stable locked = (strike * amount)/1e18
            uint256 stableRequired = notional;
            uint256 freeStable = totalStableCollateral - lockedStable;
            require(freeStable >= stableRequired, "Not enough free stable collateral");
            lockedStable += stableRequired;
        }

        // Create the option
        Option memory opt = Option({
            buyer: msg.sender,
            optionType: optType,
            strike: strike,
            expiry: expiry,
            amount: amount,
            premium: premium,
            state: OptionState.ACTIVE,
            isActive: true
        });

        options.push(opt);
        uint256 optionId = options.length - 1;

        emit OptionPurchased(optionId, msg.sender, optType, strike, expiry, amount, premium);
    }

    // ---------------------------
    // Exercise or Expire
    // ---------------------------

    /**
     * @notice Exercise an option if it's in-the-money at or after expiry.
     * - CALL: buyer pays strike * amount in stable, receives `amount` ETH.
     * - PUT: buyer sends `amount` ETH, receives strike * amount in stable.
     *
     * The contract checks the spot price to see if it’s in the money.
     * But for physically settled, the buyer *can* still exercise even if it’s not in the money
     * (though that’d be irrational). You can add an extra check for “must be ITM,” or let the buyer do as they wish.
     *
     * In real finance, European style means exercise *after* expiry. American style could be any time <= expiry.
     * This example keeps it simple: exercise if block.timestamp >= expiry.
     */
    function exerciseOption(uint256 optionId) external payable {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option is not active");
        require(opt.buyer == msg.sender, "Not your option");
        require(block.timestamp >= opt.expiry, "Not at or past expiry");
        require(opt.state == OptionState.ACTIVE, "Already exercised/expired");

        opt.isActive = false;
        opt.state = OptionState.EXERCISED;

        // For physically settled calls:
        //  - The buyer sends stable = strike*amount
        //  - The contract sends them `amount` ETH
        // For physically settled puts:
        //  - The buyer sends `amount` ETH
        //  - The contract sends them strike*amount in stable

        // We do *no spot price check* => buyer can do it if they want.
        // But a rational buyer only exercises if beneficial.
        // They might not if out-of-the-money.

        if (opt.optionType == OptionType.CALL) {
            // Buyer pays (strike * amount / 1e18) stable to the contract
            uint256 costStable = (opt.strike * opt.amount) / 1e18;
            stable.transferFrom(msg.sender, address(this), costStable);

            // Contract sends them `amount` ETH
            // If "amount" is in 1e18 representing e.g. 1 ETH => 1e18
            // That is already the actual Wei.
            // So we do a direct .transfer(amount).
            // Make sure your `amount` is correct in units for storing "1.0 ETH" as 1e18 Wei.
            uint256 ethWei = opt.amount;
            lockedEth -= ethWei; // free up that locked portion
            payable(msg.sender).transfer(ethWei);

            emit OptionExercised(optionId, costStable, ethWei);
        } else {
            // PUT => user sends ETH
            // They get stable = strike * amount / 1e18
            uint256 stableOut = (opt.strike * opt.amount) / 1e18;
            // The user must have sent EXACTLY `opt.amount` ETH in msg.value
            // or we can read from `msg.value`
            require(msg.value == opt.amount, "Must send the exact amount of ETH to sell");

            // We pay them stable
            lockedStable -= stableOut;
            stable.transfer(msg.sender, stableOut);

            emit OptionExercised(optionId, stableOut, opt.amount);
        }
    }

    /**
     * @notice If the option is not exercised, or it’s worthless,
     * anyone can call expireOption() after expiry to free the locked collateral.
     */
    function expireOption(uint256 optionId) external {
        Option storage opt = options[optionId];
        require(opt.isActive, "Option not active or already exercised");
        require(block.timestamp >= opt.expiry, "Not yet expired");
        require(opt.state == OptionState.ACTIVE, "Already exercised/expired");
        // If buyer fails to exercise, it expires worthless for them,
        // but we still release the locked collateral.

        opt.isActive = false;
        opt.state = OptionState.EXPIRED;

        if (opt.optionType == OptionType.CALL) {
            // Release locked ETH
            lockedEth -= opt.amount;
        } else {
            // Release locked stable
            uint256 stableOut = (opt.strike * opt.amount) / 1e18;
            lockedStable -= stableOut;
        }

        emit OptionExpiredWorthless(optionId);
    }

    // ---------------------------
    // Price Feed
    // ---------------------------
    /**
     * @notice Return the latest ETH/USD price in 1e18 decimals
     */
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed");
        // aggregator typically has 8 decimals => multiply by 1e10 => 1e18
        return uint256(price) * 1e10;
    }

    // ---------------------------
    // Admin
    // ---------------------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    function updatePriceFeed(address newFeed) external onlyAdmin {
        // If you want to be able to upgrade the feed
        // or just remove if you want immutability
        revert("Not implemented in this example");
    }
}
