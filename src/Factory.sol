// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pool} from "./Pool.sol";

contract Factory {
    event PoolCreated(address indexed token0, address indexed token1, uint24 fee, uint256 price, uint256 priceLower, uint256 priceUpper, address pool);

    function createPool(address tokenA, address tokenB, uint24 fee, uint256 price, uint256 priceLower, uint256 priceUpper) external returns (address pool) {
        require(tokenA != tokenB, "IDENTICAL");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        Pool p = new Pool(t0, t1, fee, price, priceLower, priceUpper);
        pool = address(p);
        emit PoolCreated(t0, t1, fee, price, priceLower, priceUpper, pool);
    }
}

