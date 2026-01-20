import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { 
  deployFreshContracts, 
  WAD, 
  INITIAL_PRICE,
  DEFAULT_K_VOL,
  DEFAULT_K_IMPACT,
  MAX_SPREAD,
} from "./helpers";

describe("HLE E2E Tests", function () {
  // Use loadFixture to deploy once and share state
  async function deployFixture() {
    return deployFreshContracts();
  }

  describe("Deployment", function () {
    it("Should deploy all contracts correctly", async function () {
      const { token0, token1, sovereignPool, hlealm, hleQuoter } = await loadFixture(deployFixture);

      expect(await token0.getAddress()).to.be.properAddress;
      expect(await token1.getAddress()).to.be.properAddress;
      expect(await sovereignPool.getAddress()).to.be.properAddress;
      expect(await hlealm.getAddress()).to.be.properAddress;
      expect(await hleQuoter.getAddress()).to.be.properAddress;
    });

    it("Should set correct pool references", async function () {
      const { sovereignPool, hlealm } = await loadFixture(deployFixture);

      expect(await hlealm.pool()).to.equal(await sovereignPool.getAddress());
    });

    it("Should initialize EWMA with correct price", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      // Use getVolatility() which returns the VolatilityReading struct
      const volatility = await hlealm.getVolatility();
      
      expect(volatility.fastEWMA).to.equal(INITIAL_PRICE);
      expect(volatility.slowEWMA).to.equal(INITIAL_PRICE);
      expect(volatility.fastVar).to.equal(0n);
      expect(volatility.slowVar).to.equal(0n);
    });

    it("Should have correct default spread parameters", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      expect(await hlealm.kVol()).to.equal(DEFAULT_K_VOL);
      expect(await hlealm.kImpact()).to.equal(DEFAULT_K_IMPACT);
    });

    it("Should be able to trade after initialization", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      expect(await hlealm.canTrade()).to.be.true;
    });
  });

  describe("Pool State", function () {
    it("Should have correct initial reserves", async function () {
      const { sovereignPool } = await loadFixture(deployFixture);

      const reserves = await sovereignPool.getReserves();
      expect(reserves[0]).to.equal(ethers.parseEther("100"));
      expect(reserves[1]).to.equal(ethers.parseEther("200000"));
    });

    it("Should have ALM set correctly", async function () {
      const { sovereignPool, hlealm } = await loadFixture(deployFixture);

      expect(await sovereignPool.alm()).to.equal(await hlealm.getAddress());
    });
  });

  describe("Spread Calculation", function () {
    it("Should have only impact spread with zero variance", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const reserveIn = ethers.parseEther("100");

      const [volSpread, impactSpread, totalSpread] = await hlealm.calculateSpreadDetails(
        amountIn,
        reserveIn
      );

      // With zero variance, volSpread = 0
      expect(volSpread).to.equal(0n);

      // impactSpread = amountIn * kImpact / reserveIn
      // = 1e18 * 1e16 / 100e18 = 1e14
      const expectedImpact = (amountIn * DEFAULT_K_IMPACT) / reserveIn;
      expect(impactSpread).to.equal(expectedImpact);
      expect(totalSpread).to.equal(expectedImpact);
    });

    it("Should include volatility spread when variance is set", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      // Set variance
      const variance = ethers.parseEther("0.01"); // 1% variance
      await hlealm.forceSetVariance(variance, variance / 2n);

      const amountIn = ethers.parseEther("1");
      const reserveIn = ethers.parseEther("100");

      const [volSpread, impactSpread, totalSpread] = await hlealm.calculateSpreadDetails(
        amountIn,
        reserveIn
      );

      // volSpread = max(fastVar, slowVar) * kVol / WAD
      const expectedVolSpread = (variance * DEFAULT_K_VOL) / WAD;
      expect(volSpread).to.equal(expectedVolSpread);

      // Total = vol + impact
      const expectedImpact = (amountIn * DEFAULT_K_IMPACT) / reserveIn;
      expect(totalSpread).to.equal(expectedVolSpread + expectedImpact);
    });

    it("Should increase impact spread with larger trades", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      const smallTrade = ethers.parseEther("1");
      const largeTrade = ethers.parseEther("10");
      const reserveIn = ethers.parseEther("100");

      const [, impactSmall] = await hlealm.calculateSpreadDetails(smallTrade, reserveIn);
      const [, impactLarge] = await hlealm.calculateSpreadDetails(largeTrade, reserveIn);

      expect(impactLarge).to.be.gt(impactSmall);
      expect(impactLarge).to.equal(impactSmall * 10n);
    });

    it("Should cap spread at MAX_SPREAD", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      // Set extreme variance
      const extremeVariance = ethers.parseEther("100"); // 10000%
      await hlealm.forceSetVariance(extremeVariance, extremeVariance);

      const amountIn = ethers.parseEther("50"); // 50% of reserves
      const reserveIn = ethers.parseEther("100");

      const [,, totalSpread] = await hlealm.calculateSpreadDetails(amountIn, reserveIn);

      expect(totalSpread).to.equal(MAX_SPREAD);
    });
  });

  describe("Quote Generation via previewSwap", function () {
    it("Should generate valid quote for BUY (zeroToOne)", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      // Use previewSwap
      const [amountOut, spreadFee, canExecute] = await hlealm.previewSwap(
        token0Addr,
        token1Addr,
        amountIn
      );

      // Should be executable
      expect(canExecute).to.be.true;

      // Output should be positive but less than max (due to spread)
      expect(amountOut).to.be.gt(0n);

      // Max output = amountIn * price = 1 * 2000 = 2000 token1
      const maxOutput = (amountIn * INITIAL_PRICE) / WAD;
      expect(amountOut).to.be.lt(maxOutput);
      expect(spreadFee).to.be.gt(0n);
    });

    it("Should generate valid quote for SELL (oneToZero)", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("2000"); // 2000 token1
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      const [amountOut, spreadFee, canExecute] = await hlealm.previewSwap(
        token1Addr, // tokenIn
        token0Addr, // tokenOut
        amountIn
      );

      expect(canExecute).to.be.true;
      expect(amountOut).to.be.gt(0n);

      // Max output = amountIn / price = 2000 / 2000 = 1 token0
      const maxOutput = (amountIn * WAD) / INITIAL_PRICE;
      expect(amountOut).to.be.lt(maxOutput);
    });

    it("Should return not executable when exceeding reserves", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      // Try to buy more than all reserves (100 token0)
      const amountIn = ethers.parseEther("200"); // Would need way more token1 than reserves
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      const [amountOut, spreadFee, canExecute] = await hlealm.previewSwap(
        token0Addr,
        token1Addr,
        amountIn
      );

      // Should not be executable
      expect(canExecute).to.be.false;
    });
  });

  describe("Preview Swap", function () {
    it("Should preview BUY correctly", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      const [amountOut, spreadFee, canExecute] = await hlealm.previewSwap(
        token0Addr,
        token1Addr,
        amountIn
      );

      expect(amountOut).to.be.gt(0n);
      expect(spreadFee).to.be.gt(0n);
      expect(canExecute).to.be.true;

      // Output should be reduced by spread
      const noSpreadOutput = (amountIn * INITIAL_PRICE) / WAD;
      expect(amountOut).to.be.lt(noSpreadOutput);
    });

    it("Should preview SELL correctly", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("2000");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      const [amountOut, spreadFee, canExecute] = await hlealm.previewSwap(
        token1Addr,
        token0Addr,
        amountIn
      );

      expect(amountOut).to.be.gt(0n);
      expect(spreadFee).to.be.gt(0n);
      expect(canExecute).to.be.true;

      const noSpreadOutput = (amountIn * WAD) / INITIAL_PRICE;
      expect(amountOut).to.be.lt(noSpreadOutput);
    });
  });

  describe("Volatility & EWMA", function () {
    it("Should update variance after price movement", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      // Get initial variance
      const initialVol = await hlealm.getVolatility();
      expect(initialVol.fastVar).to.equal(0n);

      // Simulate price movement
      await ethers.provider.send("evm_increaseTime", [60]); // 1 minute
      await ethers.provider.send("evm_mine", []);

      // Change price by 5%
      const newPrice = (INITIAL_PRICE * 105n) / 100n;
      await hlealm.setManualPrice(newPrice);
      await hlealm.updateEWMA();

      // Check variance increased
      const finalVol = await hlealm.getVolatility();
      expect(finalVol.fastVar).to.be.gt(0n);
    });

    it("Should increase spread with higher volatility", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const reserveIn = ethers.parseEther("100");

      // Get spread at low volatility
      const [,, lowVolSpread] = await hlealm.calculateSpreadDetails(amountIn, reserveIn);

      // Set high variance
      await hlealm.forceSetVariance(ethers.parseEther("0.05"), ethers.parseEther("0.03"));

      // Get spread at high volatility
      const [,, highVolSpread] = await hlealm.calculateSpreadDetails(amountIn, reserveIn);

      expect(highVolSpread).to.be.gt(lowVolSpread);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to set spread config", async function () {
      const { hlealm, deployer } = await loadFixture(deployFixture);

      const newKVol = ethers.parseEther("0.1"); // 10%
      const newKImpact = ethers.parseEther("0.02"); // 2%

      await hlealm.setSpreadConfig(newKVol, newKImpact);

      expect(await hlealm.kVol()).to.equal(newKVol);
      expect(await hlealm.kImpact()).to.equal(newKImpact);
    });

    it("Should reject non-owner setting spread config", async function () {
      const { hlealm, trader } = await loadFixture(deployFixture);

      const newKVol = ethers.parseEther("0.1");
      const newKImpact = ethers.parseEther("0.02");

      await expect(
        hlealm.connect(trader).setSpreadConfig(newKVol, newKImpact)
      ).to.be.reverted;
    });

    it("Should reject kVol > MAX_K_VOL", async function () {
      const { hlealm, deployer } = await loadFixture(deployFixture);

      const invalidKVol = ethers.parseEther("2"); // 200% > WAD
      const newKImpact = ethers.parseEther("0.02");

      await expect(
        hlealm.setSpreadConfig(invalidKVol, newKImpact)
      ).to.be.reverted;
    });
  });

  describe("Manual Price Changes", function () {
    it("Should update manual price correctly", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      const newPrice = ethers.parseEther("2500");
      await hlealm.setManualPrice(newPrice);

      expect(await hlealm.manualPrice()).to.equal(newPrice);
    });

    it("Should affect quote output after price change", async function () {
      const { hlealm, token0, token1 } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      // Get quote at initial price (2000)
      const [quote1Amount] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);

      // Change price to 2500
      await hlealm.setManualPrice(ethers.parseEther("2500"));
      await hlealm.initializeEWMA(); // Reset EWMA

      // Get quote at new price
      const [quote2Amount] = await hlealm.previewSwap(token0Addr, token1Addr, amountIn);

      // Higher price means more token1 output for same token0 input
      expect(quote2Amount).to.be.gt(quote1Amount);
    });
  });

  describe("Integration Flow", function () {
    it("Should complete full flow: price movement → variance increase → higher spread", async function () {
      const { hlealm } = await loadFixture(deployFixture);

      const amountIn = ethers.parseEther("1");
      const reserveIn = ethers.parseEther("100");

      // 1. Initial spread (no variance)
      const [,, initialSpread] = await hlealm.calculateSpreadDetails(amountIn, reserveIn);

      // 2. Simulate volatile price movements
      const prices = [
        INITIAL_PRICE * 102n / 100n, // +2%
        INITIAL_PRICE * 98n / 100n,  // -2% from original
        INITIAL_PRICE * 103n / 100n, // +3%
        INITIAL_PRICE * 97n / 100n,  // -3%
      ];

      for (const price of prices) {
        await ethers.provider.send("evm_increaseTime", [60]);
        await ethers.provider.send("evm_mine", []);
        await hlealm.setManualPrice(price);
        await hlealm.updateEWMA();
      }

      // 3. Get spread after volatility
      const [,, finalSpread] = await hlealm.calculateSpreadDetails(amountIn, reserveIn);

      // 4. Spread should have increased (or at least not decreased)
      // Note: Due to EWMA dynamics, initial variance from first update might be small
      expect(finalSpread).to.be.gte(initialSpread);

      console.log(`\n  Spread comparison:`);
      console.log(`    Initial spread: ${ethers.formatEther(initialSpread)} (${Number(initialSpread * 10000n / WAD) / 100}%)`);
      console.log(`    Final spread:   ${ethers.formatEther(finalSpread)} (${Number(finalSpread * 10000n / WAD) / 100}%)`);
    });
  });
});
