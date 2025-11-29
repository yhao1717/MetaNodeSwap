// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./Pool.sol";
import "./PoolManager.sol";

contract SwapRouter {
    function pairMatches(address poolAddr, address a, address b) internal view returns (bool) {
        Pool p = Pool(poolAddr);
        address t0 = p.token0();
        address t1 = p.token1();
        return ((a == t0 && b == t1) || (a == t1 && b == t0));
    }
    function quoteExactIn(address pool, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint256 feeAmount) {
        (amountOut, feeAmount) = Pool(pool).quoteExactIn(tokenIn, amountIn);
    }

    function quoteExactOut(address pool, address tokenIn, uint256 amountOut) external view returns (uint256 amountInGross, uint256 feeAmount) {
        (amountInGross, feeAmount) = Pool(pool).quoteExactOut(tokenIn, amountOut);
    }

    function swapExactIn(address pool, address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256 amountOut, uint256 amountInUsed) {
        require(IERC20(tokenIn).transferFrom(msg.sender, pool, amountIn), "TRANSFER");
        (amountOut, amountInUsed) = Pool(pool).swapExactIn(tokenIn, amountIn, minOut, to);
    }

    function swapExactOut(address pool, address tokenIn, uint256 amountOut, uint256 maxIn, address to) external returns (uint256 amountInGross, uint256 amountOutActual) {
        (uint256 quoteIn, ) = Pool(pool).quoteExactOut(tokenIn, amountOut);
        require(quoteIn <= maxIn, "MAX_IN");
        require(IERC20(tokenIn).transferFrom(msg.sender, pool, quoteIn), "TRANSFER");
        (amountInGross, amountOutActual) = Pool(pool).swapExactOut(tokenIn, amountOut, maxIn, to);
        if (quoteIn > amountInGross) {
            require(IERC20(tokenIn).transfer(msg.sender, quoteIn - amountInGross), "REFUND");
        }
    }

    function bestQuoteExactIn(address manager, address tokenIn, address tokenOut, uint256 amountIn) public view returns (address bestPool, uint256 bestOut, uint256 feeAmount) {
        address[] memory pools = PoolManager(manager).getAllPools();
        for (uint256 i = 0; i < pools.length; i++) {
            Pool p = Pool(pools[i]);
            address t0 = p.token0();
            address t1 = p.token1();
            if (!((tokenIn == t0 && tokenOut == t1) || (tokenIn == t1 && tokenOut == t0))) continue;
            try p.quoteExactIn(tokenIn, amountIn) returns (uint256 out, uint256 f) {
                uint256 limit = tokenIn == t0 ? p.reserve1() : p.reserve0();
                uint256 outLimited = out > limit ? limit : out;
                if (outLimited > bestOut) {
                    bestOut = outLimited;
                    bestPool = address(p);
                    feeAmount = f;
                }
            } catch {}
        }
    }

    function bestQuoteExactOut(address manager, address tokenIn, address tokenOut, uint256 amountOut) public view returns (address bestPool, uint256 bestInGross, uint256 outActual) {
        address[] memory pools = PoolManager(manager).getAllPools();
        bestInGross = type(uint256).max;
        for (uint256 i = 0; i < pools.length; i++) {
            Pool p = Pool(pools[i]);
            address t0 = p.token0();
            address t1 = p.token1();
            if (!((tokenIn == t0 && tokenOut == t1) || (tokenIn == t1 && tokenOut == t0))) continue;
            uint256 limitOut = tokenIn == t0 ? p.reserve1() : p.reserve0();
            uint256 targetOut = amountOut <= limitOut ? amountOut : limitOut;
            if (targetOut == 0) continue;
            try p.quoteExactOut(tokenIn, targetOut) returns (uint256 inGross, uint256) {
                if (inGross < bestInGross) {
                    bestInGross = inGross;
                    bestPool = address(p);
                    outActual = targetOut;
                }
            } catch {}
        }
        if (bestPool == address(0)) {
            outActual = 0;
            bestInGross = 0;
        }
    }

    function swapExactInBest(address manager, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to) external returns (address pool, uint256 amountOut, uint256 amountInUsed) {
        (pool, amountOut, ) = bestQuoteExactIn(manager, tokenIn, tokenOut, amountIn);
        require(pool != address(0) && amountOut >= minOut, "NO_POOL");
        require(IERC20(tokenIn).transferFrom(msg.sender, pool, amountIn), "TRANSFER");
        (amountOut, amountInUsed) = Pool(pool).swapExactIn(tokenIn, amountIn, minOut, to);
    }

    function swapExactOutBest(address manager, address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, address to) external returns (address pool, uint256 amountInGross, uint256 amountOutActual) {
        (pool, amountInGross, amountOutActual) = bestQuoteExactOut(manager, tokenIn, tokenOut, amountOut);
        require(pool != address(0), "NO_POOL");
        require(amountInGross <= maxIn, "MAX_IN");
        require(IERC20(tokenIn).transferFrom(msg.sender, pool, amountInGross), "TRANSFER");
        (amountInGross, amountOutActual) = Pool(pool).swapExactOut(tokenIn, amountOut, maxIn, to);
        if (amountInGross > 0) {
            (uint256 qIn, ) = Pool(pool).quoteExactOut(tokenIn, amountOutActual);
            if (amountInGross > qIn) {
                require(IERC20(tokenIn).transfer(msg.sender, amountInGross - qIn), "REFUND");
                amountInGross = qIn;
            }
        }
    }

    struct PathParams { address manager; address tokenIn; address tokenOut; uint256 amountOut; uint256 maxIn; address to; }

    function swapExactOutPath(address manager, uint32[] memory indexPath, address tokenIn, address tokenOut, uint256 amountOut, uint160 sqrtPriceLimitX96, uint256 maxIn, address to) external returns (uint256 totalInGross, uint256 totalOutActual) {
        PathParams memory p = PathParams(manager, tokenIn, tokenOut, amountOut, maxIn, to);
        (totalInGross, totalOutActual) = _swapExactOutPath(p, indexPath, sqrtPriceLimitX96);
    }

    function _swapExactOutPath(PathParams memory p, uint32[] memory indexPath, uint160 /*sqrtPriceLimitX96*/ ) internal returns (uint256 totalInGross, uint256 totalOutActual) {
        address[] memory pools = PoolManager(p.manager).getAllPools();
        uint256 remainingOut = p.amountOut;
        for (uint256 i = 0; i < indexPath.length && remainingOut > 0; i++) {
            uint256 idx = indexPath[i];
            require(idx < pools.length, "INDEX");
            address poolAddr = pools[idx];
            if (!pairMatches(poolAddr, p.tokenIn, p.tokenOut)) continue;
            (uint256 qIn, ) = Pool(poolAddr).quoteExactOut(p.tokenIn, remainingOut);
            require(qIn <= p.maxIn - totalInGross, "MAX_IN");
            require(IERC20(p.tokenIn).transferFrom(msg.sender, poolAddr, qIn), "TRANSFER");
            (uint256 usedIn, uint256 outActual) = Pool(poolAddr).swapExactOut(p.tokenIn, remainingOut, qIn, p.to);
            totalInGross += usedIn;
            totalOutActual += outActual;
            remainingOut -= outActual;
        }
    }
}
