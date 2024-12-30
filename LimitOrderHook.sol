// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import necessary contracts and libraries
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

/**
 * @title LimitOrderHook
 * @notice A contract that hooks into the Uniswap V4 protocol to manage limit orders. 
 * It processes orders based on price movements, places orders, and allows users to redeem their orders.
 */
contract LimitOrderHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // Mapping to store the last processed tick for each pool
    mapping(PoolId => int24) public tickLasts;

    // Mapping to store limit orders for each pool and tick
    mapping(PoolId => mapping(int24 => mapping(bool => int256))) public limitOrders;

    // Mapping to track if a token ID already exists
    mapping(uint256 => bool) public tokenIdExists;

    // Mapping to track claimable amount for each token ID
    mapping(uint256 => uint256) public tokenIdClaimable;

    // Mapping to track total supply of each token ID
    mapping(uint256 => uint256) public tokenIdTotalSupply;

    // Mapping to store data for each token ID
    mapping(uint256 => TokenData) public tokenIdData;

    // Constants
    uint256 public constant MIN_ORDER_SIZE = 1000;

    // Constructor to initialize the contract
    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    /**
     * @notice Returns the hook calls that should be triggered at different stages.
     * @return The structure of hook calls.
     */
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    /**
     * @notice Initializes the hook when the pool is initialized.
     * @dev Sets the last processed tick for the pool.
     * @param key The pool key
     * @param tick The current tick of the pool
     * @return The selector for afterInitialize hook.
     */
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return LimitOrderHook.afterInitialize.selector;
    }

    /**
     * @notice Processes limit orders after a swap occurs in the pool.
     * @dev Handles price movement and executes orders accordingly.
     * @param sender The address of the sender making the swap
     * @param key The pool key
     * @param params The swap parameters
     * @return The selector for afterSwap hook.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        // Skip if the sender is the contract itself
        if (sender == address(this)) {
            return LimitOrderHook.afterSwap.selector;
        }

        bool continueProcessing = true;
        int24 currentTickLower;

        // Process limit orders while price is moving
        while (continueProcessing) {
            (continueProcessing, currentTickLower) = _processOrders(key, params);
            tickLasts[key.toId()] = currentTickLower;
        }

        return LimitOrderHook.afterSwap.selector;
    }

    /**
     * @notice Processes orders based on price movements.
     * @dev Iterates through limit orders and executes them when price reaches the limit.
     * @param key The pool key
     * @param params The swap parameters
     * @return continueProcessing Whether more orders need to be processed
     * @return currentTickLower The updated lower tick
     */
    function _processOrders(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool, int24) {
        (, int24 currentTick, , , , ) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTick = tickLasts[key.toId()];
        
        bool swapZeroForOne = !params.zeroForOne;
        int256 orderAmount;

        // Price is increasing, process oneForZero orders
        if (lastTick < currentTickLower) {
            for (int24 tick = lastTick; tick < currentTickLower; ) {
                orderAmount = limitOrders[key.toId()][tick][swapZeroForOne];
                if (orderAmount > 0) {
                    _executeOrder(key, tick, swapZeroForOne, orderAmount);
                    (, currentTick, , , , ) = poolManager.getSlot0(key.toId());
                    return (true, _getTickLower(currentTick, key.tickSpacing));
                }
                tick += key.tickSpacing;
            }
        } else { 
            // Price is decreasing, process zeroForOne orders
            for (int24 tick = lastTick; currentTickLower < tick; ) {
                orderAmount = limitOrders[key.toId()][tick][swapZeroForOne];
                if (orderAmount > 0) {
                    _executeOrder(key, tick, swapZeroForOne, orderAmount);
                    (, currentTick, , , , ) = poolManager.getSlot0(key.toId());
                    return (true, _getTickLower(currentTick, key.tickSpacing));
                }
                tick -= key.tickSpacing;
            }
        }

        return (false, currentTickLower);
    }

    /**
     * @notice Places a new limit order.
     * @dev Requires the order amount to be above the minimum size. Transfers the tokens from the user and mints the corresponding token ID.
     * @param key The pool key
     * @param tick The tick at which the order is placed
     * @param amountIn The amount of tokens being placed in the order
     * @param zeroForOne Whether the order is for a token swap from token0 to token1
     * @return The token ID of the placed order
     */
    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (uint256) {
        require(amountIn >= MIN_ORDER_SIZE, "Order too small");

        // Calculate the tick lower for the order
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        limitOrders[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = _getTokenId(key, tickLower, zeroForOne);
        
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        // Mint the order token
        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenIn = zeroForOne 
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        // Transfer tokens from the user to the contract
        try IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn) {
        } catch {
            revert("Token transfer failed");
        }

        emit OrderPlaced(key.toId(), tokenId, msg.sender, amountIn, tick, zeroForOne);
        return tokenId;
    }

    /**
     * @notice Executes a limit order when the price reaches the specified tick.
     * @param key The pool key
     * @param tick The tick at which the order is executed
     * @param zeroForOne Whether the order is for token0 to token1
     * @param amountIn The amount of tokens to be swapped
     */
    function _executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        // Prepare the swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne 
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta;
        // Execute the swap and handle any failure
        try {
            delta = abi.decode(
                poolManager.lock(abi.encodeCall(this._handleSwap, (key, params))),
                (BalanceDelta)
            );
        } catch {
            revert("Order execution failed during swap");
        }

        limitOrders[key.toId()][tick][zeroForOne] -= amountIn;

        uint256 tokenId = _getTokenId(key, tick, zeroForOne);
        uint256 amountReceived = uint256(int256(
            -(zeroForOne ? delta.amount1() : delta.amount0())
        ));

        tokenIdClaimable[tokenId] += amountReceived;

        emit OrderExecuted(key.toId(), tokenId, amountIn, amountReceived);
    }

    /**
     * @notice Handles the swap operation and performs necessary token transfers.
     * @param key The pool key
     * @param params The swap parameters
     * @return The balance delta resulting from the swap
     */
    function _handleSwap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external returns (BalanceDelta) {
        BalanceDelta delta;
        try {
            delta = poolManager.swap(key, params);
        } catch {
            revert("Swap failed");
        }

        // Transfer tokens based on the direction of the swap
        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                try IERC20(Currency.unwrap(key.currency0)).safeTransfer(
                    address(poolManager),
                    uint256(delta.amount0())
                ) {
                    poolManager.settle(key.currency0);
                } catch {
                    revert("Token transfer failed for amount0");
                }
            }
            if (delta.amount1() < 0) {
                try poolManager.take(
                    key.currency1,
                    address(this),
                    uint256(-delta.amount1())
                ) {
                } catch {
                    revert("Token transfer failed for amount1");
                }
            }
        } else {
            if (delta.amount1() > 0) {
                try IERC20(Currency.unwrap(key.currency1)).safeTransfer(
                    address(poolManager),
                    uint256(delta.amount1())
                ) {
                    poolManager.settle(key.currency1);
                } catch {
                    revert("Token transfer failed for amount1");
                }
            }
            if (delta.amount0() < 0) {
                try poolManager.take(
                    key.currency0,
                    address(this),
                    uint256(-delta.amount0())
                ) {
                } catch {
                    revert("Token transfer failed for amount0");
                }
            }
        }

        return delta;
    }

    /**
     * @notice Redeems the user's token for the claimable amount.
     * @param tokenId The token ID to redeem
     * @param amount The amount of tokens to redeem
     * @param recipient The address receiving the redeemed tokens
     */
    function redeem(
        uint256 tokenId,
        uint256 amount,
        address recipient
    ) external {
        require(tokenIdClaimable[tokenId] > 0, "Nothing to claim");
        require(
            balanceOf(msg.sender, tokenId) >= amount,
            "Insufficient balance"
        );

        TokenData memory data = tokenIdData[tokenId];
        address tokenOut = data.zeroForOne
            ? Currency.unwrap(data.poolKey.currency1)
            : Currency.unwrap(data.poolKey.currency0);

        uint256 amountToSend = amount.mulDivDown(
            tokenIdClaimable[tokenId],
            tokenIdTotalSupply[tokenId]
        );

        tokenIdClaimable[tokenId] -= amountToSend;
        tokenIdTotalSupply[tokenId] -= amount;
        _burn(msg.sender, tokenId, amount);

        try IERC20(tokenOut).safeTransfer(recipient, amountToSend) {
        } catch {
            revert("Redemption transfer failed");
        }

        emit OrderRedeemed(tokenId, msg.sender, recipient, amount, amountToSend);
    }

    /**
     * @notice Generates a unique token ID for each order based on the pool key and tick.
     * @param key The pool key
     * @param tickLower The lower tick for the order
     * @param zeroForOne Whether the order is for token0 to token1
     * @return The generated token ID
     */
    function _getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne)));
    }

    /**
     * @notice Sets the last processed tick for a given pool ID.
     * @param poolId The pool ID
     * @param tick The tick to set
     */
    function _setTickLast(PoolId poolId, int24 tick) internal {
        tickLasts[poolId] = tick;
    }

    /**
     * @notice Calculates the lower tick for a given tick based on the pool's tick spacing.
     * @param tick The current tick
     * @param tickSpacing The tick spacing for the pool
     * @return The lower tick value
     */
    function _getTickLower(
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--;
        return intervals * tickSpacing;
    }

    // Events to emit for logging important actions
    event OrderPlaced(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        address owner,
        uint256 amount,
        int24 tick,
        bool zeroForOne
    );
    event OrderExecuted(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        int256 amountIn,
        uint256 amountOut
    );
    event OrderRedeemed(
        uint256 indexed tokenId,
        address indexed owner,
        address recipient,
        uint256 amount,
        uint256 amountSent
    );
}
