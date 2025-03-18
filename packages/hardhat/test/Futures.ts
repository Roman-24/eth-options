import { parseUnits, Contract, Signer } from "ethers";
import { ethers } from "hardhat";
import { expect } from "chai";

describe("Futures Contract", function () {
  let futures: Contract;
  let stableCoin: Contract;
  let priceFeedMock: Contract;

  let owner: Signer;
  let trader1: Signer;
  let trader2: Signer;
  let lpProvider: Signer;

  // For mock USDC with 6 decimals
  const stableDecimals = 6;

  // Chainlink mock aggregator price with 8 decimals => 3000.00000000
  const initialPrice = parseUnits("3000", 8);

  beforeEach(async function () {
    [owner, trader1, trader2, lpProvider] = await ethers.getSigners();

    // Deploy Mock Stablecoin (with 6 decimals)
    const StableCoin = await ethers.getContractFactory("MockStableCoin");
    stableCoin = await StableCoin.deploy("Mock USDC", "mUSDC", stableDecimals);
    await stableCoin.waitForDeployment();

    // Mint tokens to trader1, trader2, and lpProvider
    await stableCoin.mint(await trader1.getAddress(), parseUnits("10000", stableDecimals));
    await stableCoin.mint(await trader2.getAddress(), parseUnits("10000", stableDecimals));
    await stableCoin.mint(await lpProvider.getAddress(), parseUnits("10000", stableDecimals));

    // Deploy a Mock Price Feed returning `initialPrice`
    const PriceFeedMock = await ethers.getContractFactory("MockPriceFeed");
    priceFeedMock = await PriceFeedMock.deploy(initialPrice);
    await priceFeedMock.waitForDeployment();

    // Deploy the Futures contract
    const Futures = await ethers.getContractFactory("Futures");
    futures = await Futures.deploy(await stableCoin.getAddress(), await priceFeedMock.getAddress());
    await futures.waitForDeployment();

    // Mint additional tokens to the futures contract to simulate existing liquidity
    await stableCoin.mint(await futures.getAddress(), parseUnits("10000", stableDecimals));
  });

  it("should allow trader to open and close long position with fees taken", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 3;
    // tradingFeeBps = 10 => 0.1% => fee = 1 USDC on margin=1000

    // Initially, fees should be 0
    const feesBefore = await futures.accumulatedFees();
    expect(feesBefore).to.equal(0n);

    // Approve and open a long position
    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);
    await futures.connect(trader1).openPosition(margin, leverage, true);

    // Position margin = 1000 - 1 => 999
    const pos = await futures.positions(await trader1.getAddress());
    expect(pos.isOpen).to.equal(true);
    expect(pos.margin).to.equal(parseUnits("999", stableDecimals));

    // Fees should now be 1
    const feesMid = await futures.accumulatedFees();
    expect(feesMid).to.equal(parseUnits("1", stableDecimals));

    // Increase price from 3000 => 3300
    await priceFeedMock.setPrice(parseUnits("3300", 8));

    const balanceBefore = await stableCoin.balanceOf(await trader1.getAddress());
    await futures.connect(trader1).closePosition();
    const balanceAfter = await stableCoin.balanceOf(await trader1.getAddress());

    // Trader should profit from the price increase
    expect(balanceAfter).to.be.gt(balanceBefore);

    // Position should be closed
    const newPos = await futures.positions(await trader1.getAddress());
    expect(newPos.isOpen).to.equal(false);
  });

  it("should liquidate undercollateralized short position (margin minus fee) with liquidation fee", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 4;
    // For a short, if price goes up enough => undercollateralized => liquidation

    // Approve and open a short position
    await stableCoin.connect(trader2).approve(await futures.getAddress(), margin);
    await futures.connect(trader2).openPosition(margin, leverage, false);

    // Position margin = 999 after 1 USDC fee
    // accumulatedFees = 1
    const feesBefore = await futures.accumulatedFees();

    // Pump price from 3000 => 4000 => short is likely underwater
    await priceFeedMock.setPrice(parseUnits("4000", 8));

    const canLiquidate = await futures.checkLiquidation(await trader2.getAddress());
    expect(canLiquidate).to.equal(true);

    // Liquidate
    await futures.liquidate(await trader2.getAddress());
    const position = await futures.positions(await trader2.getAddress());
    expect(position.isOpen).to.equal(false);

    // Liquidation fee = 5% of margin => 5% of 999 => ~49.95 => 49 due to truncation
    // So fees increase by 49
    const feesAfter = await futures.accumulatedFees();

    // Because these are now bigints, we do normal arithmetic, not .sub(...)
    const diff = feesAfter - feesBefore;
    expect(diff).to.equal(parseUnits("49.95", stableDecimals));
  });

  it("should prevent invalid leverage", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 10; // over max (5)

    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);
    await expect(futures.connect(trader1).openPosition(margin, leverage, true)).to.be.revertedWith("Invalid leverage");
  });

  it("should allow user to provide and withdraw liquidity", async function () {
    // contract already has 10000 minted in constructor, but no LP shares
    let totalShares = await futures.totalLpShares();
    expect(totalShares).to.equal(0n);

    const provideAmount = parseUnits("2000", stableDecimals);

    // Approve and provide liquidity from lpProvider
    await stableCoin.connect(lpProvider).approve(await futures.getAddress(), provideAmount);
    await futures.connect(lpProvider).provideLiquidity(provideAmount);

    // The first deposit => 1:1 shares
    const lpShares = await futures.lpShares(await lpProvider.getAddress());
    totalShares = await futures.totalLpShares();
    expect(lpShares).to.equal(provideAmount);
    expect(totalShares).to.equal(provideAmount);

    // Provide more liquidity from the same provider
    const provideAmount2 = parseUnits("1000", stableDecimals);
    await stableCoin.connect(lpProvider).approve(await futures.getAddress(), provideAmount2);
    await futures.connect(lpProvider).provideLiquidity(provideAmount2);

    // totalLpShares should now be > 2000
    const totalShares2 = await futures.totalLpShares();
    expect(totalShares2).to.be.gt(provideAmount);

    // Withdraw some shares
    const sharesToWithdraw = parseUnits("1500", stableDecimals);
    await futures.connect(lpProvider).withdrawLiquidity(sharesToWithdraw);

    // Check new shares
    const lpSharesAfter = await futures.lpShares(await lpProvider.getAddress());
    const totalSharesFinal = await futures.totalLpShares();

    // Now we do direct subtraction with bigints
    expect(lpSharesAfter).to.equal(totalShares2 - sharesToWithdraw);
    expect(totalSharesFinal).to.equal(totalShares2 - sharesToWithdraw);
  });

  it("should accumulate fees and distribute them", async function () {
    // Provide liquidity so the contract won't revert "No liquidity providers"
    const provideAmount = parseUnits("1000", stableDecimals);
    await stableCoin.connect(lpProvider).approve(await futures.getAddress(), provideAmount);
    await futures.connect(lpProvider).provideLiquidity(provideAmount);

    // 1) Trader1 opens position => fee
    const margin = parseUnits("1000", stableDecimals);
    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);
    await futures.connect(trader1).openPosition(margin, 3, true);

    // Now fees == 1
    const feesAfterOpen = await futures.accumulatedFees();
    expect(feesAfterOpen).to.equal(parseUnits("1", stableDecimals));

    // 2) Distribute fees => 20% to admin, 80% remains in contract for LP
    const adminAddr = await owner.getAddress();
    const adminStableBefore = await stableCoin.balanceOf(adminAddr);

    await futures.connect(owner).distributeFees();

    // Fees should now be zero
    const feesAfterDist = await futures.accumulatedFees();
    expect(feesAfterDist).to.equal(0n);

    // Admin should have gotten 0.2 USDC => parseUnits("0.2", stableDecimals)
    const adminStableAfter = await stableCoin.balanceOf(adminAddr);
    const diff = adminStableAfter - adminStableBefore;
    expect(diff).to.equal(parseUnits("0.2", stableDecimals));
  });

  it("should get platform stats correctly", async function () {
    // open a long position => margin=1000, lev=3 => totalLongSize=3000
    const margin = parseUnits("1000", stableDecimals);

    // Fee => 1
    // net margin => 999
    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);
    await futures.connect(trader1).openPosition(margin, 3, true);

    const [longSize, shortSize, availableLiquidity, fees] = await futures.getPlatformStats();
    expect(longSize).to.equal(parseUnits("3000", stableDecimals));
    expect(shortSize).to.equal(0n);
    expect(fees).to.equal(parseUnits("1", stableDecimals)); // accumulatedFees from open position

    // The contract started with 10000 minted + user added 1000 => total 11000
    // But 1 goes to fees => so "availableLiquidity" => 11000 - 1 => 10999
    expect(availableLiquidity).to.equal(parseUnits("10999", stableDecimals));
  });
});
