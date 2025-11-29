MetaNodeSwap

**项目简介**
- 每个池子在创建时固定当前价格 `price` 并设定价格区间 `[a, b]`；所有报价与交易仅在此区间内成交。
- 相同交易对与费率可创建多个池；池子不可删除或修改。
- 任何人都可在池子规定的价格区间内添加/减少流动性，并按流动性份额领取交易手续费。
- 交易支持：指定输入（最大化输出）与指定输出（最小化输入）；如流动性不足则部分成交。

**合约架构**
- `src/Pool.sol`：底层池，记录 `token0/token1`、`price`、`[a,b]`、费率 `f`（单位 1e6），维护储备与 LP 份额、手续费累计，执行报价与交易。
- `src/Factory.sol`：工厂，创建池并按地址序维护交易对一致性。
- `src/PoolManager.sol`：池管理，注册并查询同交易对+费率下的多个池。
- `src/PositionManager.sol`：LP 头寸管理，增减流动性与领取手续费。
- `src/SwapRouter.sol`：报价与路由交易，封装指定输入与指定输出路径。
- `src/interfaces/IERC20.sol`：最简 ERC20 接口。

**费用模型**
- 费率 `f` 以百万分位计（如 `3000` 表示 0.30%）。
- 每笔交易在总输入上扣取手续费，累加到每股费用指标 `feePerShare{0,1}`；LP 可按份额领取，领取不影响可交易储备。

**价格与成交**
- 池的 `price` 为固定数值（单位按 18 位精度换算），仅当 `priceLower <= price <= priceUpper` 时允许报价与成交。
- 指定输入：超出对侧储备时按储备上限部分成交；指定输出：在输入或储备不足时部分成交，并退回未用的输入差额。

**快速开始**
- 构建与测试：
  - `forge build`
  - `forge test -q`

**基础用法示例**
1) 创建池（通过 `PoolManager`）
   - `createPool(tokenA, tokenB, fee, price, a, b)`；同交易对与费率可存在多个池。
2) 添加流动性（通过 `PositionManager`）
   - 先对 `PositionManager` 执行 `approve(token0, amount0)` 与 `approve(token1, amount1)`。
   - 调用 `addLiquidity(pool, amount0, amount1, to)`；池端按当前等值比例铸造份额。
3) 交易（通过 `SwapRouter`）
   - 指定输入：`approve(tokenIn, amountIn)` 后调用 `swapExactIn(pool, tokenIn, amountIn, minOut, to)`。
   - 指定输出：根据报价估算输入并 `approve(tokenIn, amountInGross)`，调用 `swapExactOut(pool, tokenIn, amountOut, maxIn, to)`。
4) 减少流动性与领取手续费（通过 `PositionManager`）
   - 减少：`removeLiquidity(pool, shares, to)` 按份额比例赎回两币。
   - 手续费：`collectFees(pool, to)` 按份额领取累计费用。

**目录结构**
- `foundry.toml`：Foundry 项目配置
- `src/`：核心合约代码
- `test/`：测试合约代码