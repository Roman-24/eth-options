import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, parseUnits, Signer } from "ethers";

/**
 * The tests below assume you have:
 *  - A "MockStableCoin" ERC20 with a constructor: MockStableCoin(name, symbol, decimals)
 *  - A "MockPriceFeed" contract with constructor: MockPriceFeed(initialPrice)
 *  - The "PhysicallySettledOptions" contract from the previous example,
 *    which calculates everything in 1e18 decimals.
 *
 * IMPORTANT CHANGE:
 *  - We'll use `stableDecimals = 18` so that it matches the contract's 1e18-based math.
 */

describe("PhysicallySettledOptions (Physically-Settled Calls & Puts)", function () {
  let options: Contract;
  let stable: Contract;
  let priceFeedMock: Contract;

  let owner: Signer;
  let lpEth: Signer; // provides ETH for calls
  let lpStable: Signer; // provides stable for puts
  let buyerCall: Signer;
  let buyerPut: Signer;

  // Common constants
  const stableDecimals = 18;
  const initialPrice = parseUnits("1500", 8); // $1,500.00
  const standardStrikePrice = parseUnits("1500", 18);
  const standardEthAmount = parseUnits("1", 18);
  const standardPremium = parseUnits("45", stableDecimals);

  // For tracking option IDs
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  let currentOptionId = 0;

  /**
   * Helper function to advance blockchain time
   */
  async function advanceTimeAfterExpiry() {
    await ethers.provider.send("evm_increaseTime", [24 * 3600 + 10]);
    await ethers.provider.send("evm_mine", []);
  }

  /**
   * Helper function to set price feed value
   */
  async function setEthPrice(price: string) {
    await priceFeedMock.setPrice(parseUnits(price, 8));
  }

  /**
   * Helper function to get expiry timestamp
   */
  async function getExpiryTimestamp() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp + 24 * 3600;
  }

  /**
   * Helper function to approve stable token spending
   */
  async function approveStable(signer: Signer, amount: bigint) {
    await stable.connect(signer).approve(await options.getAddress(), amount);
  }

  beforeEach(async () => {
    [owner, lpEth, lpStable, buyerCall, buyerPut] = await ethers.getSigners();

    // 1) Deploy MockStableCoin with 18 decimals
    const StableCoin = await ethers.getContractFactory("MockStableCoin");
    stable = await StableCoin.deploy("Mock USDC", "mUSDC", stableDecimals);
    await stable.waitForDeployment();

    // Mint some stable for LPs and buyers
    await stable.mint(await lpStable.getAddress(), parseUnits("10000", stableDecimals));
    await stable.mint(await buyerCall.getAddress(), parseUnits("5000", stableDecimals));
    await stable.mint(await buyerPut.getAddress(), parseUnits("5000", stableDecimals));

    // 2) Deploy PriceFeed Mock
    const PriceFeedMock = await ethers.getContractFactory("MockPriceFeed");
    priceFeedMock = await PriceFeedMock.deploy(initialPrice);
    await priceFeedMock.waitForDeployment();

    // 3) Deploy the Options contract
    const Options = await ethers.getContractFactory("PhysicallySettledOptions");
    options = await Options.deploy(await stable.getAddress(), await priceFeedMock.getAddress());
    await options.waitForDeployment();

    // Reset option ID counter
    currentOptionId = 0;
  });

  it("should allow LPs to provide collateral (ETH and Stable)", async function () {
    // lpEth deposits 5 ETH
    const ethAmount = parseUnits("5", 18);
    await options.connect(lpEth).provideEthCollateral({ value: ethAmount });

    // Check totalEthCollateral
    const totalEth = await options.totalEthCollateral();
    expect(totalEth).to.equal(ethAmount);

    // lpStable deposits 5000 stable
    const stableAmount = parseUnits("5000", stableDecimals);
    await approveStable(lpStable, stableAmount);
    await options.connect(lpStable).provideStableCollateral(stableAmount);

    const totalStable = await options.totalStableCollateral();
    expect(totalStable).to.equal(stableAmount);
  });

  it("should buy a CALL and exercise it if in-the-money after expiry", async () => {
    // 1) lpEth deposits 3 ETH for calls
    const ethAmount = parseUnits("3", 18);
    await options.connect(lpEth).provideEthCollateral({ value: ethAmount });

    // 2) BuyerCall buys a CALL
    const expiry = await getExpiryTimestamp();
    await approveStable(buyerCall, standardPremium * 2n);

    // Buy call => optionType=0
    await options.connect(buyerCall).buyOption(0, standardStrikePrice, expiry, standardEthAmount);
    currentOptionId++;

    // lockedEth should be 1 ETH
    const lockedETH = await options.lockedEth();
    expect(lockedETH).to.equal(standardEthAmount);

    // 3) Move time forward to simulate expiry
    await advanceTimeAfterExpiry();

    // 4) Increase price => pretend ETH is now $1800
    await setEthPrice("1800");

    // 5) Exercise => buyer pays 1500 stable => gets 1 ETH
    await approveStable(buyerCall, standardStrikePrice);

    const buyerEthBefore = await ethers.provider.getBalance(await buyerCall.getAddress());
    await options.connect(buyerCall).exerciseOption(0);
    const buyerEthAfter = await ethers.provider.getBalance(await buyerCall.getAddress());

    expect(buyerEthAfter).to.be.gt(buyerEthBefore);
    // lockedEth now 0
    const lockedETHafter = await options.lockedEth();
    expect(lockedETHafter).to.equal(0n);
  });

  it("should buy a PUT and exercise if in-the-money after expiry", async () => {
    // 1) lpStable deposits 3000 stable
    const stableAmount = parseUnits("3000", stableDecimals);
    await approveStable(lpStable, stableAmount);
    await options.connect(lpStable).provideStableCollateral(stableAmount);

    // 2) BuyerPut buys a PUT
    const expiry = await getExpiryTimestamp();
    await approveStable(buyerPut, standardPremium * 2n);

    await options.connect(buyerPut).buyOption(1, standardStrikePrice, expiry, standardEthAmount);
    currentOptionId++;

    // lockedStable => 1500
    const locked = await options.lockedStable();
    expect(locked).to.equal(standardStrikePrice);

    // 3) Increase time
    await advanceTimeAfterExpiry();

    // 4) Decrease ETH price => $1200 => puts in the money
    await setEthPrice("1200");

    // 5) Buyer sends 1 ETH => receives 1500 stable
    // Provide buyerPut with 1 ETH
    const tx = await owner.sendTransaction({
      to: await buyerPut.getAddress(),
      value: standardEthAmount,
    });
    await tx.wait();

    const stableBefore = await stable.balanceOf(await buyerPut.getAddress());
    await options.connect(buyerPut).exerciseOption(0, {
      value: standardEthAmount,
    });
    const stableAfter = await stable.balanceOf(await buyerPut.getAddress());
    expect(stableAfter).to.be.gt(stableBefore);

    // lockedStable => 0
    const lockedAfter = await options.lockedStable();
    expect(lockedAfter).to.equal(0n);
  });

  it("should expire worthless if the option is out-of-the-money", async () => {
    // Provide 2 ETH
    const ethAmount = parseUnits("2", 18);
    await options.connect(lpEth).provideEthCollateral({ value: ethAmount });

    // BuyerCall buys a CALL
    const expiry = await getExpiryTimestamp();
    await approveStable(buyerCall, standardPremium * 2n);

    await options.connect(buyerCall).buyOption(0, standardStrikePrice, expiry, standardEthAmount);
    currentOptionId++;

    const locked = await options.lockedEth();
    expect(locked).to.equal(standardEthAmount);

    // After expiry, if ETH < strike => worthless
    await advanceTimeAfterExpiry();
    await setEthPrice("1400");

    // Buyer won't exercise => anyone can call expire
    await options.expireOption(0);

    const lockedAfter = await options.lockedEth();
    expect(lockedAfter).to.equal(0n);
  });

  it("should fail buying a call if not enough free ETH is available", async () => {
    // Provide only 0.5 ETH
    const ethAmount = parseUnits("0.5", 18);
    await options.connect(lpEth).provideEthCollateral({ value: ethAmount });

    // Need 1.0 free ETH to buy a call
    const expiry = await getExpiryTimestamp();
    await approveStable(buyerCall, standardPremium * 2n);

    await expect(
      options.connect(buyerCall).buyOption(0, standardStrikePrice, expiry, standardEthAmount),
    ).to.be.revertedWith("Not enough free ETH collateral");
  });

  it("should fail buying a put if not enough free stable is available", async () => {
    // Provide only 300 stable
    const stableAmount = parseUnits("300", stableDecimals);
    await approveStable(lpStable, stableAmount);
    await options.connect(lpStable).provideStableCollateral(stableAmount);

    // Need 1500 stable locked
    const expiry = await getExpiryTimestamp();
    await approveStable(buyerPut, standardPremium * 2n);

    await expect(
      options.connect(buyerPut).buyOption(1, standardStrikePrice, expiry, standardEthAmount),
    ).to.be.revertedWith("Not enough free stable collateral");
  });
});
