// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ISovereignALM} from "@valantis-core/ALM/interfaces/ISovereignALM.sol";
import {ISovereignPool} from "@valantis-core/pools/interfaces/ISovereignPool.sol";
import {ALMLiquidityQuoteInput, ALMLiquidityQuote} from "@valantis-core/ALM/structs/SovereignALMStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {PrecompileLib} from "@hyper-evm-lib/PrecompileLib.sol";
import {HLConversions} from "@hyper-evm-lib/common/HLConversions.sol";
import {L1OracleAdapter} from "../libraries/L1OracleAdapter.sol";
import {TwoSpeedEWMA} from "../libraries/TwoSpeedEWMA.sol";

/**
 * @title HLEALM
 * @notice Hyper Liquidity Engine - ALM with L1 oracle pricing and Fill-or-Kill execution
 * @dev Implements:
 *   - Fill-or-Kill quotes at L1 oracle price (no partial fills)
 *   - Surplus capture: Any price improvement goes to protocol
 *   - Two-speed EWMA volatility gating for safety
 *   - Integration with YieldOptimizer for capital efficiency
 * 
 * Flow:
 *   1. Sovereign Pool calls getLiquidityQuote() with swap details
 *   2. HLEALM reads L1 oracle price via PrecompileLib
 *   3. Validates quote against EWMA volatility threshold
 *   4. Returns Fill-or-Kill quote at oracle price
 *   5. Pool executes swap, surplus captured by protocol
 *   6. Fees tracked for yield comparison
 */
