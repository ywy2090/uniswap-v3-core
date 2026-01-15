# Uniswap V3 开发者学习路线图

> 从入门到精通的循序渐进指南，适合有一定 Solidity 基础的开发者

---

## 学习路线总览

```
第一阶段：基础夯实（2~3 周）
    └── Solidity 进阶 + DeFi 基础 + AMM 原理

第二阶段：读懂 Core（3~4 周）
    └── 数学库 → 数据结构 → 流动性管理 → 交易执行

第三阶段：动手实验（2~3 周）
    └── 跑通测试 → 修改参数 → 编写集成测试

第四阶段：Periphery 与集成（3~4 周）
    └── NonfungiblePositionManager → Router → Quoter → 自己写调用合约

第五阶段：深水区（持续）
    └── 预言机 · MEV · Gas 优化 · 安全审计 · 协议改进
```

---

## 第一阶段：基础夯实

### 1.1 Solidity 进阶知识

学习 V3 代码前，必须牢固掌握以下 Solidity 特性（V3 大量使用）：

**存储布局与 Gas 优化**

```solidity
// V3 将 7 个字段打包进一个 32 字节存储槽（节省约 6 次 SLOAD）
struct Slot0 {
    uint160 sqrtPriceX96;    // 20 bytes
    int24   tick;            // 3 bytes
    uint16  observationIndex;// 2 bytes
    uint16  observationCardinality;       // 2 bytes
    uint16  observationCardinalityNext;   // 2 bytes
    uint8   feeProtocol;     // 1 byte
    bool    unlocked;        // 1 byte
}                            // 总计 31 bytes，刚好一个槽
```

需要掌握的知识点：
- 变量打包规则（相邻变量共享存储槽）
- `memory` vs `storage` vs `calldata` 的 gas 差异
- `SLOAD`（冷读取 2100 gas）vs `MLOAD`（3 gas）

**内联汇编（inline assembly）**

V3 的 `TickMath.getTickAtSqrtRatio()` 大量使用汇编计算对数：

```solidity
assembly {
    let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
    msb := or(msb, f)
    r := shr(f, r)
}
```

学习重点：`shl`、`shr`、`gt`、`or`、`mul`、`div` 等 EVM 操作码语义。

**回调模式（Callback Pattern）**

V3 的 mint/swap/flash 均采用"先执行后收款"的回调模式：

```solidity
// 1. 池先计算需要多少代币
// 2. 调用 msg.sender 的回调，要求转入代币
IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
// 3. 用余额变化验证，而非信任返回值
require(balance0Before.add(amount0) <= balance0(), 'M0');
```

这是一种"乐观转账"模式，理解它是理解 Flash Loan 的关键。

**定点数（Fixed Point Numbers）**

| 格式 | 含义 | V3 中的用途 |
|------|------|------------|
| Q64.96 | 整数部分 64 位，小数部分 96 位 | `sqrtPriceX96` |
| Q128.128 | 整数部分 128 位，小数部分 128 位 | `TickMath` 内部计算 |
| X128 | ×2¹²⁸ 的整数表示 | `feeGrowthGlobal0X128` |

```solidity
// Q64.96 格式：sqrtPrice * 2^96
// 实际价格 = (sqrtPriceX96 / 2^96)^2
uint256 actualPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> (96 * 2);
```

