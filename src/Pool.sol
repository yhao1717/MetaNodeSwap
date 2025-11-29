// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint256 public immutable price;
    uint256 public immutable priceLower;
    uint256 public immutable priceUpper;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public unclaimedFee0;
    uint256 public unclaimedFee1;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public feePerShare0;
    uint256 public feePerShare1;
    mapping(address => uint256) public feeDebt0;
    mapping(address => uint256) public feeDebt1;

    bool private locked;

    event Mint(address indexed provider, uint256 added0, uint256 added1, uint256 shares);
    event Burn(address indexed provider, uint256 shares, uint256 amount0, uint256 amount1);
    event Collect(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, address indexed tokenIn, uint256 amountInGross, uint256 amountOut, address indexed to);

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        uint256 _price,
        uint256 _priceLower,
        uint256 _priceUpper
    ) {
        require(_token0 != _token1, "IDENTICAL");
        require(_token0 != address(0) && _token1 != address(0), "ZERO");
        require(_priceLower <= _price && _price <= _priceUpper, "PRICE_RANGE");
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        price = _price;
        priceLower = _priceLower;
        priceUpper = _priceUpper;
    }

    modifier nonReentrant() {
        require(!locked, "LOCKED");
        locked = true;
        _;
        locked = false;
    }

    function _balance0() internal view returns (uint256) {
        return IERC20(token0).balanceOf(address(this));
    }

    function _balance1() internal view returns (uint256) {
        return IERC20(token1).balanceOf(address(this));
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function quoteExactIn(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint256 feeAmount) {
        require(priceLower <= price && price <= priceUpper, "OUT_OF_RANGE");
        require(totalShares > 0, "NO_LIQUIDITY");
        feeAmount = (amountIn * fee) / 1_000_000;
        uint256 netIn = amountIn - feeAmount;
        if (tokenIn == token0) {
            amountOut = (netIn * price) / 1e18;
        } else if (tokenIn == token1) {
            amountOut = (netIn * 1e18) / price;
        } else {
            revert("TOKEN");
        }
    }

    function quoteExactOut(address tokenIn, uint256 amountOut) external view returns (uint256 amountInGross, uint256 feeAmount) {
        require(priceLower <= price && price <= priceUpper, "OUT_OF_RANGE");
        require(totalShares > 0, "NO_LIQUIDITY");
        uint256 netIn;
        if (tokenIn == token0) {
            netIn = _divUp(amountOut * 1e18, price);
        } else if (tokenIn == token1) {
            netIn = _divUp(amountOut * price, 1e18);
        } else {
            revert("TOKEN");
        }
        amountInGross = _divUp(netIn * 1_000_000, 1_000_000 - fee);
        feeAmount = amountInGross - netIn;
    }

    function mintLiquidity(address to) external nonReentrant returns (uint256 sharesMinted, uint256 added0, uint256 added1) {
        uint256 bal0 = _balance0();
        uint256 bal1 = _balance1();
        added0 = bal0 - (reserve0 + unclaimedFee0);
        added1 = bal1 - (reserve1 + unclaimedFee1);
        require(added0 > 0 || added1 > 0, "NO_ADD");
        uint256 totalValue = reserve0 + ((reserve1 * 1e18) / price);
        uint256 addValue = added0 + ((added1 * 1e18) / price);
        if (totalShares == 0) {
            sharesMinted = addValue;
        } else {
            sharesMinted = (addValue * totalShares) / totalValue;
        }
        require(sharesMinted > 0, "ZERO_SHARES");
        sharesOf[to] += sharesMinted;
        totalShares += sharesMinted;
        reserve0 += added0;
        reserve1 += added1;
        emit Mint(to, added0, added1, sharesMinted);
    }

    function burnLiquidity(address from, uint256 sharesBurn, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(sharesOf[from] >= sharesBurn && sharesBurn > 0, "SHARES");
        amount0 = (reserve0 * sharesBurn) / totalShares;
        amount1 = (reserve1 * sharesBurn) / totalShares;
        sharesOf[from] -= sharesBurn;
        totalShares -= sharesBurn;
        reserve0 -= amount0;
        reserve1 -= amount1;
        require(IERC20(token0).transfer(to, amount0), "T0");
        require(IERC20(token1).transfer(to, amount1), "T1");
        emit Burn(from, sharesBurn, amount0, amount1);
    }

    function collectFees(address provider, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 s = sharesOf[provider];
        uint256 accrued0 = (s * feePerShare0) / 1e18;
        uint256 accrued1 = (s * feePerShare1) / 1e18;
        amount0 = accrued0 - feeDebt0[provider];
        amount1 = accrued1 - feeDebt1[provider];
        if (amount0 > 0) {
            feeDebt0[provider] += amount0;
            require(unclaimedFee0 >= amount0, "FEE0");
            unclaimedFee0 -= amount0;
            require(IERC20(token0).transfer(to, amount0), "F0");
        }
        if (amount1 > 0) {
            feeDebt1[provider] += amount1;
            require(unclaimedFee1 >= amount1, "FEE1");
            unclaimedFee1 -= amount1;
            require(IERC20(token1).transfer(to, amount1), "F1");
        }
        emit Collect(provider, amount0, amount1);
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) external nonReentrant returns (uint256 amountOut, uint256 amountInUsed) {
        require(priceLower <= price && price <= priceUpper, "OUT_OF_RANGE");
        require(tokenIn == token0 || tokenIn == token1, "TOKEN");
        require(totalShares > 0, "NO_LIQUIDITY");
        uint256 balIn = tokenIn == token0 ? _balance0() : _balance1();
        uint256 heldIn = tokenIn == token0 ? (reserve0 + unclaimedFee0) : (reserve1 + unclaimedFee1);
        uint256 grossIn = balIn - heldIn;
        require(grossIn == amountIn && grossIn > 0, "INPUT_DELTA");
        uint256 feeAmount = (grossIn * fee) / 1_000_000;
        uint256 netIn = grossIn - feeAmount;
        if (tokenIn == token0) {
            uint256 outByIn = (netIn * price) / 1e18;
            uint256 maxOut = reserve1;
            if (outByIn > maxOut) {
                amountOut = maxOut;
                uint256 netUsed = _divUp(amountOut * 1e18, price);
                amountInUsed = _divUp(netUsed * 1_000_000, 1_000_000 - fee);
                feeAmount = amountInUsed - netUsed;
                require(amountInUsed <= grossIn, "AMOUNT_IN");
                netIn = netUsed;
            } else {
                amountOut = outByIn;
                amountInUsed = grossIn;
            }
            require(amountOut >= minOut, "SLIPPAGE");
            reserve0 += netIn;
            unclaimedFee0 += feeAmount;
            reserve1 -= amountOut;
            feePerShare0 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token1).transfer(to, amountOut), "OUT1");
        } else {
            uint256 outByIn = (netIn * 1e18) / price;
            uint256 maxOut = reserve0;
            if (outByIn > maxOut) {
                amountOut = maxOut;
                uint256 netUsed = _divUp(amountOut * price, 1e18);
                amountInUsed = _divUp(netUsed * 1_000_000, 1_000_000 - fee);
                feeAmount = amountInUsed - netUsed;
                require(amountInUsed <= grossIn, "AMOUNT_IN");
                netIn = netUsed;
            } else {
                amountOut = outByIn;
                amountInUsed = grossIn;
            }
            require(amountOut >= minOut, "SLIPPAGE");
            reserve1 += netIn;
            unclaimedFee1 += feeAmount;
            reserve0 -= amountOut;
            feePerShare1 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token0).transfer(to, amountOut), "OUT0");
        }
        emit Swap(msg.sender, tokenIn, amountInUsed, amountOut, to);
    }

    function swapExactOut(address tokenIn, uint256 amountOut, uint256 maxIn, address to) external nonReentrant returns (uint256 amountInGross, uint256 amountOutActual) {
        require(priceLower <= price && price <= priceUpper, "OUT_OF_RANGE");
        require(tokenIn == token0 || tokenIn == token1, "TOKEN");
        require(totalShares > 0, "NO_LIQUIDITY");
        if (tokenIn == token0) {
            uint256 maxOut = reserve1;
            uint256 balIn = _balance0();
            uint256 heldIn = reserve0 + unclaimedFee0;
            uint256 grossDelta = balIn - heldIn;
            uint256 netFromDelta = (grossDelta * (1_000_000 - fee)) / 1_000_000;
            uint256 outByDelta = (netFromDelta * price) / 1e18;
            amountOutActual = amountOut;
            if (amountOutActual > outByDelta) amountOutActual = outByDelta;
            if (amountOutActual > maxOut) amountOutActual = maxOut;
            uint256 netNeeded = _divUp(amountOutActual * 1e18, price);
            amountInGross = _divUp(netNeeded * 1_000_000, 1_000_000 - fee);
            require(amountInGross <= maxIn, "MAX_IN");
            require(amountInGross <= grossDelta, "INSUFFICIENT_IN");
            uint256 refund = grossDelta - amountInGross;
            if (refund > 0) {
                require(IERC20(token0).transfer(msg.sender, refund), "REFUND0");
            }
            uint256 feeAmount = amountInGross - netNeeded;
            reserve0 += netNeeded;
            unclaimedFee0 += feeAmount;
            reserve1 -= amountOutActual;
            feePerShare0 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token1).transfer(to, amountOutActual), "OUT1");
        } else {
            uint256 maxOut = reserve0;
            uint256 balIn = _balance1();
            uint256 heldIn = reserve1 + unclaimedFee1;
            uint256 grossDelta = balIn - heldIn;
            uint256 netFromDelta = (grossDelta * (1_000_000 - fee)) / 1_000_000;
            uint256 outByDelta = (netFromDelta * 1e18) / price;
            amountOutActual = amountOut;
            if (amountOutActual > outByDelta) amountOutActual = outByDelta;
            if (amountOutActual > maxOut) amountOutActual = maxOut;
            uint256 netNeeded = _divUp(amountOutActual * price, 1e18);
            amountInGross = _divUp(netNeeded * 1_000_000, 1_000_000 - fee);
            require(amountInGross <= maxIn, "MAX_IN");
            require(amountInGross <= grossDelta, "INSUFFICIENT_IN");
            uint256 refund = grossDelta - amountInGross;
            if (refund > 0) {
                require(IERC20(token1).transfer(msg.sender, refund), "REFUND1");
            }
            uint256 feeAmount = amountInGross - netNeeded;
            reserve1 += netNeeded;
            unclaimedFee1 += feeAmount;
            reserve0 -= amountOutActual;
            feePerShare1 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token0).transfer(to, amountOutActual), "OUT0");
        }
        emit Swap(msg.sender, tokenIn, amountInGross, amountOutActual, to);
    }
}
