# American-Style Options (Pool-Based) – Business Overview

This document provides a **business-level** explanation of an American-style options prototype built on a pooled liquidity model. The contract is written in Solidity, but these notes avoid technical details and focus on the **financial concept**.

---

## 1. Purpose

This contract allows individuals (Liquidity Providers) to deposit stablecoins into a shared pool. **Option Buyers** can then purchase call or put options on an underlying asset price (as reported by a price feed). Because the options are **American-style**, buyers can exercise at any time **up to** the option’s expiry date if the option is profitable.

---

## 2. Key Participants

### 2.1 Liquidity Providers (LPs)
- **Role**: Supply stablecoins to the pool.
- **Reason**: Earn premiums from option buyers, since all premiums go into the pool.
- **Mechanism**:
    - Deposit stablecoins → Receive “LP shares” that represent a fraction of the pool.
    - Withdraw their unlocked portion of the pool’s liquidity at any time.

### 2.2 Option Buyers
- **Role**: Purchase an option (call or put) for a fixed premium.
- **Reason**: Gain the right to collect a payoff if the option becomes profitable (i.e., “in-the-money”).
- **Mechanism**:
    - Pay a premium (in stablecoins) to buy an option.
    - If profitable before expiry, exercise immediately and receive a cash payoff from the pool.

### 2.3 Administrator
- **Role**: Deploys the contract, can update the price feed address.
- **Reason**: Maintain the correctness of the price feed (e.g., switching to a new Chainlink feed).
- **Mechanism**:
    - Does **not** control user funds; only can replace the feed contract if needed.

---

## 3. How It Works

1. **Providing Liquidity**
    - LPs send stablecoins to the contract, which in turn issues LP shares.
    - The more you deposit relative to the total pool, the larger your share percentage.
    - Your deposit contributes to the pool that will later pay out any winning options.

2. **Buying an Option**
    - An option buyer chooses whether it’s a **call** (benefits if price goes **above** strike) or a **put** (benefits if price goes **below** strike).
    - They specify a “strike price,” the expiry date, and how many units they want.
    - A **premium** is calculated as a small percentage (2% in this demo) of the notional value. The buyer pays this premium, which goes into the pool.
    - The contract locks enough collateral to cover the worst-case payout scenario for that option.

3. **Exercising (American Style)**
    - The buyer can exercise **any time** up to expiry if the option is “in-the-money.”
        - **Call**: If the market price is above the strike, the payoff is `(market price – strike) * number of units.`
        - **Put**: If the market price is below the strike, the payoff is `(strike – market price) * number of units.`
    - Once exercised, the contract pays the buyer’s profit (capped by the locked collateral).
    - Any unused collateral from that option is reclassified as “unlocked” liquidity for the pool.

4. **Expiry**
    - If the buyer does **not** exercise on time, or the option never goes in-the-money, anyone can call a function that marks it “expired worthless.”
    - At that point, all the collateral locked for that option is returned to the general liquidity pool.

5. **Withdrawing Liquidity**
    - Because some liquidity is “locked” as collateral, LPs can only withdraw their share of the **unlocked** portion of the pool.
    - After an option expires worthless or is exercised, any previously locked collateral is returned to the pool, and becomes available to LPs again.

---

## 4. Benefits & Use Cases

1. **Simple Access**:
    - Traders buy options directly from a **single pool** rather than matching with individual sellers.

2. **Earnings for LPs**:
    - Liquidity Providers potentially earn from the premiums paid by all option buyers.

3. **Flexible Exercise**:
    - American-style allows immediate exercise if an opportunity arises, **not** forcing buyers to wait for expiry.

4. **Cash-Settled**:
    - Payouts are in a stablecoin, simplifying the settlement process (no physical delivery of assets).

---

## 5. Considerations & Future Enhancements

1. **Pricing Model**
    - The prototype charges a flat 2% of the notional amount. Real-world options typically use advanced models (e.g., Black-Scholes) with implied volatility.
    - This contract’s simplistic premium might be too low or high compared to actual market conditions.

2. **Capital Efficiency**
    - Currently, the pool locks the full notional (`strike * amount`) as collateral, which may be over-collateralized if the asset price cannot move beyond certain ranges.
    - Enhancements could free up some liquidity if partial margin is deemed acceptable.

3. **Distribution of Premiums**
    - The contract collects premiums into the pool, but it doesn’t explicitly track or distribute them to LPs. Over time, the pool balance grows, indirectly benefiting LPs.
    - In a commercial context, it’s common to track yield or handle fees in a more direct manner.

4. **Partial Exercises**
    - True American options can be exercised incrementally. Here, each contract can be exercised only once, for simplicity.

5. **Risk & Governance**
    - A robust design might require risk frameworks and governance (e.g., limiting total open interest, updating strike constraints, using oracles to handle emergency shutdowns, etc.).

---

## 6. Conclusion

This contract showcases a **proof-of-concept** for American-style, cash-settled options using a shared liquidity pool. Liquidity Providers deposit stablecoins and earn from buyer premiums, while option buyers gain the flexibility of early exercise. Though not production-ready, it illustrates the core mechanics of a pooled underwriting model for on-chain options. In a real financial environment, additional risk controls, pricing logic, and governance structures would likely be added to ensure long-term sustainability and fairness for all participants.
