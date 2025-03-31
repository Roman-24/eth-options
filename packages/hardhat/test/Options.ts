import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits, Contract, Signer, MaxUint256 } from "ethers";

/**
 * This test ensures there's enough liquidity in the pool for large strike*amount calculations,
 * and uses MaxUint256 for approvals so we never get an "ERC20InsufficientAllowance" revert.
 */

describe("Options (Cash-Settled Pool, American Style)", function () {
  let options: Contract;
  let stable: Contract;
  let priceFeedMock: Contract;

  let lp1: Signer;
  let traderCall: Signer;
  let traderPut: Signer;

  // We'll use 18 decimals for the stable token, matching 1e18 math in the contract
  const stableDecimals = 18;

  // Mock price feed: "3000" => 3,000 * 1e8 => parseUnits("3000", 8)
  const initialPrice = parseUnits("3000", 8);

  beforeEach(async () => {
    [lp1, traderCall, traderPut] = await ethers.getSigners();

    // 1) Deploy MockStableCoin (18 decimals)
    const StableCoin = await ethers.getContractFactory("MockStableCoin");
    stable = await StableCoin.deploy("Mock USDC", "mUSDC", stableDecimals);
    await stable.waitForDeployment();

    // 2) Mint a huge amount of stable to lp1 so they can deposit
    const bigMint = parseUnits("1000000000000000000000000", stableDecimals); // 1e24
    await stable.mint(await lp1.getAddress(), bigMint);

    // Traders get smaller amounts
    await stable.mint(await traderCall.getAddress(), parseUnits("50000", stableDecimals));
    await stable.mint(await traderPut.getAddress(), parseUnits("50000", stableDecimals));

    // 3) Deploy MockPriceFeed returning initialPrice
    const PriceFeed = await ethers.getContractFactory("MockPriceFeed");
    priceFeedMock = await PriceFeed.deploy(initialPrice);
    await priceFeedMock.waitForDeployment();

    // 4) Deploy the updated American-style Options contract
    const Options = await ethers.getContractFactory("Options");
    options = await Options.deploy(await stable.getAddress(), await priceFeedMock.getAddress());
    await options.waitForDeployment();
  });

  it("should allow a huge liquidity deposit and partial withdrawal", async () => {
    // 1) Approve the contract with a giant allowance
    const deposit = parseUnits("1000000000000000000000000", stableDecimals); // 1e24
    await stable.connect(lp1).approve(await options.getAddress(), MaxUint256);

    // 2) Provide Liquidity
    await options.connect(lp1).provideLiquidity(deposit);

    const totalLiquidity = await options.totalLiquidity();
    expect(totalLiquidity).to.equal(deposit);

    // LP shares => deposit (first time)
    let lpShares = await options.lpShares(await lp1.getAddress());
    expect(lpShares).to.equal(deposit);

    // 3) Withdraw some portion
    const partialWithdraw = parseUnits("1000000000000000000000", stableDecimals); // 1e21
    await options.connect(lp1).withdrawLiquidity(partialWithdraw);

    const newLiquidity = await options.totalLiquidity();
    expect(newLiquidity).to.equal(deposit - partialWithdraw);

    lpShares = await options.lpShares(await lp1.getAddress());
    expect(lpShares).to.equal(deposit - partialWithdraw);
  });

  it("should buy a CALL & exercise if in-the-money (strike=3000, amount=2)", async () => {
    // Provide a large deposit
    const deposit = parseUnits("1000000000000000000000000", stableDecimals);
    await stable.connect(lp1).approve(await options.getAddress(), MaxUint256);
    await options.connect(lp1).provideLiquidity(deposit);

    // Approve max for traderCall
    await stable.connect(traderCall).approve(await options.getAddress(), MaxUint256);

    // Set an expiry well in the future
    const expiry = (await currentBlockTimestamp()) + 7200; // 2 hours from now

    // e.g. strike=3000 (1e18), amount=2(1e18)
    const strike = parseUnits("3000", stableDecimals);
    const amountCall = parseUnits("2", stableDecimals);

    // Trader buys the CALL option
    await options.connect(traderCall).buyOption(0, strike, expiry, amountCall);

    // Increase time, but remain *before* expiry so we can still exercise
    await ethers.provider.send("evm_increaseTime", [3600 + 10]); // ~1 hour
    await ethers.provider.send("evm_mine", []);

    // Increase price => let's say 4000 => payoff = (4000 - 3000) * 2 = 2000
    await priceFeedMock.setPrice(parseUnits("4000", 8));

    const balBefore = await stable.balanceOf(await traderCall.getAddress());
    await options.connect(traderCall).exerciseOption(0);
    const balAfter = await stable.balanceOf(await traderCall.getAddress());

    const diff = balAfter - balBefore;
    expect(diff).to.equal(parseUnits("2000", stableDecimals));
  });

  it("should buy a PUT & expire worthless if out-of-the-money", async () => {
    // Big deposit from lp1
    const deposit = parseUnits("1000000000000000000000000", stableDecimals);
    await stable.connect(lp1).approve(await options.getAddress(), MaxUint256);
    await options.connect(lp1).provideLiquidity(deposit);

    // TraderPut approves max
    await stable.connect(traderPut).approve(await options.getAddress(), MaxUint256);

    // strike=3000, amount=1 => collateral=3000 => we have enough
    const strike = parseUnits("3000", stableDecimals);
    const expiry = (await currentBlockTimestamp()) + 3600;
    const amountPut = parseUnits("1", stableDecimals);

    await options.connect(traderPut).buyOption(1, strike, expiry, amountPut);

    // After expiry => price=3500 => the PUT is out-of-the-money => worthless
    await ethers.provider.send("evm_increaseTime", [3600 + 1]);
    await ethers.provider.send("evm_mine", []);
    await priceFeedMock.setPrice(parseUnits("3500", 8));

    // Release collateral
    await options.expireOption(0);

    const locked = await options.lockedCollateral();
    expect(locked).to.equal(0n);
  });

  it("should revert if user tries to buy with insufficient liquidity", async () => {
    // Provide only 2000 => way less than 3000 needed for strike=3000, amount=1
    const smallDeposit = parseUnits("2000", stableDecimals);
    await stable.connect(lp1).approve(await options.getAddress(), MaxUint256);
    await options.connect(lp1).provideLiquidity(smallDeposit);

    // TraderCall => also approve max
    await stable.connect(traderCall).approve(await options.getAddress(), MaxUint256);

    const strike = parseUnits("3000", stableDecimals);
    const expiry = (await currentBlockTimestamp()) + 3600;
    const amt = parseUnits("1", stableDecimals);

    await expect(options.connect(traderCall).buyOption(0, strike, expiry, amt)).to.be.revertedWith(
      "Not enough pool liquidity",
    );
  });

  // Helper function: get current block timestamp
  async function currentBlockTimestamp(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp;
  }
});
