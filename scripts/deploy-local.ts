import { ethers } from "hardhat";
import { updateNetworkDeployments, getNetworkName } from "./utils/deployments";

/**
 * Local Test Deployment Script
 * 
 * Deploys the HLE system with HLEALM in manual price mode for local Hardhat testing.
 * Manual price mode allows setting prices without real L1 oracle precompiles.
 * 
 * Usage:
 *   npx hardhat run scripts/deploy-local.ts --network hardhat
 */

// Default price: 1 token0 = 2000 token1 (like ETH/USDC)
const INITIAL_PRICE = ethers.parseEther("2000");
const TOKEN0_INDEX = 0n;
const TOKEN1_INDEX = 1n;

async function main() {
  const [deployer, feeRecipient, trader, lp] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const networkName = getNetworkName(chainId);
  
  console.log("╔════════════════════════════════════════════════════════════╗");
  console.log("║        HLE Local Test Deployment (Manual Price Mode)        ║");
  console.log("╚════════════════════════════════════════════════════════════╝\n");
  
  console.log(`Network: ${networkName} (chainId: ${chainId})`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`FeeRecipient: ${feeRecipient?.address || deployer.address}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 1: Deploy Mock Tokens
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 1: Deploying Mock Tokens...");
  
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  
  const tokenA = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
  await tokenA.waitForDeployment();
  
  const tokenB = await MockERC20.deploy("USD Coin", "USDC", 18);
  await tokenB.waitForDeployment();
  
  // Sort tokens for Valantis
  const tokenAAddress = await tokenA.getAddress();
  const tokenBAddress = await tokenB.getAddress();
  
  let token0Address: string, token1Address: string;
  let token0: typeof tokenA, token1: typeof tokenA;
  
  if (tokenAAddress.toLowerCase() < tokenBAddress.toLowerCase()) {
    token0Address = tokenAAddress;
    token1Address = tokenBAddress;
    token0 = tokenA;
    token1 = tokenB;
  } else {
    token0Address = tokenBAddress;
    token1Address = tokenAAddress;
    token0 = tokenB;
    token1 = tokenA;
  }
  
  console.log(`  Token0: ${token0Address}`);
  console.log(`  Token1: ${token1Address}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 2: Deploy Sovereign Pool
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 2: Deploying Sovereign Pool...");
  
  const SovereignPool = await ethers.getContractFactory("SovereignPool");
  
  const poolArgs = {
    token0: token0Address,
    token1: token1Address,
    protocolFactory: deployer.address,
    poolManager: deployer.address,
    sovereignVault: ethers.ZeroAddress,
    verifierModule: ethers.ZeroAddress,
    isToken0Rebase: false,
    isToken1Rebase: false,
    token0AbsErrorTolerance: 0,
    token1AbsErrorTolerance: 0,
    defaultSwapFeeBips: 0,
  };
  
  const sovereignPool = await SovereignPool.deploy(poolArgs);
  await sovereignPool.waitForDeployment();
  const poolAddress = await sovereignPool.getAddress();
  console.log(`  Sovereign Pool: ${poolAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 3: Deploy HLEALM (with manual price mode for testing)
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 3: Deploying HLEALM...");
  
  const HLEALM = await ethers.getContractFactory("HLEALM");
  
  const hlealm = await HLEALM.deploy(
    poolAddress,
    TOKEN0_INDEX,
    TOKEN1_INDEX,
    feeRecipient?.address || deployer.address,
    deployer.address
  );
  await hlealm.waitForDeployment();
  const almAddress = await hlealm.getAddress();
  console.log(`  HLEALM: ${almAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 4: Deploy HLEQuoter
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 4: Deploying HLEQuoter...");
  
  const HLEQuoter = await ethers.getContractFactory("HLEQuoter");
  
  const hleQuoter = await HLEQuoter.deploy(poolAddress, almAddress);
  await hleQuoter.waitForDeployment();
  const quoterAddress = await hleQuoter.getAddress();
  console.log(`  HLEQuoter: ${quoterAddress}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 5: Configure & Initialize
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 5: Configuring...");
  
  // Set ALM on pool
  await sovereignPool.setALM(almAddress);
  console.log(`  ALM set on pool ✓`);
  
  // Set manual price (disable L1 oracle for local testing)
  await hlealm.setManualPrice(INITIAL_PRICE);
  await hlealm.setOracleMode(false); // Use manual price, not L1 oracle
  console.log(`  Manual price set to ${ethers.formatEther(INITIAL_PRICE)} ✓`);
  
  // Initialize EWMA
  await hlealm.initializeEWMA();
  console.log(`  EWMA initialized ✓`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 6: Bootstrap Liquidity
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 6: Bootstrapping liquidity...");
  
  const INITIAL_TOKEN0 = ethers.parseEther("100");     // 100 ETH
  const INITIAL_TOKEN1 = ethers.parseEther("200000");  // 200,000 USDC
  
  // Mint tokens to deployer
  await token0.mint(deployer.address, INITIAL_TOKEN0);
  await token1.mint(deployer.address, INITIAL_TOKEN1);
  console.log(`  Minted ${ethers.formatEther(INITIAL_TOKEN0)} token0 to deployer ✓`);
  console.log(`  Minted ${ethers.formatEther(INITIAL_TOKEN1)} token1 to deployer ✓`);
  
  // Approve pool
  await token0.approve(poolAddress, INITIAL_TOKEN0);
  await token1.approve(poolAddress, INITIAL_TOKEN1);
  console.log(`  Approved tokens for pool ✓`);
  
  // Deposit liquidity
  await sovereignPool.depositLiquidity(
    INITIAL_TOKEN0,
    INITIAL_TOKEN1,
    deployer.address,
    "0x",
    "0x"
  );
  console.log(`  Deposited liquidity to pool ✓`);
  
  // Verify reserves
  const reserves = await sovereignPool.getReserves();
  console.log(`  Pool reserves: ${ethers.formatEther(reserves[0])} / ${ethers.formatEther(reserves[1])}`);

  // ═══════════════════════════════════════════════════════════════════════════
  // STEP 7: Fund test accounts
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nStep 7: Funding test accounts...");
  
  if (trader) {
    await token0.mint(trader.address, ethers.parseEther("10"));
    await token1.mint(trader.address, ethers.parseEther("20000"));
    console.log(`  Funded trader: ${trader.address} ✓`);
  }
  
  if (lp) {
    await token0.mint(lp.address, ethers.parseEther("50"));
    await token1.mint(lp.address, ethers.parseEther("100000"));
    console.log(`  Funded LP: ${lp.address} ✓`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SAVE DEPLOYMENTS
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\nSaving deployments...");
  
  updateNetworkDeployments(networkName, {
    token0: token0Address,
    token1: token1Address,
    sovereignPool: poolAddress,
    hlealm: almAddress,
    hleQuoter: quoterAddress,
    deployer: deployer.address,
  });
  
  console.log(`  Deployments saved ✓`);

  // ═══════════════════════════════════════════════════════════════════════════
  // SUMMARY
  // ═══════════════════════════════════════════════════════════════════════════
  
  console.log("\n╔════════════════════════════════════════════════════════════╗");
  console.log("║                    Deployment Complete                      ║");
  console.log("╠════════════════════════════════════════════════════════════╣");
  console.log(`║ Token0:         ${token0Address} ║`);
  console.log(`║ Token1:         ${token1Address} ║`);
  console.log(`║ SovereignPool:  ${poolAddress} ║`);
  console.log(`║ HLEALM:         ${almAddress} ║`);
  console.log(`║ HLEQuoter:      ${quoterAddress} ║`);
  console.log("║                                                            ║");
  console.log(`║ Initial Price: 1 token0 = ${ethers.formatEther(INITIAL_PRICE)} token1          ║`);
  console.log(`║ Pool Reserves: ${ethers.formatEther(INITIAL_TOKEN0)} / ${ethers.formatEther(INITIAL_TOKEN1)}           ║`);
  console.log("╚════════════════════════════════════════════════════════════╝\n");
  
  return {
    token0Address,
    token1Address,
    poolAddress,
    almAddress,
    quoterAddress,
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