**推荐学习资源：**
- [Solidity by Example](https://solidity-by-example.org/)
- [EVM Deep Dives（noxx 系列）](https://noxx.substack.com/p/evm-deep-dives-the-path-to-shadowy)
- [Solidity Gas 优化技巧（Rareskills）](https://www.rareskills.io/post/gas-optimization)

---

### 1.2 DeFi 与 AMM 基础

**必须先理解 Uniswap V2**（V3 是 V2 的演进）：

核心概念检查清单：
- [ ] 恒积公式 $x \cdot y = k$ 的推导
- [ ] 无常损失（Impermanent Loss）的本质
- [ ] LP Token 的铸造与赎回机制
- [ ] 价格影响（Price Impact）与滑点（Slippage）的区别
- [ ] 套利（Arbitrage）如何维持 AMM 价格与市场价格一致

**推荐学习顺序：**

1. 阅读 [Uniswap V2 白皮书](https://uniswap.org/whitepaper.pdf)（仅 8 页）
2. 阅读 [V2 Core 合约](https://github.com/Uniswap/v2-core)（仅 3 个合约，代码量极少）
3. 再阅读 [Uniswap V3 白皮书](https://uniswap.org/whitepaper-v3.pdf)（重点：Section 2, 6）

---

## 第二阶段：逐层读懂 Core 代码

### 推荐阅读顺序（从简单到复杂）

```
工具库（无业务逻辑）
    ↓
数学库（纯计算）
    ↓
数据结构库（状态管理）
    ↓
核心 Pool 合约
```

### 2.1 第一层：工具库（1~2 天）

这些库最简单，可以热身：

| 文件 | 功能 | 学习重点 |
|------|------|---------|
| `LowGasSafeMath.sol` | 溢出检查的加减法 | 为何要自己实现（Solidity 0.8 之前无内置检查） |
| `SafeCast.sol` | 安全类型转换 | `uint256` → `uint128` 时的截断风险 |
| `FullMath.sol` | 512 位精度乘除法 | `mulDiv`：避免 256 位乘法溢出的技巧 |
| `BitMath.sol` | 最高/最低有效位 | 用于 `TickBitmap` 的位扫描 |
| `UnsafeMath.sol` | 不检查溢出的除法 | 在已知安全时节省 gas |
| `FixedPoint96/128.sol` | 常量定义 | Q64.96 和 X128 格式的基准值 |

**动手实践**：运行对应的单元测试，观察边界值行为：

```bash
# 在项目根目录
npx hardhat test test/FullMath.spec.ts
npx hardhat test test/BitMath.spec.ts
```

---

### 2.2 第二层：数学库（3~4 天）

#### `TickMath.sol`：Tick ↔ 价格转换

**学习目标**：理解为何用二进制分解计算 $1.0001^{tick}$

```
思路：tick 的每个二进制位对应 1.0001^(2^k)
      先预计算所有 1.0001^(2^k) 的值，
      然后根据 tick 的位模式逐位相乘，
      等价于 O(log tick) 的幂运算，实际常数为 20 步
```

验证方法（在 `test/TickMath.spec.ts` 中）：

```typescript
// 测试关键价格点的转换
it('getSqrtRatioAtTick', async () => {
    expect(await tickMath.getSqrtRatioAtTick(0)).to.eq(
        BigNumber.from('79228162514264337593543950336')  // = 2^96
    )
    // 价格为 1 时，sqrt(1) * 2^96 = 2^96
})
```

**动手实践**：

```typescript
// 自己实现 tickToPrice 的 JS 版本，与合约结果对比
function tickToSqrtPrice(tick: number): bigint {
    return BigInt(Math.round(Math.sqrt(1.0001 ** tick) * 2 ** 96))
}
```

#### `SqrtPriceMath.sol`：代币数量计算

**两个核心公式**（务必手推一遍）：

$$\Delta x = L \cdot \frac{\sqrt{P_b} - \sqrt{P_a}}{\sqrt{P_a} \cdot \sqrt{P_b}} \quad \text{（token0 数量）}$$

$$\Delta y = L \cdot (\sqrt{P_b} - \sqrt{P_a}) \quad \text{（token1 数量）}$$

为何 token0 的公式更复杂？因为 token0 数量正比于 $1/\sqrt{P}$，而非 $\sqrt{P}$。

**验证**：

```bash
npx hardhat test test/SqrtPriceMath.spec.ts
```

#### `SwapMath.sol`：单步交易计算

最重要的函数是 `computeSwapStep()`，理解其四种情况：

```
exactIn  + 未达到目标价格 → 价格停在中间，余量全部算费用
exactIn  + 达到目标价格  → 价格移动到目标，费用按比例计算
exactOut + 未达到目标价格 → 类似
exactOut + 达到目标价格  → 类似
```

---

### 2.3 第三层：数据结构库（3~4 天）

#### `Tick.sol`：理解 liquidityNet 的设计

**最关键的洞察**：`liquidityNet` 是一种**差分编码**。

与其存储每个区间的流动性总量（需要扫描所有重叠区间），不如存储每个 tick 处的流动性**变化量**：

```
流动性变化（liquidityNet）:
         +100  +200  -50   -250
          ↓     ↓     ↓     ↓
  ────────|─────|─────|─────|────→ 价格
         1000  1500  2000  2500

当前在 1800 处的活跃流动性 = 累加到 1800 的所有 liquidityNet
= 100 + 200 = 300

移动到 1600 时（越过 1000 tick）：
= 300 - 100 = 200
```

**`getFeeGrowthInside()` 的数学原理**：

```
设 feeGrowthGlobal 为全局总费用
设 feeGrowthBelow  为 tickLower 下方的费用（用 outside 推算）
设 feeGrowthAbove  为 tickUpper 上方的费用（用 outside 推算）

则区间内费用 = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove

"outside" 字段在价格跨越 tick 时取反，
保证无论当前价格在哪里，above/below 都能正确推算
```

#### `TickBitmap.sol`：理解位图压缩

```
tick 空间有 887272*2 ≈ 180 万个位置，
但已初始化的 tick 通常只有几十到几百个。

TickBitmap 用 int16 → uint256 的映射：
  - int16 是"字的索引"（256 个 tick 为一组）
  - uint256 的每一位对应一个 tick 的初始化状态

查找下一个初始化的 tick = 在一个 uint256 中找最近的 1 位
→ 用 BitMath 的位扫描函数，O(1) 完成
```

#### `Position.sol`：头寸费用结算

重点理解 `update()` 函数中的费用结算逻辑：

```solidity
// Position.sol: 60-76
uint128 tokensOwed0 = uint128(
    FullMath.mulDiv(
        feeGrowthInside0X128 - self.feeGrowthInside0LastX128,  // 区间内费用增量
        self.liquidity,                                          // LP 的流动性份额
        FixedPoint128.Q128                                       // 归一化
    )
);
```

这个公式保证了费用按流动性**比例**分配，且无论多长时间未结算都能一次性补齐。

---

### 2.4 第四层：核心 Pool 合约（1 周）

**推荐阅读顺序**：

```
initialize() → 理解初始化
    ↓
mint() → _modifyPosition() → _updatePosition()  → 理解流动性管理
    ↓
swap() 的状态机  → 理解交易执行（最复杂，需要多读几遍）
    ↓
burn() + collect()  → 理解退出和费用提取
    ↓
flash()  → 理解闪电贷（最简单）
```

**读 swap() 的技巧**：

用状态机图辅助理解 while 循环：

```
[开始]
  ↓
[找到下一个 tick] ←─────────────────────┐
  ↓                                     │
[computeSwapStep：单步计算]              │
  ↓                                     │
[更新 amountRemaining, feeGrowth]       │
  ↓                                     │
[到达 tick 边界？]                       │
  ├── 否 → [更新 tick]                  │
  │          ↓                          │
  │        [amountRemaining == 0？]     │
  │          ├── 是 → [结束]            │
  │          └── 否 ──────────────────→─┤
  └── 是 → [cross tick，更新流动性]      │
             ↓                          │
           [amountRemaining == 0？]     │
             ├── 是 → [结束]            │
             └── 否 ──────────────────→─┘
```

---

## 第三阶段：动手实验

### 3.1 搭建本地开发环境

```bash
# 克隆仓库
git clone https://github.com/Uniswap/v3-core
cd v3-core
yarn install

# 编译合约
npx hardhat compile

# 运行全部测试（约需 3~5 分钟）
npx hardhat test

# 运行单个测试文件
npx hardhat test test/UniswapV3Pool.spec.ts
npx hardhat test test/UniswapV3Pool.swaps.spec.ts

# 查看 gas 消耗报告
npx hardhat test test/UniswapV3Pool.gas.spec.ts
```

### 3.2 理解测试辅助工具

学习 `test/shared/utilities.ts` 中的关键工具函数：

```typescript
// 将价格编码为 sqrtPriceX96 格式（测试中常用）
// reserve1/reserve0 = token1/token0 的比值 = 价格
export function encodePriceSqrt(reserve1, reserve0): BigNumber {
    return BigNumber.from(
        new bn(reserve1.toString())
            .div(reserve0.toString())
            .sqrt()
            .multipliedBy(new bn(2).pow(96))
            .integerValue(3)
            .toString()
    )
}
// 例：ETH/USDC 价格 2000 → encodePriceSqrt(2000, 1)

// 获取给定 tickSpacing 下的最小/最大 tick
export const getMinTick = (tickSpacing) => Math.ceil(-887272 / tickSpacing) * tickSpacing
export const getMaxTick = (tickSpacing) => Math.floor(887272 / tickSpacing) * tickSpacing

// 计算头寸的存储 key
export function getPositionKey(address, lowerTick, upperTick): string {
    return utils.keccak256(
        utils.solidityPack(['address', 'int24', 'int24'], [address, lowerTick, upperTick])
    )
}
```

### 3.3 动手实验清单

按照以下顺序，在 Hardhat 测试中编写实验代码：

**实验 1：初始化池并添加流动性**

```typescript
// 目标：理解 mint 的代币计算
it('实验1: 不同价格区间的代币比例', async () => {
    // 初始化价格为 1:1
    await pool.initialize(encodePriceSqrt(1, 1))

    // 实验 A：在当前价格处添加流动性（双边存入）
    await mint(wallet.address, -60, 60, expandTo18Decimals(1))

    // 实验 B：在当前价格左侧添加流动性（只需 token0）
    await mint(wallet.address, -120, -60, expandTo18Decimals(1))

    // 实验 C：在当前价格右侧添加流动性（只需 token1）
    await mint(wallet.address, 60, 120, expandTo18Decimals(1))

    // 观察：三种情况下 amount0 和 amount1 的不同
})
```

**实验 2：观察 tick 跨越时的流动性变化**

```typescript
it('实验2: swap 跨越 tick 时流动性的变化', async () => {
    await pool.initialize(encodePriceSqrt(1, 1))
    // 在 [-120, 120] 和 [-60, 60] 分别添加流动性
    await mint(wallet.address, -120, 120, expandTo18Decimals(1))
    await mint(wallet.address, -60, 60, expandTo18Decimals(1))

    // 当前价格在两个区间内，流动性叠加
    console.log('交易前流动性:', (await pool.liquidity()).toString())

    // 执行大额交易，让价格超出内层区间 [-60, 60]
    await swapExact0For1(expandTo18Decimals(2), wallet.address)
    // 此时内层区间的流动性已退出
    console.log('穿越内层tick后流动性:', (await pool.liquidity()).toString())

    // 继续交易，超出外层区间 [-120, 120]
    await swapExact0For1(expandTo18Decimals(10), wallet.address)
    console.log('穿越外层tick后流动性:', (await pool.liquidity()).toString())
    // 预期：0
})
```

**实验 3：手续费的计算与领取**

```typescript
it('实验3: 手续费按流动性比例分配', async () => {
    await pool.initialize(encodePriceSqrt(1, 1))

    // Alice 和 Bob 在同一区间提供等量流动性
    await mint(alice.address, -60, 60, expandTo18Decimals(1))
    await mint(bob.address, -60, 60, expandTo18Decimals(1))

    // 执行一笔交易
    await swapExact0For1(expandTo18Decimals(0.1), trader.address)

    // 分别 burn(0) + collect 查看各自应得手续费
    // 预期：Alice 和 Bob 各得约一半的手续费
})
```

**实验 4：套利场景模拟**

```typescript
// test/UniswapV3Pool.arbitrage.spec.ts 已有完整示例
// 重点理解：价格偏离时，套利者如何通过交易将价格推回市场价
```

---

## 第四阶段：Periphery 与集成开发

Core 合约仅提供原语，实际 DApp 开发需要了解 [v3-periphery](https://github.com/Uniswap/v3-periphery)。

### 4.1 Periphery 合约概览

```
v3-periphery/
├── NonfungiblePositionManager.sol  ← LP 头寸的 NFT 包装（最重要）
├── SwapRouter.sol                  ← 用户友好的交易路由
├── Quoter.sol / QuoterV2.sol       ← 链上报价（不修改状态）
├── TickLens.sol                    ← 批量读取 tick 数据
└── libraries/
    ├── LiquidityAmounts.sol        ← 流动性 ↔ 代币数量转换
    ├── PoolAddress.sol             ← CREATE2 地址计算
    └── Path.sol                    ← 多跳路径编码/解码
```

### 4.2 NonfungiblePositionManager（重点）

Core 的 Pool 合约直接管理头寸（以 `owner + tickLower + tickUpper` 为 key）。
Periphery 的 `NonfungiblePositionManager` 将每个头寸包装成 **ERC-721 NFT**，使头寸可以转让和在 DeFi 中组合。

**关键流程**：

```solidity
// 1. 添加流动性（同时铸造 NFT）
INonfungiblePositionManager.MintParams memory params = MintParams({
    token0: WETH,
    token1: USDC,
    fee: 3000,
    tickLower: -887220,  // 对应约 0 价格
    tickUpper: 887220,   // 对应约无穷大价格
    amount0Desired: 1 ether,
    amount1Desired: 2000e6,
    amount0Min: 0,
    amount1Min: 0,
    recipient: msg.sender,
    deadline: block.timestamp + 300
});
(uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
    nonfungiblePositionManager.mint(params);

// 2. 查询头寸
(, , , , , int24 tickLower, int24 tickUpper, uint128 lpLiquidity, , , , ) =
    nonfungiblePositionManager.positions(tokenId);

// 3. 增加流动性
nonfungiblePositionManager.increaseLiquidity(IncreaseLiquidityParams({
    tokenId: tokenId,
    amount0Desired: 0.5 ether,
    amount1Desired: 1000e6,
    amount0Min: 0, amount1Min: 0,
    deadline: block.timestamp + 300
}));

// 4. 减少流动性
nonfungiblePositionManager.decreaseLiquidity(DecreaseLiquidityParams({
    tokenId: tokenId,
    liquidity: lpLiquidity / 2,  // 撤出一半
    amount0Min: 0, amount1Min: 0,
    deadline: block.timestamp + 300
}));

// 5. 领取手续费（collect 参数设最大值）
nonfungiblePositionManager.collect(CollectParams({
    tokenId: tokenId,
    recipient: msg.sender,
    amount0Max: type(uint128).max,
    amount1Max: type(uint128).max
}));
```

### 4.3 SwapRouter（多跳交易）

```solidity
// 单跳交易
ISwapRouter.ExactInputSingleParams memory params = ExactInputSingleParams({
    tokenIn: WETH,
    tokenOut: USDC,
    fee: 3000,
    recipient: msg.sender,
    deadline: block.timestamp + 300,
    amountIn: 1 ether,
    amountOutMinimum: 1900e6,  // 最少收到 1900 USDC（滑点保护）
    sqrtPriceLimitX96: 0       // 不设价格上限
});
uint256 amountOut = swapRouter.exactInputSingle(params);

// 多跳交易（ETH → USDC → DAI）
bytes memory path = abi.encodePacked(
    WETH, uint24(3000), USDC, uint24(500), DAI
);
ISwapRouter.ExactInputParams memory multiHopParams = ExactInputParams({
    path: path,
    recipient: msg.sender,
    deadline: block.timestamp + 300,
    amountIn: 1 ether,
    amountOutMinimum: 1890e18  // 最少收到 1890 DAI
});
uint256 daiOut = swapRouter.exactInput(multiHopParams);
```

### 4.4 LiquidityAmounts 工具库

这是开发集成合约最常用的工具库：

```solidity
// 已知代币数量，计算最大可提供的流动性
uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
    sqrtPriceX96,           // 当前价格
    sqrtRatioAX96,          // 区间下限价格
    sqrtRatioBX96,          // 区间上限价格
    amount0,                // token0 数量
    amount1                 // token1 数量
);

// 已知流动性，计算需要多少代币
(uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
    sqrtPriceX96,
    sqrtRatioAX96,
    sqrtRatioBX96,
    liquidity
);
```

### 4.5 综合实战：编写一个 LP 管理合约

作为阶段性实战，尝试编写一个简单的"自动再平衡 LP"合约：

```
功能目标：
1. 接受用户存入的 ETH 和 USDC
2. 计算当前价格对应的最优区间（如 ±10%）
3. 调用 NonfungiblePositionManager.mint() 添加流动性
4. 提供 rebalance() 函数：当价格超出区间时，移除旧头寸，在新价格区间重新添加
5. 允许用户按比例提取本金和手续费
```

这个合约会迫使你理解：
- 如何将价格转换为 tick
- 如何计算 `amount0Desired` 和 `amount1Desired`
- approve/transferFrom 的正确时序
- rebalance 时的滑点保护

---

## 第五阶段：深水区

### 5.1 TWAP 预言机

V3 内置了无需额外部署的链上 TWAP（时间加权平均价格）预言机。

**基本用法**：

```solidity
// 获取过去 30 分钟的 TWAP 价格
uint32[] memory secondsAgos = new uint32[](2);
secondsAgos[0] = 1800;  // 30 分钟前
secondsAgos[1] = 0;     // 当前

(int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

// TWAP tick = 累积值之差 / 时间差
int56 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];
int24 arithmeticMeanTick = int24(tickCumulativeDelta / 1800);

// 将 tick 转回价格
uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
```

**深入理解**：
- 为何用 tick 的时间加权平均而非价格的加权平均？（防止操纵）
- `observationCardinality` 决定历史数据深度，需要提前扩容
- `observe()` 使用二分查找，支持任意时间点插值

### 5.2 MEV 与价格操纵防御

V3 的几个重要安全特性：

**`sqrtPriceLimitX96`（价格滑点保护）**：
```solidity
// 在 swap 中设置价格上/下限，防止大滑点
// zeroForOne = true（价格下降），设置价格不能低于 sqrtPriceLimitX96
// 设为 MIN_SQRT_RATIO + 1 表示不限制
```

**重入保护（`unlock` 标志）**：
```solidity
// slot0.unlocked 在操作开始时置 false，结束时置 true
// 任何重入调用都会在 require(slot0Start.unlocked, 'LOK') 处失败
```

**三明治攻击（Sandwich Attack）**：理解 MEV 机器人如何利用待处理交易，以及 `amountOutMinimum` 的保护作用。

### 5.3 Gas 优化分析

运行 gas 测试并分析结果：

```bash
npx hardhat test test/UniswapV3Pool.gas.spec.ts
```

V3 的主要 gas 优化技术：

| 技术 | 位置 | 节省量 |
|------|------|--------|
| Slot0 存储打包 | `UniswapV3Pool.sol` | ~6 × 2100 gas/读 |
| TickBitmap 位图 | `TickBitmap.sol` | 避免顺序扫描 |
| `noDelegateCall` | 修饰符 | 防止代理绕过，而非节省 |
| 内存缓存 slot0 | swap/mint | 避免重复 SLOAD |
| `UnsafeMath` | 已知安全处 | ~20 gas/次 |
| `unchecked` 块 | 已知安全处 | ~20 gas/次 |

### 5.4 安全审计要点

阅读 V3 的官方审计报告（在 `audits/` 目录）：

```bash
ls audits/
# abdk.pdf          - ABDK 数学审计
# tob.pdf           - Trail of Bits 审计
# samczsun.md       - 白帽发现的问题记录
```

常见安全考虑点：
- **价格操纵**：单区块内的价格可被闪贷操纵，应使用 TWAP 而非即时价格作为预言机
- **流动性为 0**：价格在 tick 边界之外时 liquidity=0，此时计算应特殊处理
- **精度截断**：所有除法向下取整（LP）或向上取整（协议），方向选择有严格约定
- **溢出设计**：`feeGrowthGlobal` 故意允许溢出（uint256 溢出需极长时间，且差值计算仍正确）

---

## 学习资源清单

### 官方资源

| 资源 | 链接 | 推荐阶段 |
|------|------|---------|
| V3 白皮书 | https://uniswap.org/whitepaper-v3.pdf | 第一阶段 |
| V3 开发者文档 | https://docs.uniswap.org/contracts/v3/overview | 第四阶段 |
| V3 Core 仓库 | https://github.com/Uniswap/v3-core | 第二阶段 |
| V3 Periphery 仓库 | https://github.com/Uniswap/v3-periphery | 第四阶段 |
| V3 SDK | https://github.com/Uniswap/v3-sdk | 第四阶段 |

### 深度解析文章

| 文章 | 作者 | 内容 |
|------|------|------|
| Uniswap v3 Core（系列） | Uniswap Blog | 官方设计说明 |
| Under the Hood of v3 AMMs | Dragonfly Research | 集中流动性原理推导 |
| A Primer on Uniswap v3 Math | Atis Elsts | 数学公式详解 |
| Liquidity Math in Uniswap v3 | Atis Elsts | 深入数学证明 |

### 视频资源

| 视频 | 平台 | 内容 |
|------|------|------|
| Uniswap V3 Code Walkthrough | YouTube | 逐行代码讲解 |
| Smart Contract Programmer - Uniswap V3 | YouTube | 合约实现讲解 |

### 实用工具

| 工具 | 用途 |
|------|------|
| [Desmos 集中流动性计算器](https://www.desmos.com/calculator/l6omp0rwnh) | 可视化流动性曲线 |
| [Uniswap V3 Fee Calculator](https://uniswapv3.flipsidecrypto.com/) | 手续费估算 |
| [Revert Finance](https://revert.finance/) | LP 头寸分析 |
| [Etherscan + V3 Pool](https://etherscan.io/address/0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8) | 直接读取链上池状态 |

---

## 阶段性自测清单

### 第二阶段结束时，应能回答：

- [ ] 为什么 V3 使用 `sqrtPrice` 而不是直接存储价格？
- [ ] `liquidityNet` 为什么等于上下界 tick 处的流动性变化量？
- [ ] 当 swap 跨越 tick 时，`feeGrowthOutside` 为什么要取反？
- [ ] `FullMath.mulDiv` 相比直接 `a * b / c` 解决了什么问题？
- [ ] `encodePriceSqrt(2000, 1)` 计算出来是什么值？为什么？

### 第三阶段结束时，应能回答：

- [ ] 如果在 `tickLower = -887220`（最小 tick）处添加流动性，需要存入多少 token0？
- [ ] 运行 `UniswapV3Pool.swaps.spec.ts` 中的某个测试用例，手动计算预期结果并验证
- [ ] Pool 的 `observations` 数组存储什么数据？默认长度是多少？如何扩展？

### 第四阶段结束时，应能回答：

- [ ] 如何仅用 Periphery 合约，在 Hardhat 测试中完整执行一次 mint → swap → collect 流程？
- [ ] `tickLower` 和 `tickUpper` 必须满足什么约束（与 tickSpacing 的关系）？
- [ ] `QuoterV2` 为什么不会修改链上状态，但又能模拟真实交易结果？

---

## 推荐学习时间表

| 周次 | 内容 | 产出 |
|------|------|------|
| 第 1 周 | Solidity 进阶 + V2 代码 | 能解释 V2 的完整流程 |
| 第 2 周 | 阅读 V3 白皮书 + 工具库 | 理解定点数、全部工具库测试通过 |
| 第 3 周 | 数学库（TickMath/SqrtPriceMath/SwapMath） | 能手动推算代币数量 |
| 第 4 周 | 数据结构库（Tick/TickBitmap/Position） | 理解 liquidityNet 和费用计算 |
| 第 5-6 周 | UniswapV3Pool.sol 全文 + 动手实验 | 完成 4 个实验，能解释 swap 循环 |
| 第 7-8 周 | Periphery 合约 + 集成开发 | 写出可用的 LP 管理合约 |
| 第 9 周起 | MEV/预言机/安全/Gas 优化 | 参与审计或 Protocol 改进 |
