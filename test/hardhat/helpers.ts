import { ethers } from "hardhat";
import { loadDeployments, getNetworkName, DeploymentAddresses } from "../../scripts/utils/deployments";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import type { Contract } from "ethers";

/**
 * Test fixture that loads deployed contracts from deployments.json
 */
export interface TestContracts {
  token0: Contract;
  token1: Contract;
  sovereignPool: Contract;
  hlealm: Contract;
  hleQuoter: Contract;
  deployer: HardhatEthersSigner;
  trader: HardhatEthersSigner;
  lp: HardhatEthersSigner;
}

/**
 * Load deployed contracts for testing
 * Requires running deploy-local.ts first
 */
export async function loadDeployedContracts(): Promise<TestContracts> {
  const { chainId } = await ethers.provider.getNetwork();
  const networkName = getNetworkName(chainId);
  
  const deployments = loadDeployments();
  const addresses = deployments[networkName];
  
  if (!addresses.sovereignPool || !addresses.hlealm) {
    throw new Error(
      `Contracts not deployed on ${networkName}. Run 'npx hardhat run scripts/deploy-local.ts' first.`
    );
  }
  
  const [deployer, _, trader, lp] = await ethers.getSigners();
  
  // Load contract instances - use ISovereignPool interface for external contract
  const token0 = await ethers.getContractAt("MockERC20", addresses.token0!);
  const token1 = await ethers.getContractAt("MockERC20", addresses.token1!);
  const sovereignPool = await ethers.getContractAt(
    "node_modules/@valantis/valantis-core/src/pools/interfaces/ISovereignPool.sol:ISovereignPool", 
    addresses.sovereignPool!
  );
  const hlealm = await ethers.getContractAt("HLEALM", addresses.hlealm!);
  const hleQuoter = await ethers.getContractAt("HLEQuoter", addresses.hleQuoter!);
  
  return {
    token0,
    token1,
    sovereignPool,
    hlealm,
    hleQuoter,
    deployer,
    trader,
    lp,
  };
}

/**
 * Deploy fresh contracts for each test (alternative to fixture)
 */
export async function deployFreshContracts(): Promise<TestContracts> {
  const [deployer, feeRecipient, trader, lp] = await ethers.getSigners();
  
  // Deploy tokens
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const tokenA = await MockERC20.deploy("Token A", "TKA", 18);
  const tokenB = await MockERC20.deploy("Token B", "TKB", 18);
  
  // Sort tokens
  const tokenAAddress = await tokenA.getAddress();
  const tokenBAddress = await tokenB.getAddress();
  
  let token0: Contract, token1: Contract;
  let token0Address: string, token1Address: string;
  
  if (tokenAAddress.toLowerCase() < tokenBAddress.toLowerCase()) {
    token0 = tokenA;
    token1 = tokenB;
    token0Address = tokenAAddress;
    token1Address = tokenBAddress;
  } else {
    token0 = tokenB;
    token1 = tokenA;
    token0Address = tokenBAddress;
    token1Address = tokenAAddress;
  }
  
  // Deploy pool using the full artifact path
  const SovereignPool = await ethers.getContractFactory(
    "node_modules/@valantis/valantis-core/src/pools/SovereignPool.sol:SovereignPool"
  );
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
  const poolAddress = await sovereignPool.getAddress();
  
  // Deploy HLEALM (real contract with manual price mode)
  const HLEALM = await ethers.getContractFactory("HLEALM");
  const hlealm = await HLEALM.deploy(
    poolAddress,
    0n, // token0Index
    1n, // token1Index
    feeRecipient.address,
    deployer.address
  );
  const almAddress = await hlealm.getAddress();
  
  // Deploy quoter
  const HLEQuoter = await ethers.getContractFactory("HLEQuoter");
  const hleQuoter = await HLEQuoter.deploy(poolAddress, almAddress);
  
  // Configure
  await sovereignPool.setALM(almAddress);
  
  // Initialize with price using manual mode (not L1 oracle)
  const INITIAL_PRICE = ethers.parseEther("2000");
  await hlealm.setManualPrice(INITIAL_PRICE);
  await hlealm.setOracleMode(false); // Use manual price, not L1 oracle
  await hlealm.initializeEWMA();
  
  // Bootstrap liquidity via ALM's depositLiquidity function
  const INITIAL_TOKEN0 = ethers.parseEther("100");
  const INITIAL_TOKEN1 = ethers.parseEther("200000");
  
  await token0.mint(deployer.address, INITIAL_TOKEN0);
  await token1.mint(deployer.address, INITIAL_TOKEN1);
  await token0.approve(almAddress, INITIAL_TOKEN0);
  await token1.approve(almAddress, INITIAL_TOKEN1);
  
  // Use ALM's depositLiquidity (which calls pool.depositLiquidity internally)
  await hlealm.depositLiquidity(INITIAL_TOKEN0, INITIAL_TOKEN1, deployer.address);
  
  // Fund test accounts
  await token0.mint(trader.address, ethers.parseEther("10"));
  await token1.mint(trader.address, ethers.parseEther("20000"));
  await token0.mint(lp.address, ethers.parseEther("50"));
  await token1.mint(lp.address, ethers.parseEther("100000"));
  
  return {
    token0,
    token1,
    sovereignPool,
    hlealm,
    hleQuoter,
    deployer,
    trader,
    lp,
  };
}

/**
 * Constants for testing
 */
export const WAD = ethers.parseEther("1");
export const INITIAL_PRICE = ethers.parseEther("2000"); // 1 token0 = 2000 token1
export const DEFAULT_K_VOL = ethers.parseEther("0.05"); // 5%
export const DEFAULT_K_IMPACT = ethers.parseEther("0.01"); // 1%
export const MAX_SPREAD = ethers.parseEther("0.5"); // 50%

/**
 * Helper to build swap params
 */
export function buildSwapParams(
  isZeroToOne: boolean,
  amountIn: bigint,
  amountOutMin: bigint,
  recipient: string,
  tokenOut: string
) {
  return {
    isSwapCallback: false,
    isZeroToOne,
    amountIn,
    amountOutMin,
    deadline: Math.floor(Date.now() / 1000) + 3600,
    recipient,
    swapTokenOut: tokenOut,
    swapContext: {
      externalContext: "0x",
      verifierContext: "0x",
      swapCallbackContext: "0x",
      swapFeeModuleContext: "0x",
    },
  };
}

/**
 * Helper to build liquidity quote input
 */
export function buildQuoteInput(
  isZeroToOne: boolean,
  amountIn: bigint,
  sender: string,
  recipient: string,
  tokenOut: string
) {
  return {
    isZeroToOne,
    amountInMinusFee: amountIn,
    feeInBips: 0,
    sender,
    recipient,
    tokenOutSwap: tokenOut,
  };
}
