// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

contract Pool is ERC721 {
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
    mapping(uint256 => uint256) public sharesOfToken;
    uint256 public feePerShare0;
    uint256 public feePerShare1;
    mapping(uint256 => uint256) public feeDebt0Token;
    mapping(uint256 => uint256) public feeDebt1Token;
    uint256 public nextTokenId;

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
    ) ERC721("MetaNode LP", "MNLP") {
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

    function currentPrice() public view returns (uint256) {
        if (reserve0 == 0 || reserve1 == 0) {
            return price;
        }
        return (reserve1 * 1e18) / reserve0;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }

    function quoteExactIn(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint256 feeAmount) {
        require(totalShares > 0, "NO_LIQUIDITY");
        feeAmount = (amountIn * fee) / 1_000_000;
        uint256 netIn = amountIn - feeAmount;
        uint256 R0 = reserve0;
        uint256 R1 = reserve1;
        if (tokenIn == token0) {
            uint256 k = R0 * R1;
            amountOut = R1 - (k / (R0 + netIn));
        } else if (tokenIn == token1) {
            uint256 k = R0 * R1;
            amountOut = R0 - (k / (R1 + netIn));
        } else {
            revert("TOKEN");
        }
    }

    function quoteExactOut(address tokenIn, uint256 amountOut) external view returns (uint256 amountInGross, uint256 feeAmount) {
        require(totalShares > 0, "NO_LIQUIDITY");
        uint256 R0 = reserve0;
        uint256 R1 = reserve1;
        uint256 outActual = amountOut;
        uint256 netIn;
        if (tokenIn == token0) {
            if (outActual >= R1) outActual = R1 - 1;
            netIn = _divUp(R0 * outActual, R1 - outActual);
        } else if (tokenIn == token1) {
            if (outActual >= R0) outActual = R0 - 1;
            netIn = _divUp(R1 * outActual, R0 - outActual);
        } else {
            revert("TOKEN");
        }
        amountInGross = _divUp(netIn * 1_000_000, 1_000_000 - fee);
        feeAmount = amountInGross - netIn;
    }

    function mintLiquidity(address to) external nonReentrant returns (uint256 tokenId, uint256 sharesMinted, uint256 added0, uint256 added1) {
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
        tokenId = ++nextTokenId;
        _mint(to, tokenId);
        sharesOfToken[tokenId] = sharesMinted;
        feeDebt0Token[tokenId] = (sharesMinted * feePerShare0) / 1e18;
        feeDebt1Token[tokenId] = (sharesMinted * feePerShare1) / 1e18;
        totalShares += sharesMinted;
        reserve0 += added0;
        reserve1 += added1;
        emit Mint(to, added0, added1, sharesMinted);
    }

    function burnLiquidity(uint256 tokenId, uint256 sharesBurn, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "NOT_OWNER");
        uint256 sBefore = sharesOfToken[tokenId];
        require(sBefore >= sharesBurn && sharesBurn > 0, "SHARES");
        amount0 = (reserve0 * sharesBurn) / totalShares;
        amount1 = (reserve1 * sharesBurn) / totalShares;
        uint256 sAfter = sBefore - sharesBurn;
        sharesOfToken[tokenId] = sAfter;
        uint256 d0 = feeDebt0Token[tokenId];
        uint256 d1 = feeDebt1Token[tokenId];
        totalShares -= sharesBurn;
        if (sAfter == 0) {
            delete feeDebt0Token[tokenId];
            delete feeDebt1Token[tokenId];
            _burn(tokenId);
        } else {
            feeDebt0Token[tokenId] = (d0 * sAfter) / sBefore;
            feeDebt1Token[tokenId] = (d1 * sAfter) / sBefore;
        }
        reserve0 -= amount0;
        reserve1 -= amount1;
        require(IERC20(token0).transfer(to, amount0), "T0");
        require(IERC20(token1).transfer(to, amount1), "T1");
        emit Burn(ownerOf(tokenId), sharesBurn, amount0, amount1);
    }

    function collectFees(uint256 tokenId, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "NOT_OWNER");
        uint256 s = sharesOfToken[tokenId];
        uint256 accrued0 = (s * feePerShare0) / 1e18;
        uint256 accrued1 = (s * feePerShare1) / 1e18;
        uint256 d0 = feeDebt0Token[tokenId];
        uint256 d1 = feeDebt1Token[tokenId];
        if (accrued0 > d0) {
            amount0 = accrued0 - d0;
            feeDebt0Token[tokenId] = accrued0;
            require(unclaimedFee0 >= amount0, "FEE0");
            unclaimedFee0 -= amount0;
            require(IERC20(token0).transfer(to, amount0), "F0");
        }
        if (accrued1 > d1) {
            amount1 = accrued1 - d1;
            feeDebt1Token[tokenId] = accrued1;
            require(unclaimedFee1 >= amount1, "FEE1");
            unclaimedFee1 -= amount1;
            require(IERC20(token1).transfer(to, amount1), "F1");
        }
        emit Collect(ownerOf(tokenId), amount0, amount1);
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) external nonReentrant returns (uint256 amountOut, uint256 amountInUsed) {
        require(tokenIn == token0 || tokenIn == token1, "TOKEN");
        require(totalShares > 0, "NO_LIQUIDITY");
        uint256 balIn = tokenIn == token0 ? _balance0() : _balance1();
        uint256 heldIn = tokenIn == token0 ? (reserve0 + unclaimedFee0) : (reserve1 + unclaimedFee1);
        uint256 grossIn = balIn - heldIn;
        require(grossIn == amountIn && grossIn > 0, "INPUT_DELTA");
        uint256 feeAmount = (grossIn * fee) / 1_000_000;
        uint256 netIn = grossIn - feeAmount;
        if (tokenIn == token0) {
            uint256 R0 = reserve0;
            uint256 R1 = reserve1;
            uint256 k = R0 * R1;
            uint256 outByIn = R1 - (k / (R0 + netIn));
            uint256 maxOut = R1;
            if (outByIn > maxOut) outByIn = maxOut;
            amountOut = outByIn;
            uint256 netUsed = _divUp(R0 * amountOut, R1 - amountOut);
            if (netUsed > netIn) netUsed = netIn;
            amountInUsed = _divUp(netUsed * 1_000_000, 1_000_000 - fee);
            require(amountInUsed <= grossIn, "AMOUNT_IN");
            uint256 refund = grossIn - amountInUsed;
            if (refund > 0) {
                require(IERC20(token0).transfer(msg.sender, refund), "REFUND0");
            }
            feeAmount = amountInUsed - netUsed;
            require(amountOut >= minOut, "SLIPPAGE");
            reserve0 += netUsed;
            unclaimedFee0 += feeAmount;
            reserve1 -= amountOut;
            feePerShare0 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token1).transfer(to, amountOut), "OUT1");
        } else {
            uint256 R0 = reserve0;
            uint256 R1 = reserve1;
            uint256 k = R0 * R1;
            uint256 outByIn = R0 - (k / (R1 + netIn));
            uint256 maxOut = R0;
            if (outByIn > maxOut) outByIn = maxOut;
            amountOut = outByIn;
            uint256 netUsed = _divUp(R1 * amountOut, R0 - amountOut);
            if (netUsed > netIn) netUsed = netIn;
            amountInUsed = _divUp(netUsed * 1_000_000, 1_000_000 - fee);
            require(amountInUsed <= grossIn, "AMOUNT_IN");
            uint256 refund = grossIn - amountInUsed;
            if (refund > 0) {
                require(IERC20(token1).transfer(msg.sender, refund), "REFUND1");
            }
            feeAmount = amountInUsed - netUsed;
            require(amountOut >= minOut, "SLIPPAGE");
            reserve1 += netUsed;
            unclaimedFee1 += feeAmount;
            reserve0 -= amountOut;
            feePerShare1 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token0).transfer(to, amountOut), "OUT0");
        }
        emit Swap(msg.sender, tokenIn, amountInUsed, amountOut, to);
    }

    function swapExactOut(address tokenIn, uint256 amountOut, uint256 maxIn, address to) external nonReentrant returns (uint256 amountInGross, uint256 amountOutActual) {
        require(tokenIn == token0 || tokenIn == token1, "TOKEN");
        require(totalShares > 0, "NO_LIQUIDITY");
        if (tokenIn == token0) {
            uint256 R0 = reserve0;
            uint256 R1 = reserve1;
            uint256 balIn = _balance0();
            uint256 heldIn = R0 + unclaimedFee0;
            uint256 grossDelta = balIn - heldIn;
            uint256 amountOutReq = amountOut;
            if (amountOutReq >= R1) amountOutReq = R1 - 1;
            uint256 netNeeded = _divUp(R0 * amountOutReq, R1 - amountOutReq);
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
            amountOutActual = amountOutReq;
            reserve1 -= amountOutActual;
            feePerShare0 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token1).transfer(to, amountOutActual), "OUT1");
        } else {
            uint256 R0 = reserve0;
            uint256 R1 = reserve1;
            uint256 balIn = _balance1();
            uint256 heldIn = R1 + unclaimedFee1;
            uint256 grossDelta = balIn - heldIn;
            uint256 amountOutReq = amountOut;
            if (amountOutReq >= R0) amountOutReq = R0 - 1;
            uint256 netNeeded = _divUp(R1 * amountOutReq, R0 - amountOutReq);
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
            amountOutActual = amountOutReq;
            reserve0 -= amountOutActual;
            feePerShare1 += (feeAmount * 1e18) / totalShares;
            require(IERC20(token0).transfer(to, amountOutActual), "OUT0");
        }
        emit Swap(msg.sender, tokenIn, amountInGross, amountOutActual, to);
    }
}
