MetaNodeSwap

**项目简介**
- 每个池子在创建时固定当前价格 `price` 并设定价格区间 `[a, b]`；所有报价与交易仅在此区间内成交。
- 相同交易对与费率可创建多个池；池子不可删除或修改。
- 任何人都可在池子规定的价格区间内添加/减少流动性，并按流动性份额领取交易手续费。
- 交易支持：指定输入（最大化输出）与指定输出（最小化输入）；如流动性不足则部分成交。

**合约架构**
- `src/Pool.sol`：底层池，维护储备 `reserve0/reserve1`、手续费累计与 LP 份额；采用常数乘积做市（x*y=k），交易价格由储备推导 `currentPrice = R1 * 1e18 / R0`；创建时的 `price` 用于等值换算 LP 份额铸造。
- `src/Factory.sol`：工厂，创建池并按地址序维护交易对一致性。
- `src/PoolManager.sol`：池管理，注册并查询同交易对+费率下的多个池。
- `src/PositionManager.sol`：LP 头寸管理（ERC721），增减流动性与领取手续费。
- `src/SwapRouter.sol`：报价与路由交易，封装指定输入与指定输出路径。

**费用模型**
- 费率 `f` 以百万分位计（如 `3000` 表示 0.30%）。
- 每笔交易在总输入上扣取手续费，累加到每股费用指标 `feePerShare{0,1}`；LP 可按份额领取，领取不影响可交易储备。

**价格与成交（CPMM）**
- 即时价格：`currentPrice = R1 * 1e18 / R0`，随储备变化而变化。
- 指定输入（Exact In）：
  - 手续费：`feeAmount = amountIn * f / 1_000_000`，净输入 `netIn = amountIn - feeAmount`
  - 输出：`out = R1 - (R0*R1)/(R0 + netIn)`（token0→token1；对称公式适用于另一方向）
  - 多余输入退款：若与该输出对应的最小净输入 `netUsed` 小于 `netIn`，退回差额；储备不足时部分成交。
- 指定输出（Exact Out）：
  - 净输入：`netIn = ceil(R0*out/(R1 - out))`（token0→token1；对称公式适用于另一方向）
  - 总输入：`amountInGross = ceil(netIn * 1_000_000 / (1_000_000 - f))`
  - 不足时部分成交并退款：若输入或储备不足，按可达输出部分成交，并退回未用的输入差额。

**快速开始**
- 构建与测试：
  - `forge build`
  - `forge test -q`

**基础用法示例**
1) 创建池（通过 `PoolManager`）
   - `createPool(tokenA, tokenB, fee, price, a, b)`；同交易对与费率可存在多个池。
2) 添加流动性（通过 `PositionManager`）
   - 先对 `PositionManager` 执行 `approve(token0, amount0)` 与 `approve(token1, amount1)`。
   - 调用 `addLiquidity(pool, amount0, amount1, to)`；返回 `(tokenId, shares, added0, added1)`；支持只添加一种代币（至少一侧 > 0）。
3) 交易（通过 `SwapRouter`）
   - 指定输入：`approve(tokenIn, amountIn)` 后调用 `swapExactIn(pool, tokenIn, amountIn, minOut, to)`。
   - 指定输出：根据报价估算输入并 `approve(tokenIn, amountInGross)`，调用 `swapExactOut(pool, tokenIn, amountOut, maxIn, to)`。
4) 减少流动性与领取手续费（通过 `PositionManager`）
   - 减少：`removeLiquidity(pool, tokenId, sharesToBurn, to)` 按份额比例赎回两币；份额清零时销毁 NFT。
   - 手续费：`collectFees(pool, tokenId, to)` 按份额领取累计费用。

**目录结构**
- `foundry.toml`：Foundry 项目配置
- `src/`：核心合约代码
- `test/`：测试合约代码
