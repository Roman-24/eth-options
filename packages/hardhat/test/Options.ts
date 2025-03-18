import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits, Contract, Signer, MaxUint256 } from "ethers";

/**
 * This test ensures there's enough liquidity in the pool for large strike*amount calculations,
 * and uses MaxUint256 for approvals so we never get an "ERC20InsufficientAllowance" revert.
 */

describe("Options (Cash-Settled Pool)", function () {
  let options: Contract;
  let stable: Contract;
  let priceFeedMock: Contract;

  let lp1: Signer;
  let traderCall: Signer;
  let traderPut: Signer;

  // We'll use 18 decimals for the stable token, matching 1e18 math in the contract
  const stableDecimals = 18;

  // Price feed mock: "3000" => 3,000 * 1e8 => parseUnits("3000", 8)
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

    // 4) Deploy the Options contract
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

    // Now buy the call from traderCall
    // Approve max to avoid allowance issues
    await stable.connect(traderCall).approve(await options.getAddress(), MaxUint256);

    // strike=3000 (1e18), amount=2 (1e18) => collateral=6e39, but we have 1e24 minted => plenty
    const strike = parseUnits("3000", 18);
    const expiry = (await currentBlockTimestamp()) + 3600;
    const amountCall = parseUnits("2", 18);

    // premium=2%*(3000*2)=120 => 120 * 1e18
    // We'll just rely on the contract's logic. No big math needed here, but "120" in 1e18 => parseUnits("120", 18)
    // We do not need to do the exact math for the test. The contract will do it, and we have enough allowance.
    await options.connect(traderCall).buyOption(0, strike, expiry, amountCall);

    // Move time forward
    await ethers.provider.send("evm_increaseTime", [3600 + 10]);
    await ethers.provider.send("evm_mine", []);

    // Increase price => let's say 4000 => payoff= (4000-3000)*2=2000
    await priceFeedMock.setPrice(parseUnits("4000", 8));

    const balBefore = await stable.balanceOf(await traderCall.getAddress());
    await options.connect(traderCall).exerciseOption(0);
    const balAfter = await stable.balanceOf(await traderCall.getAddress());
    const diff = balAfter - balBefore;

    // Expect 2000 in 1e18
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
    const strike = parseUnits("3000", 18);
    const expiry = (await currentBlockTimestamp()) + 3600;
    const amountPut = parseUnits("1", 18);

    await options.connect(traderPut).buyOption(1, strike, expiry, amountPut);

    // After expiry => price=3500 => put worthless => call expireOption
    await ethers.provider.send("evm_increaseTime", [3600 + 1]);
    await ethers.provider.send("evm_mine", []);
    await priceFeedMock.setPrice(parseUnits("3500", 8));

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

    const strike = parseUnits("3000", 18);
    const expiry = (await currentBlockTimestamp()) + 3600;
    const amt = parseUnits("1", 18);

    await expect(options.connect(traderCall).buyOption(0, strike, expiry, amt)).to.be.revertedWith(
      "Not enough liquidity to cover max payoff",
    );
  });

  // Helper function
  async function currentBlockTimestamp(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp;
  }
});
