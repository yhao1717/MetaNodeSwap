// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Factory.sol";

contract PoolManager {
    Factory public immutable factory;

    mapping(bytes32 => address[]) public poolsByKey;
    address[] public allPools;

    event PoolRegistered(address indexed pool);

    constructor(address _factory) {
        factory = Factory(_factory);
    }

    function _key(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(t0, t1, fee));
    }

    function createPool(address tokenA, address tokenB, uint24 fee, uint256 price, uint256 priceLower, uint256 priceUpper) external returns (address pool) {
        pool = factory.createPool(tokenA, tokenB, fee, price, priceLower, priceUpper);
        bytes32 k = _key(tokenA, tokenB, fee);
        poolsByKey[k].push(pool);
        allPools.push(pool);
        emit PoolRegistered(pool);
    }

    function getPools(address tokenA, address tokenB, uint24 fee) external view returns (address[] memory) {
        return poolsByKey[_key(tokenA, tokenB, fee)];
    }

    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }
}

