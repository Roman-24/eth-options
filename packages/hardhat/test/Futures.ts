import { parseUnits, Contract, Signer } from "ethers";
import { ethers } from "hardhat";
import { expect } from "chai";

describe("Futures Contract", function () {
  let futures: Contract;
  let stableCoin: Contract;
  let priceFeedMock: Contract;
  //let owner: Signer;
  let trader1: Signer;
  let trader2: Signer;

  // For mock USDC with 6 decimals
  const stableDecimals = 6;

  // Chainlink mock aggregator price with 8 decimals => 3000.00000000
  const initialPrice = parseUnits("3000", 8);

  beforeEach(async function () {
    [owner, trader1, trader2] = await ethers.getSigners();

    // Deploy Mock Stablecoin (with 6 decimals)
    const StableCoin = await ethers.getContractFactory("MockStableCoin");
    stableCoin = await StableCoin.deploy("Mock USDC", "mUSDC", stableDecimals);

    // Make sure to wait for deployment to complete
    await stableCoin.waitForDeployment();
    const stableCoinAddress = await stableCoin.getAddress();

    // Mint some tokens to trader1 and trader2
    await stableCoin.mint(await trader1.getAddress(), parseUnits("10000", stableDecimals));
    await stableCoin.mint(await trader2.getAddress(), parseUnits("10000", stableDecimals));

    // Deploy a Mock Price Feed returning `initialPrice`
    const PriceFeedMock = await ethers.getContractFactory("MockPriceFeed");
    priceFeedMock = await PriceFeedMock.deploy(initialPrice);

    // Make sure to wait for deployment to complete
    await priceFeedMock.waitForDeployment();
    const priceFeedAddress = await priceFeedMock.getAddress();

    // Deploy the Futures contract
    const Futures = await ethers.getContractFactory("Futures");
    futures = await Futures.deploy(stableCoinAddress, priceFeedAddress);
    await futures.waitForDeployment();

    // Mint additional tokens to the futures contract to cover potential profits
    // This simulates the contract already having liquidity from other traders
    await stableCoin.mint(await futures.getAddress(), parseUnits("10000", stableDecimals));
  });

  it("should allow trader to open and close long position profitably", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 3;

    // Approve and open a long position
    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);
    await futures.connect(trader1).openPosition(margin, leverage, true); // long

    let position = await futures.positions(await trader1.getAddress());
    expect(position.isOpen).to.equal(true);
    expect(position.margin).to.equal(margin);
    expect(position.leverage).to.equal(leverage);

    // Increase price to 3300
    await priceFeedMock.setPrice(parseUnits("3300", 8));

    const balanceBefore = await stableCoin.balanceOf(await trader1.getAddress());
    await futures.connect(trader1).closePosition();
    const balanceAfter = await stableCoin.balanceOf(await trader1.getAddress());

    // Verify profit
    expect(balanceAfter).to.be.gt(balanceBefore);
    console.log("Profit:", ethers.formatUnits(balanceAfter - balanceBefore, stableDecimals), "USDC");

    // Position should no longer exist
    position = await futures.positions(await trader1.getAddress());
    expect(position.isOpen).to.equal(false);
  });

  it("should liquidate undercollateralized short position", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 4;

    // Approve and open a short position
    await stableCoin.connect(trader2).approve(await futures.getAddress(), margin);
    await futures.connect(trader2).openPosition(margin, leverage, false);

    // Price pumps to 4000 => short position might get liquidated
    await priceFeedMock.setPrice(parseUnits("4000", 8));

    const canLiquidate = await futures.checkLiquidation(await trader2.getAddress());
    expect(canLiquidate).to.equal(true);

    // Liquidate
    await futures.liquidate(await trader2.getAddress());
    const position = await futures.positions(await trader2.getAddress());
    expect(position.isOpen).to.equal(false);
  });

  it("should prevent invalid leverage", async function () {
    const margin = parseUnits("1000", stableDecimals);
    const leverage = 10; // over max (5)

    await stableCoin.connect(trader1).approve(await futures.getAddress(), margin);

    // Expect revert: "Invalid leverage"
    await expect(futures.connect(trader1).openPosition(margin, leverage, true)).to.be.revertedWith("Invalid leverage");
  });
});