contract HLEALM is ISovereignALM, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TwoSpeedEWMA for TwoSpeedEWMA.EWMAState;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice WAD precision (18 decimals)
    uint256 constant WAD = 1e18;

    /// @notice Basis points precision
    uint256 constant BPS = 10_000;

    /// @notice Default volatility threshold (100 bps = 1%)
    uint256 constant DEFAULT_VOLATILITY_THRESHOLD_BPS = 100;

    /// @notice Default K_VOL multiplier for volatility spread (WAD scale)
    /// @dev volSpread = (maxVariance * K_VOL) / WAD
    uint256 constant DEFAULT_K_VOL = 5e16; // 0.05 (5%)

    /// @notice Default K_IMPACT multiplier for price impact spread (WAD scale)
    /// @dev impactSpread = (amountIn * K_IMPACT) / reserveIn
    uint256 constant DEFAULT_K_IMPACT = 1e16; // 0.01 (1%)

    /// @notice Maximum K_VOL (100% = 1.0)
    uint256 constant MAX_K_VOL = WAD;

    /// @notice Maximum K_IMPACT (10% = 0.1)
    uint256 constant MAX_K_IMPACT = 1e17;

    /// @notice Maximum total spread (50% = 0.5)
    uint256 constant MAX_SPREAD = 5e17;

    /// @notice Maximum price deviation allowed (500 bps = 5%)
    uint256 constant MAX_PRICE_DEVIATION_BPS = 500;

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Sovereign pool this ALM serves
    ISovereignPool public immutable pool;

    /// @notice Token0 of the pool
    address public immutable token0;

    /// @notice Token1 of the pool
    address public immutable token1;

    /// @notice HyperCore token index for token0
    uint64 public token0Index;

    /// @notice HyperCore token index for token1
    uint64 public token1Index;

    /// @notice EWMA state for price tracking
    TwoSpeedEWMA.EWMAState public priceEWMA;

    /// @notice Volatility threshold in basis points (for gating)
    uint256 public volatilityThresholdBps;

    /// @notice K_VOL multiplier for volatility-based spread (WAD scale)
    /// @dev volSpread = (maxVariance * kVol) / WAD
    uint256 public kVol;

    /// @notice K_IMPACT multiplier for price impact spread (WAD scale)
    /// @dev impactSpread = (amountIn * kImpact) / reserveIn
    uint256 public kImpact;

    /// @notice Accumulated spread fees for token0
    uint256 public accumulatedFees0;

    /// @notice Accumulated spread fees for token1
    uint256 public accumulatedFees1;

    /// @notice Surplus captured for token0
    uint256 public surplusCaptured0;

    /// @notice Surplus captured for token1
    uint256 public surplusCaptured1;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice YieldOptimizer for fee tracking (optional)
    address public yieldOptimizer;

    /// @notice Whether the ALM is paused
    bool public paused;

    /// @notice Manual price override (0 = use L1 oracle, >0 = use this price)
    /// @dev Allows testing without L1 precompiles
    uint256 public manualPrice;

    /// @notice Whether to use L1 oracle or manual price
    bool public useL1Oracle;

    // ═══════════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════════

    event SwapExecuted(
        address indexed sender,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        uint256 effectivePrice,
        uint256 spreadUsed
    );

    event VolatilityGated(
        uint256 fastEWMA,
        uint256 slowEWMA,
        uint256 deviationBps,
        uint256 thresholdBps
    );

    event SpreadConfigUpdated(uint256 kVol, uint256 kImpact);

    event FeesCollected(address indexed recipient, uint256 amount0, uint256 amount1);
    event SurplusCollected(address indexed recipient, uint256 amount0, uint256 amount1);
    event VolatilityThresholdUpdated(uint256 volatilityThresholdBps);
    event YieldOptimizerSet(address indexed optimizer);
    event Paused(bool isPaused);
    event LiquidityDeposited(address indexed sender, uint256 amount0, uint256 amount1);
    event LiquidityWithdrawn(address indexed recipient, uint256 amount0, uint256 amount1);
    event ManualPriceSet(uint256 price);
    event OracleModeSet(bool useL1Oracle);

    // ═══════════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════════

    error HLEALM__OnlyPool();
    error HLEALM__Paused();
    error HLEALM__VolatilityTooHigh();
    error HLEALM__PriceDeviationTooHigh();
    error HLEALM__InsufficientLiquidity();
    error HLEALM__ZeroAddress();
    error HLEALM__InvalidSpreadConfig();
    error HLEALM__NotInitialized();
    error HLEALM__SlippageExceeded();
    error HLEALM__InvalidTokenPair();

    // ═══════════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════════

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert HLEALM__OnlyPool();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert HLEALM__Paused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the HLE ALM
     * @param _pool Sovereign pool address
     * @param _token0Index HyperCore index for token0
     * @param _token1Index HyperCore index for token1
     * @param _feeRecipient Address to receive fees
     * @param _owner Owner address
     */
    constructor(
        address _pool,
        uint64 _token0Index,
        uint64 _token1Index,
        address _feeRecipient,
        address _owner
    ) {
        if (_pool == address(0)) revert HLEALM__ZeroAddress();
        if (_feeRecipient == address(0)) revert HLEALM__ZeroAddress();
        if (_owner == address(0)) revert HLEALM__ZeroAddress();

        pool = ISovereignPool(_pool);
        token0 = pool.token0();
        token1 = pool.token1();
        token0Index = _token0Index;
        token1Index = _token1Index;
        feeRecipient = _feeRecipient;
        volatilityThresholdBps = DEFAULT_VOLATILITY_THRESHOLD_BPS;
        kVol = DEFAULT_K_VOL;
        kImpact = DEFAULT_K_IMPACT;
        
        // Transfer ownership to _owner (OZ 4.x)
        _transferOwnership(_owner);
    }
    // ═══════════════════════════════════════════════════════════════════════════════
    // INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize EWMA with current oracle price
     * @dev Must be called before first swap
     */
    function initialize() external onlyOwner {
        uint256 currentPrice = _getOracleMidPrice();
        priceEWMA.initialize(currentPrice);
    }

    /**
     * @notice Initialize EWMA with custom alphas
     * @param fastAlpha Fast EWMA smoothing factor (WAD)
     * @param slowAlpha Slow EWMA smoothing factor (WAD)
     */
    function initializeWithAlphas(
        uint256 fastAlpha,
        uint256 slowAlpha
    ) external onlyOwner {
        uint256 currentPrice = _getOracleMidPrice();
        priceEWMA.initializeWithAlphas(currentPrice, fastAlpha, slowAlpha);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ISALM IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get liquidity quote for a swap - core ALM function
     * @dev Called by Sovereign Pool to get quote for swap
     *      Uses spread-based pricing:
     *        - volSpread = (maxVariance * kVol) / WAD
     *        - impactSpread = (amountIn * kImpact) / reserveIn
     *        - totalSpread = volSpread + impactSpread
     *        - BUY (selling token0 for token1): askPrice = oracle * (1 + spread)
     *        - SELL (selling token1 for token0): bidPrice = oracle * (1 - spread)
     * @param _almLiquidityQuoteInput Quote input parameters
     * @return quote Fill-or-Kill quote at spread-adjusted price
     */
    function getLiquidityQuote(
        ALMLiquidityQuoteInput calldata _almLiquidityQuoteInput,
        bytes calldata /* _externalContext */,
        bytes calldata /* _verifierData */
    ) external override onlyPool whenNotPaused returns (ALMLiquidityQuote memory quote) {
        if (!priceEWMA.initialized) revert HLEALM__NotInitialized();

        // Get current oracle price
        uint256 oraclePrice = _getOracleMidPrice();
        
        // Update EWMA and get volatility reading (includes variance update)
        TwoSpeedEWMA.VolatilityReading memory volatility = priceEWMA.update(oraclePrice);
        
        // Gate on volatility
        if (volatility.deviationBps > volatilityThresholdBps) {
            emit VolatilityGated(
                volatility.fastEWMA,
                volatility.slowEWMA,
                volatility.deviationBps,
                volatilityThresholdBps
            );
            revert HLEALM__VolatilityTooHigh();
        }

        uint256 amountIn = _almLiquidityQuoteInput.amountInMinusFee;
        bool isBuy = _almLiquidityQuoteInput.isZeroToOne;

        // Calculate spread using max variance
        uint256 maxVar = volatility.fastVar > volatility.slowVar 
            ? volatility.fastVar 
            : volatility.slowVar;
        uint256 totalSpread = _calculateSpreadWithVar(amountIn, isBuy ? token0 : token1, maxVar);

        // Calculate output with spread
        (uint256 amountOut, uint256 effectivePrice) = _calculateSwapOutput(
            amountIn, oraclePrice, totalSpread, isBuy
        );

        // Check liquidity
        address tokenOut = isBuy ? token1 : token0;
        if (IERC20(tokenOut).balanceOf(address(pool)) < amountOut) {
            revert HLEALM__InsufficientLiquidity();
        }

        // Track fees and notify optimizer
        _trackFeesAndNotify(amountIn, amountOut, oraclePrice, isBuy);

        // Build Fill-or-Kill quote
        quote = ALMLiquidityQuote({
            isCallbackOnSwap: false,
            amountOut: amountOut,
            amountInFilled: amountIn
        });

        emit SwapExecuted(
            _almLiquidityQuoteInput.sender,
            isBuy,
            amountIn,
            amountOut,
            oraclePrice,
            effectivePrice,
            totalSpread
        );
    }

    /**
     * @notice Callback after swap (optional)
     * @dev Not used in this implementation
     */
    function onSwapCallback(
        bool /* _isZeroToOne */,
        uint256 /* _amountIn */,
        uint256 /* _amountOut */
    ) external override onlyPool {
        // No callback logic needed for Fill-or-Kill model
    }

    /**
     * @notice Callback when liquidity is deposited
     * @dev Called by the pool during depositLiquidity - transfers tokens to pool
     */
    function onDepositLiquidityCallback(
        uint256 _amount0,
        uint256 _amount1,
        bytes memory /* _data */
    ) external override onlyPool {
        // Transfer tokens from ALM to pool
        if (_amount0 > 0) {
            IERC20(token0).safeTransfer(msg.sender, _amount0);
        }
        if (_amount1 > 0) {
            IERC20(token1).safeTransfer(msg.sender, _amount1);
        }
        
        // Update YieldOptimizer with new liquidity
        if (yieldOptimizer != address(0)) {
            uint256 currentLiquidity = _getTotalLiquidity();
            (bool success,) = yieldOptimizer.call(
                abi.encodeWithSignature("updateLiquidity(uint256)", currentLiquidity)
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get current oracle mid price (token0/token1)
     * @return price Price in WAD (18 decimals)
     */
    function getOracleMidPrice() external view returns (uint256 price) {
        return _getOracleMidPrice();
    }

    /**
     * @notice Get current volatility reading
     * @return reading Volatility reading struct
     */
    function getVolatility() external view returns (TwoSpeedEWMA.VolatilityReading memory reading) {
        if (!priceEWMA.initialized) revert HLEALM__NotInitialized();
        return priceEWMA.getVolatility(volatilityThresholdBps);
    }

    /**
     * @notice Check if current volatility allows trading
     * @return canTrade True if volatility is within threshold
     */
    function canTrade() external view returns (bool) {
        if (!priceEWMA.initialized) return false;
        return !priceEWMA.isVolatile(volatilityThresholdBps);
    }

    /**
     * @notice Get total liquidity value (in token0 terms)
     * @return liquidity Total liquidity in WAD
     */
    function getTotalLiquidity() external view returns (uint256 liquidity) {
        return _getTotalLiquidity();
    }

    /**
     * @notice Get accumulated fees
     * @return fees0 Accumulated fees in token0
     * @return fees1 Accumulated fees in token1
     */
    function getAccumulatedFees() external view returns (uint256 fees0, uint256 fees1) {
        return (accumulatedFees0, accumulatedFees1);
    }

    /**
     * @notice Preview swap output for given input (off-chain quote estimation)
     * @dev Uses spread-based pricing matching getLiquidityQuote()
     * @param tokenIn Address of the input token (must be token0 or token1)
     * @param tokenOut Address of the output token (must be token0 or token1)
     * @param amountIn Input amount (after any external fees)
     * @return amountOut Expected output amount after spread
     * @return spreadFee Spread fee amount captured
     * @return canExecute Whether the swap can execute (liquidity + volatility check)
     */
    function previewSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 spreadFee, bool canExecute) {
        // Validate tokens
        bool isBuy = (tokenIn == token0 && tokenOut == token1);
        bool isSell = (tokenIn == token1 && tokenOut == token0);
        if (!isBuy && !isSell) {
            return (0, 0, false);
        }
        
        // Check initialization
        if (!priceEWMA.initialized) {
            return (0, 0, false);
        }

        // Check volatility (without updating EWMA)
        if (priceEWMA.isVolatile(volatilityThresholdBps)) {
            return (0, 0, false);
        }

        // Get oracle price
        uint256 oraclePrice = _getOracleMidPrice();
        
        // Calculate spread
        uint256 totalSpread = _calculateSpread(amountIn, isBuy ? token0 : token1);
        
        // Calculate output with spread
        (amountOut, spreadFee) = _calculateOutput(amountIn, oraclePrice, totalSpread, isBuy);

        // Check liquidity
        uint256 available = IERC20(tokenOut).balanceOf(address(pool));
        canExecute = available >= amountOut;
    }

    /**
     * @notice Get a quote for a swap (off-chain estimation)
     * @dev Uses spread-based pricing:
     *      - BUY (tokenIn=token0): askPrice = oracle * (1 + spread)
     *      - SELL (tokenIn=token1): bidPrice = oracle * (1 - spread)
     * @param tokenIn Address of the input token (must be token0 or token1)
     * @param tokenOut Address of the output token (must be token0 or token1)
     * @param amountIn Amount of tokenIn to swap
     * @return amountOut Expected output amount of tokenOut after spread
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        // Validate tokens
        bool isBuy = (tokenIn == token0 && tokenOut == token1);
        bool isSell = (tokenIn == token1 && tokenOut == token0);
        if (!isBuy && !isSell) revert HLEALM__InvalidTokenPair();
        
        // Get oracle price
        uint256 oraclePrice = _getOracleMidPrice();
        
        // Calculate spread
        uint256 totalSpread = _calculateSpread(amountIn, tokenIn);
        
        // Calculate output with spread
        (amountOut, ) = _calculateOutput(amountIn, oraclePrice, totalSpread, isBuy);
    }

    /**
     * @notice Get current spread for a given trade size
     * @param amountIn Trade size
     * @param tokenIn Token being sold
     * @return volSpread Volatility component of spread (WAD)
     * @return impactSpread Price impact component of spread (WAD)
     * @return totalSpread Total spread (WAD)
     */
    function getSpread(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256 volSpread, uint256 impactSpread, uint256 totalSpread) {
        if (!priceEWMA.initialized) revert HLEALM__NotInitialized();
        
        // Get max variance
        uint256 maxVar = priceEWMA.getMaxVariance();
        volSpread = (maxVar * kVol) / WAD;
        
        // Get reserve for impact calc
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(pool));
        impactSpread = reserveIn > 0 ? (amountIn * kImpact) / reserveIn : 0;
        
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }

    /**
     * @notice Get current variance values
     * @return fastVar Fast EWMA variance (WAD)
     * @return slowVar Slow EWMA variance (WAD)
     * @return maxVar Maximum of fast/slow variance (WAD)
     */
    function getVariance() external view returns (uint256 fastVar, uint256 slowVar, uint256 maxVar) {
        if (!priceEWMA.initialized) revert HLEALM__NotInitialized();
        (fastVar, slowVar) = priceEWMA.getVariances();
        maxVar = fastVar > slowVar ? fastVar : slowVar;
    }

    /**
     * @notice Get spread configuration
     * @return _kVol Volatility multiplier (WAD)
     * @return _kImpact Impact multiplier (WAD)
     */
    function getSpreadConfig() external view returns (uint256 _kVol, uint256 _kImpact) {
        return (kVol, kImpact);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set spread configuration (K_VOL and K_IMPACT)
     * @param _kVol New volatility multiplier (WAD scale)
     * @param _kImpact New impact multiplier (WAD scale)
     */
    function setSpreadConfig(
        uint256 _kVol,
        uint256 _kImpact
    ) external onlyOwner {
        if (_kVol > MAX_K_VOL || _kImpact > MAX_K_IMPACT) revert HLEALM__InvalidSpreadConfig();
        kVol = _kVol;
        kImpact = _kImpact;
        emit SpreadConfigUpdated(_kVol, _kImpact);
    }

    /**
     * @notice Set volatility threshold for gating
     * @param _volatilityThresholdBps New volatility threshold in basis points
     */
    function setVolatilityThreshold(uint256 _volatilityThresholdBps) external onlyOwner {
        volatilityThresholdBps = _volatilityThresholdBps;
        emit VolatilityThresholdUpdated(_volatilityThresholdBps);
    }

    /**
     * @notice Set YieldOptimizer for fee tracking
     * @param _optimizer YieldOptimizer address
     */
    function setYieldOptimizer(address _optimizer) external onlyOwner {
        yieldOptimizer = _optimizer;
        emit YieldOptimizerSet(_optimizer);
    }

    /**
     * @notice Set fee recipient
     * @param _recipient New fee recipient
     */
    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert HLEALM__ZeroAddress();
        feeRecipient = _recipient;
    }

    /**
     * @notice Collect accumulated fees
     */
    function collectFees() external {
        uint256 fees0 = accumulatedFees0;
        uint256 fees1 = accumulatedFees1;
        
        accumulatedFees0 = 0;
        accumulatedFees1 = 0;

        if (fees0 > 0) {
            IERC20(token0).safeTransfer(feeRecipient, fees0);
        }
        if (fees1 > 0) {
            IERC20(token1).safeTransfer(feeRecipient, fees1);
        }

        emit FeesCollected(feeRecipient, fees0, fees1);
    }

    /**
     * @notice Collect captured surplus
     */
    function collectSurplus() external {
        uint256 surplus0 = surplusCaptured0;
        uint256 surplus1 = surplusCaptured1;
        
        surplusCaptured0 = 0;
        surplusCaptured1 = 0;

        if (surplus0 > 0) {
            IERC20(token0).safeTransfer(feeRecipient, surplus0);
        }
        if (surplus1 > 0) {
            IERC20(token1).safeTransfer(feeRecipient, surplus1);
        }

        emit SurplusCollected(feeRecipient, surplus0, surplus1);
    }

    /**
     * @notice Pause/unpause the ALM
     * @param _paused New paused state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice Update token indices
     * @param _token0Index New token0 index
     * @param _token1Index New token1 index
     */
    function setTokenIndices(uint64 _token0Index, uint64 _token1Index) external onlyOwner {
        token0Index = _token0Index;
        token1Index = _token1Index;
    }

    /**
     * @notice Set manual price for testing (when not using L1 oracle)
     * @param _price Price in WAD (token0/token1)
     */
    function setManualPrice(uint256 _price) external onlyOwner {
        manualPrice = _price;
        emit ManualPriceSet(_price);
    }

    /**
     * @notice Set oracle mode
     * @param _useL1Oracle True to use L1 precompiles, false to use manual price
     */
    function setOracleMode(bool _useL1Oracle) external onlyOwner {
        useL1Oracle = _useL1Oracle;
        emit OracleModeSet(_useL1Oracle);
    }

    /**
     * @notice Initialize EWMA with current price (call after setting price)
     */
    function initializeEWMA() external onlyOwner {
        uint256 currentPrice = _getOracleMidPrice();
        require(currentPrice > 0, "Price not set");
        TwoSpeedEWMA.initialize(priceEWMA, currentPrice);
    }

    /**
     * @notice Force set variance values for testing
     * @param _fastVar Fast variance value
     * @param _slowVar Slow variance value
     */
    function forceSetVariance(uint256 _fastVar, uint256 _slowVar) external onlyOwner {
        priceEWMA.fastVar = _fastVar;
        priceEWMA.slowVar = _slowVar;
    }

    /**
     * @notice Deposit liquidity into the pool (only callable by owner)
     * @dev Transfers tokens from sender to pool via ALM
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param sender Address providing the tokens
     * @return amount0Deposited Actual amount of token0 deposited
     * @return amount1Deposited Actual amount of token1 deposited
     */
    function depositLiquidity(
        uint256 amount0,
        uint256 amount1,
        address sender
    ) external onlyOwner nonReentrant returns (uint256 amount0Deposited, uint256 amount1Deposited) {
        // Transfer tokens from sender to this contract
        // Pool will call onDepositLiquidityCallback which will transfer to pool
        if (amount0 > 0) {
            IERC20(token0).safeTransferFrom(sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransferFrom(sender, address(this), amount1);
        }

        // Call pool's depositLiquidity - this will trigger onDepositLiquidityCallback
        (amount0Deposited, amount1Deposited) = pool.depositLiquidity(
            amount0,
            amount1,
            sender, // original sender
            "", // verificationContext
            ""  // depositData
        );

        emit LiquidityDeposited(sender, amount0Deposited, amount1Deposited);
    }

    /**
     * @notice Withdraw liquidity from the pool (only callable by owner)
     * @dev Withdraws tokens from pool and sends to recipient
     * @param amount0 Amount of token0 to withdraw
     * @param amount1 Amount of token1 to withdraw
     * @param recipient Address to receive the tokens
     */
    function withdrawLiquidity(
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) external onlyOwner nonReentrant {
        pool.withdrawLiquidity(
            amount0,
            amount1,
            address(this), // sender
            recipient,
            "" // verificationContext
        );

        emit LiquidityWithdrawn(recipient, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PUBLIC VIEW FUNCTIONS (for testing and debugging)
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate spread details for a given trade
     * @param amountIn Trade amount
     * @param reserveIn Reserve of token being sold
     * @return volSpread Volatility spread component
     * @return impactSpread Impact spread component
     * @return totalSpread Total spread (capped at MAX_SPREAD)
     */
    function calculateSpreadDetails(
        uint256 amountIn,
        uint256 reserveIn
    ) external view returns (uint256 volSpread, uint256 impactSpread, uint256 totalSpread) {
        // 1. Volatility spread: use max(fastVar, slowVar)
        uint256 maxVar = priceEWMA.getMaxVariance();
        volSpread = (maxVar * kVol) / WAD;
        
        // 2. Impact spread: amountIn / reserveIn * kImpact
        impactSpread = reserveIn > 0 ? (amountIn * kImpact) / reserveIn : 0;
        
        // 3. Total spread (capped)
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }

    /**
     * @notice Update EWMA with current price (public for testing)
     * @dev Call this after changing manual price to update variance
     */
    function updateEWMA() external {
        uint256 currentPrice = _getOracleMidPrice();
        require(currentPrice > 0, "Price not set");
        TwoSpeedEWMA.update(priceEWMA, currentPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get oracle mid price (token0/token1)
     * @return price Price in WAD
     * @dev Uses L1 precompiles if useL1Oracle=true, else uses manualPrice
     */
    function _getOracleMidPrice() internal view virtual returns (uint256 price) {
        if (useL1Oracle) {
            uint256 price0 = L1OracleAdapter.getSpotPriceByIndexWAD(token0Index);
            uint256 price1 = L1OracleAdapter.getSpotPriceByIndexWAD(token1Index);
            price = L1OracleAdapter.getMidPrice(price0, price1);
        } else {
            price = manualPrice;
        }
    }

    /**
     * @notice Calculate total liquidity (in token0 value)
     * @return liquidity Total liquidity in WAD
     */
    function _getTotalLiquidity() internal view returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(pool));
        uint256 balance1 = IERC20(token1).balanceOf(address(pool));
        
        // Convert token1 to token0 value
        uint256 price = _getOracleMidPrice();
        uint256 value1InToken0 = (balance1 * WAD) / price;
        
        liquidity = balance0 + value1InToken0;
    }

    /**
     * @notice Calculate spread for a given trade
     * @param amountIn Trade size
     * @param tokenIn Token being sold
     * @return totalSpread Combined volatility + impact spread (WAD)
     */
    function _calculateSpread(uint256 amountIn, address tokenIn) internal view returns (uint256 totalSpread) {
        // 1. Volatility spread: use max(fastVar, slowVar)
        uint256 maxVar = priceEWMA.getMaxVariance();
        uint256 volSpread = (maxVar * kVol) / WAD;
        
        // 2. Impact spread: amountIn / reserveIn * kImpact
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(pool));
        uint256 impactSpread = reserveIn > 0 ? (amountIn * kImpact) / reserveIn : 0;
        
        // 3. Total spread (capped)
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }

    /**
     * @notice Calculate spread with provided variance (for getLiquidityQuote)
     * @param amountIn Trade size
     * @param tokenIn Token being sold
     * @param maxVar Max variance (already computed)
     * @return totalSpread Combined volatility + impact spread (WAD)
     */
    function _calculateSpreadWithVar(
        uint256 amountIn, 
        address tokenIn, 
        uint256 maxVar
    ) internal view returns (uint256 totalSpread) {
        uint256 volSpread = (maxVar * kVol) / WAD;
        uint256 reserveIn = IERC20(tokenIn).balanceOf(address(pool));
        uint256 impactSpread = reserveIn > 0 ? (amountIn * kImpact) / reserveIn : 0;
        
        totalSpread = volSpread + impactSpread;
        if (totalSpread > MAX_SPREAD) {
            totalSpread = MAX_SPREAD;
        }
    }

    /**
     * @notice Calculate swap output and effective price
     */
    function _calculateSwapOutput(
        uint256 amountIn,
        uint256 oraclePrice,
        uint256 totalSpread,
        bool isBuy
    ) internal pure returns (uint256 amountOut, uint256 effectivePrice) {
        if (isBuy) {
            effectivePrice = (oraclePrice * (WAD + totalSpread)) / WAD;
            amountOut = (amountIn * oraclePrice) / effectivePrice;
        } else {
            effectivePrice = (oraclePrice * (WAD - totalSpread)) / WAD;
            amountOut = (amountIn * WAD) / effectivePrice;
        }
    }

    /**
     * @notice Track fees and notify yield optimizer
     */
    function _trackFeesAndNotify(
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        bool isBuy
    ) internal {
        // Calculate fee captured (difference from oracle price output)
        uint256 amountOutAtOracle;
        if (isBuy) {
            amountOutAtOracle = (amountIn * oraclePrice) / WAD;
        } else {
            amountOutAtOracle = (amountIn * WAD) / oraclePrice;
        }
        uint256 spreadFee = amountOutAtOracle > amountOut ? amountOutAtOracle - amountOut : 0;

        // Track spread fees
        if (isBuy) {
            accumulatedFees1 += spreadFee;
        } else {
            accumulatedFees0 += spreadFee;
        }

        // Notify YieldOptimizer of fee income
        if (yieldOptimizer != address(0)) {
            uint256 currentLiquidity = _getTotalLiquidity();
            (bool success,) = yieldOptimizer.call(
                abi.encodeWithSignature("recordSwapFees(uint256,uint256)", spreadFee, currentLiquidity)
            );
        }
    }

    /**
     * @notice Calculate output amount given spread
     * @param amountIn Input amount
     * @param oraclePrice Oracle mid price (WAD)
     * @param totalSpread Spread to apply (WAD)
     * @param isBuy True if buying token1 (selling token0)
     * @return amountOut Output amount
     * @return spreadFee Fee captured from spread
     */
    function _calculateOutput(
        uint256 amountIn,
        uint256 oraclePrice,
        uint256 totalSpread,
        bool isBuy
    ) internal pure returns (uint256 amountOut, uint256 spreadFee) {
        uint256 amountOutAtOracle;
        
        if (isBuy) {
            // BUY token1 with token0: pay askPrice = oraclePrice * (1 + spread)
            // amountOutAtOracle = amountIn * oraclePrice / WAD
            // amountOut = amountOutAtOracle / (1 + spread)
            amountOutAtOracle = (amountIn * oraclePrice) / WAD;
            amountOut = (amountOutAtOracle * WAD) / (WAD + totalSpread);
        } else {
            // SELL token1 for token0: receive bidPrice = oraclePrice * (1 - spread)
            // amountOutAtOracle = amountIn * WAD / oraclePrice
            // amountOut = amountOutAtOracle * (1 - spread)
            amountOutAtOracle = (amountIn * WAD) / oraclePrice;
            amountOut = (amountOutAtOracle * (WAD - totalSpread)) / WAD;
        }
        
        // Fee is difference from oracle price
        spreadFee = amountOutAtOracle > amountOut ? amountOutAtOracle - amountOut : 0;
    }
}
