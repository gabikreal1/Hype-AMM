# HLE — Hyper Liquidity Engine

**Spread-Based AMM with L1 Oracle Pricing & Variance-Driven Volatility Protection**

Built on [Valantis Sovereign Pools](https://docs.valantis.xyz/design-space) for Hyperliquid.

---

## What Is This?

A market-making AMM that uses Hyperliquid's L1 oracle (via precompiles) for pricing, with dynamic spreads based on:

1. **Volatility Spread** — Derived from Two-Speed EWMA variance tracking
2. **Impact Spread** — Proportional to trade size relative to reserves

### Key Features

| Feature | Description |
|---------|-------------|
| **Oracle-Based Pricing** | Reads HyperCore L1 oracle prices on-chain via precompile |
| **Dynamic Spreads** | Spread = volatilitySpread + impactSpread (capped at 50%) |
| **Variance Tracking** | Fast/slow EWMA with variance for volatility detection |
| **Directional Quotes** | BUY: askPrice = oracle × (1 + spread), SELL: bidPrice = oracle × (1 - spread) |
| **Fill-or-Kill** | Native Valantis FoK via `amountOutMin` parameter |

---

## Architecture

```
┌─────────────────── HyperEVM ───────────────────┐
│                                                │
│   Sovereign Pool (Valantis)                    │
│   ├── HLEALM            ← spread-based pricing │
│   │   └── TwoSpeedEWMA  ← variance tracking    │
│   ├── HLEQuoter         ← on-chain quotes      │
│   └── LendingModule     ← yield optimization   │
│                                                │
│   PrecompileLib ─────────→ L1 Oracle Read      │
│                                                │
└────────────────────┬───────────────────────────┘
                     │
                     ▼
              ┌─────────────┐
              │  HyperCore  │
              │  (L1 Oracle)│
              └─────────────┘
```

---

## Core Components

### 1. HLEALM (`src/modules/HLEALM.sol`)
The main ALM implementing spread-based pricing:

```
totalSpread = volSpread + impactSpread
volSpread   = max(fastVariance, slowVariance) × kVol / WAD
impactSpread = amountIn × kImpact / reserveIn
```

- **BUY (zeroToOne)**: `askPrice = oraclePrice × (1 + totalSpread)`
- **SELL (oneToZero)**: `bidPrice = oraclePrice × (1 - totalSpread)`

### 2. TwoSpeedEWMA (`src/libraries/TwoSpeedEWMA.sol`)
Two-speed exponential moving average with variance tracking:

```
fastEWMA = αFast × price + (1 - αFast) × oldFast
slowEWMA = αSlow × price + (1 - αSlow) × oldSlow
variance = α × (price - ewma)² + (1 - α) × oldVariance
```

### 3. HLEQuoter (`src/modules/HLEQuoter.sol`)
On-chain quoter for getting spread-based quotes:
- `quote()` — Returns expected output amount
- `quoteDetailed()` — Returns full breakdown (spread, volatility, impact)

### 4. LendingModule (`src/modules/LendingModule.sol`)
Tracks deployed capital and yield for idle reserves sent to HyperCore.

---

## Project Structure

```
├── src/
│   ├── interfaces/           # Contract interfaces
│   │   ├── IHLEALM.sol       # ALM interface with spread pricing
│   │   ├── ILendingModule.sol
│   │   └── IYieldOptimizer.sol
│   ├── modules/              # Core AMM modules
│   │   ├── HLEALM.sol        # Main ALM with spread pricing
│   │   ├── HLEQuoter.sol     # On-chain quoter
│   │   ├── LendingModule.sol # Lending tracking
│   │   └── YieldOptimizer.sol
│   ├── libraries/            # Utility libraries
│   │   ├── TwoSpeedEWMA.sol  # Variance-tracking EWMA
│   │   ├── YieldTracker.sol  # APY calculation
│   │   └── L1OracleAdapter.sol
│   └── docs/
│       └── HLE_DOCUMENTATION.md
├── test/
│   ├── mocks/                # Test mocks
│   ├── modules/              # Module unit tests
│   ├── E2E.t.sol             # Integration tests
│   └── HLE_E2E.t.sol         # Full HLE E2E tests
├── script/
│   └── DeployHLE.s.sol       # Foundry deployment
├── lib/
│   ├── hyper-evm-lib/        # Precompile & CoreWriter utilities
│   └── valantis-core/        # Sovereign Pool framework
└── foundry.toml              # Foundry config
```

---

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Hyperliquid testnet RPC: `https://rpc.hyperliquid-testnet.xyz/evm`

### Install
```bash
git clone <repo>
cd Hype-AMM
forge install
```

### Build
```bash
forge build
```

### Test
```bash
# Run all tests
forge test -vvv

# Run specific test files
forge test --match-contract HLEE2ETest -vvv     # E2E tests
forge test --match-contract HLEALMTest -vvv      # ALM unit tests
forge test --match-contract LendingModuleTest -vvv
```

---

## Deployment

### Local/Fork Deployment
```bash
# Deploy to local anvil or fork
forge script script/DeployHLE.s.sol --rpc-url http://localhost:8545 --broadcast

# With verbose output
forge script script/DeployHLE.s.sol --rpc-url http://localhost:8545 --broadcast -vvvv
```

### Testnet Deployment
```bash
# Set your private key
export PRIVATE_KEY=0x...

# Deploy to Hyperliquid testnet
forge script script/DeployHLE.s.sol \
  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \
  --broadcast \
  --verify
```

### Mainnet Deployment
```bash
forge script script/DeployHLE.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast \
  --verify
```

---

## Bootstrap Liquidity

After deployment, bootstrap the pool with initial liquidity:

```solidity
// 1. Approve tokens to pool
token0.approve(address(pool), amount0);
token1.approve(address(pool), amount1);

// 2. Deposit liquidity (only pool manager can do this)
pool.depositLiquidity(
    amount0,           // token0 amount
    amount1,           // token1 amount
    poolManager,       // recipient of LP position
    "",               // verification context
    ""                // deposit data
);
```

Or via Foundry script:
```bash
forge script script/DeployHLE.s.sol:BootstrapLiquidity \
  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \
  --broadcast
```

---

## Execute Swaps

### Via Contract
```solidity
// Prepare swap params
SovereignPoolSwapParams memory params = SovereignPoolSwapParams({
    isSwapCallback: false,
    isZeroToOne: true,        // true = buy token1, false = sell token1
    amountIn: 1000e18,        // input amount
    amountOutMin: 990e18,     // minimum output (slippage protection / FoK)
    deadline: block.timestamp + 300,
    recipient: msg.sender,
    swapTokenOut: token1,
    swapContext: ""
});

// Execute swap
(uint256 amountInUsed, uint256 amountOut) = pool.swap(params);
```

### Get Quote First
```solidity
// Get quote with spread breakdown
(uint256 expectedOutput, uint256 volSpread, uint256 impactSpread) = 
    quoter.quoteDetailed(
        address(pool),
        true,           // isZeroToOne
        1000e18        // amountIn
    );
```

---

## Configuration

### Spread Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `kVol` | 5e16 (5%) | Volatility multiplier |
| `kImpact` | 1e16 (1%) | Impact multiplier |
| `MAX_SPREAD` | 5e17 (50%) | Maximum total spread cap |

### EWMA Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `alphaFast` | 5e16 (5%) | Fast EWMA decay (higher = more reactive) |
| `alphaSlow` | 1e16 (1%) | Slow EWMA decay (lower = more stable) |

### Adjust Parameters (Pool Manager Only)
```solidity
// Update spread multipliers
hlealm.setSpreadParams(newKVol, newKImpact);

// Update EWMA parameters  
hlealm.setEWMAParams(newAlphaFast, newAlphaSlow);
```

---

## Constants

| Name | Value |
|------|-------|
| L1 Oracle Precompile | `0x0000000000000000000000000000000000000807` |
| CoreWriter | `0x3333333333333333333333333333333333333333` |
| HYPE System Address | `0x2222222222222222222222222222222222222222` |
| Testnet Chain ID | 998 |
| Mainnet Chain ID | 999 |

---

## Spread Calculation Example

For a **BUY** (zeroToOne) trade of 1000 USDC:

```
Oracle Price:     $2000/ETH
Reserve0 (USDC):  100,000 USDC
Fast Variance:    0.001 (0.1%)
Slow Variance:    0.0005 (0.05%)

Volatility Metric = max(0.001, 0.0005) = 0.001
Vol Spread        = 0.001 × 0.05 = 0.00005 (0.005%)
Impact Spread     = 1000 / 100,000 × 0.01 = 0.0001 (0.01%)
Total Spread      = 0.015%

Ask Price         = $2000 × 1.00015 = $2000.30
Expected Output   = 1000 / 2000.30 = 0.4999 ETH
```

---

## Why Hyperliquid?

- **Precompiles**: Direct on-chain L1 oracle reads (~2k gas). No Chainlink, no keepers.
- **HyperBFT**: ~100ms block times. Fast enough for reactive systems.
- **CoreWriter**: Trustless cross-layer capital deployment for yield.
- **Fair ordering**: Prevents order-flow MEV at consensus level.

---

## Security Considerations

1. **Oracle Reliance** — Prices come from HyperCore L1 consensus (manipulate-resistant)
2. **Spread Protection** — MAX_SPREAD (50%) prevents extreme pricing during volatility
3. **Variance Tracking** — Detects rapid price movements and increases spreads
4. **Fill-or-Kill** — Native Valantis FoK via `amountOutMin` protects traders
5. **Pool Manager Only** — Parameter changes restricted to pool manager

---

## Documentation

- [HLE Technical Docs](./src/docs/HLE_DOCUMENTATION.md) — Full architecture & pricing model
- [Valantis Docs](https://docs.valantis.xyz/design-space) — Sovereign Pool framework
- [hyper-evm-lib](./lib/hyper-evm-lib/README.md) — Precompile & CoreWriter library

---

## License

MIT
