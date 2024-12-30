// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

contract LimitOrderHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    mapping(PoolId => int24) public tickLasts;
    mapping(PoolId => mapping(int24 => mapping(bool => int256))) public limitOrders;
    mapping(uint256 => bool) public tokenIdExists;
    mapping(uint256 => uint256) public tokenIdClaimable;
    mapping(uint256 => uint256) public tokenIdTotalSupply;
    mapping(uint256 => TokenData) public tokenIdData;

    struct TokenData {
        PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    uint256 public constant MIN_ORDER_SIZE = 1000;

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

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

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return LimitOrderHook.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        if (sender == address(this)) {
            return LimitOrderHook.afterSwap.selector;
        }

        bool continueProcessing = true;
        int24 currentTickLower;
        
        while (continueProcessing) {
            (continueProcessing, currentTickLower) = _processOrders(key, params);
            tickLasts[key.toId()] = currentTickLower;
        }

        return LimitOrderHook.afterSwap.selector;
    }

    function _processOrders(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool, int24) {
        (, int24 currentTick, , , , ) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTick = tickLasts[key.toId()];
        
        bool swapZeroForOne = !params.zeroForOne;
        int256 orderAmount;

        if (lastTick < currentTickLower) {
            // Price increased - process oneForZero orders
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
            // Price decreased - process zeroForOne orders
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

    function placeOrder(
        PoolKey calldata key,
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (uint256) {
        require(amountIn >= MIN_ORDER_SIZE, "Order too small");

        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        limitOrders[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = _getTokenId(key, tickLower, zeroForOne);
        
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenIn = zeroForOne 
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
            
        try IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn) {
        } catch {
            revert("Token transfer failed");
        }

        emit OrderPlaced(key.toId(), tokenId, msg.sender, amountIn, tick, zeroForOne);
        return tokenId;
    }

    function _executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 amountIn
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountIn,
            sqrtPriceLimitX96: zeroForOne 
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta;
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

    function _getTokenId(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne)));
    }

    function _setTickLast(PoolId poolId, int24 tick) internal {
        tickLasts[poolId] = tick;
    }

    function _getTickLower(
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--;
        return intervals * tickSpacing;
    }

    // Events
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
