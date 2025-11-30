// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pool} from "./Pool.sol";

contract PositionManager {
    function addLiquidity(address pool, uint256 amount0, uint256 amount1, address to) external returns (uint256 tokenId, uint256 shares, uint256 added0, uint256 added1) {
        Pool p = Pool(pool);
        address token0 = p.token0();
        address token1 = p.token1();
        if (amount0 > 0) {
            require(IERC20(token0).transferFrom(msg.sender, pool, amount0), "T0");
        }
        if (amount1 > 0) {
            require(IERC20(token1).transferFrom(msg.sender, pool, amount1), "T1");
        }
        (tokenId, shares, added0, added1) = p.mintLiquidity(to);
    }

    function removeLiquidity(address pool, uint256 tokenId, uint256 shares, address to) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = Pool(pool).burnLiquidity(tokenId, shares, to);
    }

    function collectFees(address pool, uint256 tokenId, address to) external returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = Pool(pool).collectFees(tokenId, to);
    }
}
