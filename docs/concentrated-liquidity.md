# Uniswap V3 集中流动性深度解析

> 基于 [uniswap-v3-core](https://github.com/Uniswap/v3-core) 源码分析

---

## 目录

1. [核心原理](#一核心原理)
   - 1.1 从 V2 到 V3 的演进
   - 1.2 集中流动性的数学模型
   - 1.3 虚拟储备与真实储备
   - 1.4 价格表示：sqrtPriceX96
2. [Tick 系统](#二tick-系统)
   - 2.1 Tick 的定义与范围
   - 2.2 Tick ↔ 价格转换
   - 2.3 Tick 数据结构
   - 2.4 TickBitmap 快速查找
3. [代码实现](#三代码实现)
   - 3.1 核心状态结构
   - 3.2 添加流动性（mint）
   - 3.3 移除流动性（burn）与领取费用（collect）
   - 3.4 交易执行（swap）
   - 3.5 费用分配机制
4. [完整示例](#四完整示例)
   - 4.1 场景设定
   - 4.2 存入流动性
   - 4.3 区间内小额交易
   - 4.4 跨越 Tick 的大额交易
   - 4.5 资本效率对比
5. [设计亮点总结](#五设计亮点总结)

---

## 一、核心原理

### 1.1 从 V2 到 V3 的演进

**Uniswap V2** 使用经典的恒积公式：

$$x \cdot y = k$$

流动性**均匀**分布在 $(0, +\infty)$ 整个价格空间。对于一个 ETH/USDC 池，即使 ETH 价格长期在 1800~2200 之间波动，大量资本被"闲置"在 0~1800 和 2200~∞ 这些几乎不会触达的区间，**资本利用率极低**。

**Uniswap V3** 引入**集中流动性（Concentrated Liquidity）**：LP 可以将流动性集中在自定义的价格区间 $[P_a, P_b]$ 内。同等资本在该区间内可以模拟更深的做市深度，大幅提升资本效率（最高可达 V2 的数千倍）。

```
V2 流动性分布（均匀）：
  深度
  │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
  └──────────────────────────────────────→ 价格
        0        1800  2000  2200       ∞

V3 流动性分布（集中）：
  深度
  │               ████████████
  │               ████████████
  │▓▓▓▓▓▓▓▓▓▓▓▓▓▓████████████▓▓▓▓▓▓▓▓▓▓▓▓▓
  └──────────────────────────────────────→ 价格
        0        1800  2000  2200       ∞
```

### 1.2 集中流动性的数学模型

V3 以**平方根价格** $\sqrt{P}$ 作为核心状态量，对恒积公式进行变形推导。

设在区间 $[\sqrt{P_a}, \sqrt{P_b}]$ 内的流动性参数为 $L$，当前价格为 $P \in [P_a, P_b]$：

**token0（如 ETH）的数量：**

$$\Delta x = L \cdot \left(\frac{1}{\sqrt{P}} - \frac{1}{\sqrt{P_b}}\right)$$

**token1（如 USDC）的数量：**

$$\Delta y = L \cdot (\sqrt{P} - \sqrt{P_a})$$

这两个公式是整个 V3 系统的数学基础，直接对应 `SqrtPriceMath.sol` 中的核心函数。

### 1.3 虚拟储备与真实储备

V3 使用"**虚拟储备**"概念——将集中流动性等效为一个覆盖全价格范围的 V2 池，但只在 $[P_a, P_b]$ 区间内"激活"。

真实储备（LP 实际存入的代币）= 虚拟储备在区间内的"切片"：

| 当前价格位置 | token0 状态 | token1 状态 |
|---|---|---|
| $P < P_a$（区间左侧） | 全部为 token0，等待价格上涨 | 无 |
| $P_a \le P \le P_b$（区间内） | 部分 token0（$P$ → $P_b$ 段） | 部分 token1（$P_a$ → $P$ 段） |
| $P > P_b$（区间右侧） | 无 | 全部为 token1，等待价格下跌 |

### 1.4 价格表示：sqrtPriceX96

为避免浮点运算，V3 使用定点数格式 **Q64.96** 存储平方根价格：

$$\text{sqrtPriceX96} = \sqrt{P} \times 2^{96}$$

用 `uint160` 类型存储（160 位足够覆盖所有合法价格范围），精度为 $2^{-96}$，足以满足 DeFi 精度需求。

---

## 二、Tick 系统

### 2.1 Tick 的定义与范围

V3 将连续价格空间**离散化**为整数 tick，每个 tick 对应一个价格：

$$P(i) = 1.0001^i$$

每相邻两个 tick 之间的价格差约为 **0.01%（1 个基点）**，这是 DeFi 中足够精细的粒度。

- 取值范围：`MIN_TICK = -887272` 到 `MAX_TICK = 887272`
- 覆盖价格范围：$[2^{-128}, 2^{128}]$，涵盖任何实际资产价格

不同费率档位对应不同的 `tickSpacing`（仅 tickSpacing 整数倍的 tick 可被初始化）：

| 费率 | tickSpacing | 每步价格变化 |
|------|-------------|-------------|
| 0.05% | 10 | ~0.10% |
| 0.30% | 60 | ~0.60% |
| 1.00% | 200 | ~2.00% |

### 2.2 Tick ↔ 价格转换

`TickMath.sol` 实现了 tick 与 `sqrtPriceX96` 之间的双向转换：

**`getSqrtRatioAtTick(tick)`**：利用二进制分解和预计算魔法数，通过位运算实现 O(1) 精确转换，避免昂贵的幂运算。

```solidity
// 以 tick 的二进制位为索引，逐位累乘预计算好的 1.0001^(2^k) 值
uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
// ... 以此类推，共 20 位
```

**`getTickAtSqrtRatio(sqrtPriceX96)`**：通过内联汇编计算 $\log_2$，再转换为以 1.0001 为底的对数，得到 tick 值。

### 2.3 Tick 数据结构

每个已初始化的 tick 存储以下信息：

```solidity
// contracts/libraries/Tick.sol
struct Info {
    uint128 liquidityGross;                    // 引用此 tick 的总流动性（用于判断是否可清除）
    int128  liquidityNet;                      // 跨越时的流动性净变化（左→右时加，右→左时减）
    uint256 feeGrowthOutside0X128;             // tick "另一侧" 的 token0 累计费用
    uint256 feeGrowthOutside1X128;             // tick "另一侧" 的 token1 累计费用
    int56   tickCumulativeOutside;             // 预言机：tick "另一侧" 的累计 tick 值
    uint160 secondsPerLiquidityOutsideX128;    // 预言机：tick "另一侧" 的流动性时间
    uint32  secondsOutside;                    // 预言机：tick "另一侧" 的经过秒数
    bool    initialized;                       // 是否已初始化
}
```

**`liquidityNet` 的设计是集中流动性的核心机制之一**：
- 区间下界 tick 的 `liquidityNet = +L`（价格从左进入区间时增加流动性）
- 区间上界 tick 的 `liquidityNet = -L`（价格从左离开区间时减少流动性）
- 交易时，每次跨越 tick 只需读取并叠加这一个值，O(1) 完成流动性更新

### 2.4 TickBitmap 快速查找

`TickBitmap` 用 `uint256` 位图记录哪些 tick 已被初始化，`nextInitializedTickWithinOneWord()` 利用位运算在一个 256-tick 范围内 O(1) 找到下一个目标 tick，避免逐 tick 遍历，大幅降低 swap 的 gas 消耗。

---

## 三、代码实现

### 3.1 核心状态结构

`UniswapV3Pool.sol` 的主要状态变量：

```solidity
// 打包在单个存储槽（节省 gas）
Slot0 public override slot0;

struct Slot0 {
    uint160 sqrtPriceX96;              // 当前平方根价格（Q64.96）
    int24   tick;                      // 当前 tick
    uint16  observationIndex;          // TWAP 预言机：最新观察索引
    uint16  observationCardinality;    // TWAP 预言机：当前容量
    uint16  observationCardinalityNext;// TWAP 预言机：扩展目标容量
    uint8   feeProtocol;               // 协议费率（低4位=token0，高4位=token1）
    bool    unlocked;                  // 重入保护锁
}

uint128 public override liquidity;                 // 当前价格处的活跃流动性总量
uint256 public override feeGrowthGlobal0X128;      // token0 全局费用增长累计器
uint256 public override feeGrowthGlobal1X128;      // token1 全局费用增长累计器

mapping(int24 => Tick.Info)          public override ticks;       // tick 信息
mapping(int16 => uint256)            public override tickBitmap;  // tick 位图
mapping(bytes32 => Position.Info)    public override positions;   // 头寸信息
Oracle.Observation[65535]            public override observations; // TWAP 观察记录
```

头寸（Position）的数据结构：

```solidity
// contracts/libraries/Position.sol
struct Info {
    uint128 liquidity;                    // 该头寸的流动性数量
    uint256 feeGrowthInside0LastX128;     // 上次更新时区间内 token0 的累计费用
    uint256 feeGrowthInside1LastX128;     // 上次更新时区间内 token1 的累计费用
    uint128 tokensOwed0;                  // 待领取的 token0 费用
    uint128 tokensOwed1;                  // 待领取的 token1 费用
}
```

头寸的唯一标识（key）= `keccak256(owner, tickLower, tickUpper)`，无需 NFT 即可精确定位任意头寸。

---

### 3.2 添加流动性（mint）

**调用链：** `mint()` → `_modifyPosition()` → `_updatePosition()`

**`mint()` 函数**（公开入口）：

```solidity
// contracts/UniswapV3Pool.sol: 712-753
function mint(
    address recipient,
    int24   tickLower,
    int24   tickUpper,
    uint128 amount,       // 要添加的流动性 L 值
    bytes calldata data
) external override lock returns (uint256 amount0, uint256 amount1) {
    require(amount > 0);

    // 1. 计算需要存入的代币数量
    (, int256 amount0Int, int256 amount1Int) = _modifyPosition(ModifyPositionParams({
        owner: recipient,
        tickLower: tickLower,
        tickUpper: tickUpper,
        liquidityDelta: int256(amount).toInt128()  // 正数 = 添加
    }));

    amount0 = uint256(amount0Int);
    amount1 = uint256(amount1Int);

    // 2. 记录转账前余额，通过回调要求调用者转入代币
    uint256 balance0Before; uint256 balance1Before;
    if (amount0 > 0) balance0Before = balance0();
    if (amount1 > 0) balance1Before = balance1();
    IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

    // 3. 验证代币已实际转入（余额校验，防止虚假回调）
    if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
    if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

    emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
}
```

**`_modifyPosition()` 函数**（根据价格位置计算代币数量）：

```solidity
// contracts/UniswapV3Pool.sol: 501-582
function _modifyPosition(ModifyPositionParams memory params)
    private
    returns (Position.Info storage position, int256 amount0, int256 amount1)
{
    checkTicks(params.tickLower, params.tickUpper);
    Slot0 memory _slot0 = slot0; // 缓存到内存，避免多次 SLOAD

    // 更新头寸和 tick 数据
    position = _updatePosition(params.owner, params.tickLower, params.tickUpper,
                               params.liquidityDelta, _slot0.tick);

    if (params.liquidityDelta != 0) {
        if (_slot0.tick < params.tickLower) {
            // ── 情况 1：当前价格在区间左侧 ──
            // 流动性尚未激活，全部存为 token0（等待价格上涨进入区间）
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.tickLower),
                TickMath.getSqrtRatioAtTick(params.tickUpper),
                params.liquidityDelta
            );
        } else if (_slot0.tick < params.tickUpper) {
            // ── 情况 2：当前价格在区间内 ──
            // 双边存入，流动性立即生效
            amount0 = SqrtPriceMath.getAmount0Delta(
                _slot0.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.tickUpper),
                params.liquidityDelta
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.tickLower),
                _slot0.sqrtPriceX96,
                params.liquidityDelta
            );
            // 更新全局活跃流动性
            liquidity = LiquidityMath.addDelta(liquidity, params.liquidityDelta);
        } else {
            // ── 情况 3：当前价格在区间右侧 ──
            // 区间已耗尽 token0，全部存为 token1（等待价格下跌进入区间）
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.tickLower),
                TickMath.getSqrtRatioAtTick(params.tickUpper),
                params.liquidityDelta
            );
        }
    }
}
```

**`_updatePosition()` 函数**（更新 tick 和头寸状态）：

```solidity
// contracts/UniswapV3Pool.sol: 599-687
function _updatePosition(
    address owner, int24 tickLower, int24 tickUpper,
    int128 liquidityDelta, int24 tick
) private returns (Position.Info storage position) {
    position = positions.get(owner, tickLower, tickUpper);

    if (liquidityDelta != 0) {
        // 更新上下界 tick（返回是否发生"翻转"——从无到有或从有到无）
        bool flippedLower = ticks.update(tickLower, tick, liquidityDelta, ...);
        bool flippedUpper = ticks.update(tickUpper, tick, liquidityDelta, ...);

        // 若 tick 翻转，在位图中标记（flipped = 初始化/取消初始化）
        if (flippedLower) tickBitmap.flipTick(tickLower, tickSpacing);
        if (flippedUpper) tickBitmap.flipTick(tickUpper, tickSpacing);
    }

    // 计算区间内累计费用，更新头寸（顺带结算未领取的费用）
    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        ticks.getFeeGrowthInside(tickLower, tickUpper, tick, ...);
    position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

    // 移除流动性时，清理不再需要的 tick 数据
    if (liquidityDelta < 0) {
        if (flippedLower) ticks.clear(tickLower);
        if (flippedUpper) ticks.clear(tickUpper);
    }
}
```

---

### 3.3 移除流动性（burn）与领取费用（collect）

V3 将"退出流动性"与"提取代币"**解耦**为两步操作：

**`burn()`**：减少头寸流动性，将应返还的代币数量记录到 `tokensOwed`，**不实际转账**。

```solidity
// contracts/UniswapV3Pool.sol: 821-851
function burn(int24 tickLower, int24 tickUpper, uint128 amount)
    external override lock returns (uint256 amount0, uint256 amount1)
{
    (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
        _modifyPosition(ModifyPositionParams({
            owner: msg.sender,
            tickLower: tickLower, tickUpper: tickUpper,
            liquidityDelta: -int256(amount).toInt128()  // 负数 = 移除
        }));

    amount0 = uint256(-amount0Int);
    amount1 = uint256(-amount1Int);

    // 记入待领取余额（不立即转账）
    if (amount0 > 0 || amount1 > 0) {
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
    }
    emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
}
```

**`collect()`**：提取 `tokensOwed` 中的代币（包含本金和手续费），执行实际转账。

```solidity
// contracts/UniswapV3Pool.sol: 771-800
function collect(
    address recipient, int24 tickLower, int24 tickUpper,
    uint128 amount0Requested, uint128 amount1Requested
) external override lock returns (uint128 amount0, uint128 amount1) {
    Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

    // 实际可取数量 = min(请求数量, 待领取余额)
    amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
    amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

    if (amount0 > 0) { position.tokensOwed0 -= amount0; TransferHelper.safeTransfer(token0, recipient, amount0); }
    if (amount1 > 0) { position.tokensOwed1 -= amount1; TransferHelper.safeTransfer(token1, recipient, amount1); }

    emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
}
```

> **设计意图**：分离 burn 和 collect 使 LP 可以**只收取手续费**（burn(0) + collect），而不必退出头寸；也允许合约对 burn 的结果做进一步处理后再提取。

---

### 3.4 交易执行（swap）

`swap()` 是 V3 最复杂的函数，通过**分步遍历 tick** 处理跨多个流动性区间的大额交易：

```solidity
// contracts/UniswapV3Pool.sol: 917-1165
function swap(
    address recipient,
    bool    zeroForOne,         // true = token0 换 token1（价格下降）
    int256  amountSpecified,    // 正数 = 精确输入，负数 = 精确输出
    uint160 sqrtPriceLimitX96,  // 价格上/下限（滑点保护）
    bytes calldata data
) external override noDelegateCall returns (int256 amount0, int256 amount1) {

    // 初始化交易状态
    SwapState memory state = SwapState({
        amountSpecifiedRemaining: amountSpecified,
        amountCalculated: 0,
        sqrtPriceX96: slot0Start.sqrtPriceX96,
        tick: slot0Start.tick,
        feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
        protocolFee: 0,
        liquidity: cache.liquidityStart
    });

    // ══ 核心循环：逐步消耗输入/输出，直到用尽或触达价格上限 ══
    while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
        StepComputations memory step;
        step.sqrtPriceStartX96 = state.sqrtPriceX96;

        // 步骤 1：用 TickBitmap 找到下一个已初始化的 tick
        (step.tickNext, step.initialized) =
            tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);
        step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

        // 步骤 2：计算在当前流动性下，到目标价格的交易量（单步）
        (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) =
            SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                // 目标价格 = min(下一个tick价格, 用户设置的价格限制)
                (zeroForOne
                    ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                    : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96 : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

        // 步骤 3：更新剩余数量和累计输出
        if (exactInput) {
            state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
            state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
        } else {
            state.amountSpecifiedRemaining += step.amountOut.toInt256();
            state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
        }

        // 步骤 4：累计手续费（费用 / 当前流动性 → 每单位流动性的费用增量）
        if (state.liquidity > 0)
            state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

        // 步骤 5：若到达了 tick 边界，执行跨越（更新流动性）
        if (state.sqrtPriceX96 == step.sqrtPriceNextX96 && step.initialized) {
            int128 liquidityNet = ticks.cross(step.tickNext, ...);
            // liquidityNet 对于向右移动是正的（进入区间），向左移动时取反
            if (zeroForOne) liquidityNet = -liquidityNet;
            state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
        }
        // 更新当前 tick
        state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
    }

    // 循环结束：将最终状态写回存储，执行代币转账
    slot0.sqrtPriceX96 = state.sqrtPriceX96;
    slot0.tick = state.tick;
    if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;
    feeGrowthGlobal0X128 (or 1) = state.feeGrowthGlobalX128;

    // 先转出，再通过回调收取输入代币（类似 Flash Loan 的先给后收模式）
    if (zeroForOne) {
        if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
    }
    // ...
}
```

**`SwapMath.computeSwapStep()` 的单步计算**：

```solidity
// contracts/libraries/SwapMath.sol: 21-97
function computeSwapStep(
    uint160 sqrtRatioCurrentX96,   // 当前价格
    uint160 sqrtRatioTargetX96,    // 目标价格（下一个tick或用户价格限制）
    uint128 liquidity,              // 当前活跃流动性
    int256  amountRemaining,        // 剩余交易量（正=精确输入，负=精确输出）
    uint24  feePips                 // 费率（百万分之一）
) returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
    bool exactIn = amountRemaining >= 0;

    if (exactIn) {
        // 扣除手续费后的实际可用输入量
        uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
        // 计算到达目标价格需要的输入量
        amountIn = zeroForOne
            ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);

        if (amountRemainingLessFee >= amountIn)
            sqrtRatioNextX96 = sqrtRatioTargetX96;  // 能到达目标
        else
            sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(...);  // 不能到达，计算实际停止价格
    }
    // 精确输出类似，不再赘述...

    // 手续费 = 实际输入量 * feePips / (1e6 - feePips)
    feeAmount = exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96
        ? uint256(amountRemaining) - amountIn  // 用尽剩余输入时，余量全算手续费
        : FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
}
```

---

### 3.5 费用分配机制

V3 的费用分配设计精妙，无需遍历即可为任意区间的 LP 精确计算应得费用。

**全局累计器**：每次 swap 向全局费用增长累计器添加增量：

$$\text{feeGrowthGlobal} \mathrel{+}= \frac{\text{feeAmount} \times 2^{128}}{\text{liquidity}}$$

**Tick 的"另一侧"技巧**：每个 tick 记录该 tick "另一侧"（相对当前价格）的累计费用 `feeGrowthOutside`。当价格跨越 tick 时，`outside` 取反（相当于参考系切换）：

```solidity
// contracts/libraries/Tick.sol: 178-179
info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
```

**区间内费用计算**（O(1) 复杂度）：

```solidity
// contracts/libraries/Tick.sol: 60-95
function getFeeGrowthInside(...) {
    // 区间下方的累计费用
    uint256 feeGrowthBelow0X128 = (tickCurrent >= tickLower)
        ? lower.feeGrowthOutside0X128
        : feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;

    // 区间上方的累计费用（同理）
    uint256 feeGrowthAbove0X128 = (tickCurrent < tickUpper)
        ? upper.feeGrowthOutside0X128
        : feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;

    // 区间内费用 = 全局总量 - 区间外总量
    feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
}
```

**LP 头寸领取费用**：

```solidity
// contracts/libraries/Position.sol: 44-87
function update(Info storage self, int128 liquidityDelta, uint256 feeGrowthInside0X128, ...) {
    // 应得费用 = 流动性 × (当前区间内累计费用 - 上次结算时的累计费用)
    uint128 tokensOwed0 = uint128(
        FullMath.mulDiv(
            feeGrowthInside0X128 - self.feeGrowthInside0LastX128,
            self.liquidity,
            FixedPoint128.Q128
        )
    );
    self.tokensOwed0 += tokensOwed0;
    self.feeGrowthInside0LastX128 = feeGrowthInside0X128; // 更新快照
}
```

---

## 四、完整示例

### 4.1 场景设定

**池**：ETH/USDC，费率 0.3%（`tickSpacing = 60`）

**初始状态**：
- 当前价格：2000 USDC/ETH
- 当前 tick：76,012（= floor(log(2000) / log(1.0001))）
- 当前活跃流动性：0（新池）

**Alice** 将在区间 **[1800, 2200]** 提供 **L = 1,000,000** 的流动性。

**Bob** 将用 **40,200 USDC** 购买 ETH（精确输入）。

### 4.2 存入流动性（Alice Mint）

**Step 1：计算 tick**

| 价格 | tick | 计算 |
|------|------|------|
| 1800 | 74,040 | `floor(log(1800)/log(1.0001))`，对齐到 tickSpacing=60 |
| 2000 | 76,012 | 当前 tick |
| 2200 | 77,920 | `floor(log(2200)/log(1.0001))`，对齐到 tickSpacing=60 |

**Step 2：计算需要存入的代币数量**

当前价格 $\sqrt{P} = \sqrt{2000} \approx 44.72$，在区间 $[\sqrt{1800}, \sqrt{2200}] = [42.43, 46.90]$ 内，触发情况 2。

$$\Delta x_{ETH} = L \cdot \left(\frac{1}{\sqrt{P}} - \frac{1}{\sqrt{P_b}}\right) = 1{,}000{,}000 \times \left(\frac{1}{44.72} - \frac{1}{46.90}\right) \approx \mathbf{104 \text{ ETH}}$$

$$\Delta y_{USDC} = L \cdot (\sqrt{P} - \sqrt{P_a}) = 1{,}000{,}000 \times (44.72 - 42.43) \approx \mathbf{229{,}000 \text{ USDC}}$$

Alice 存入 **104 ETH + 229,000 USDC**，总价值约 **$437,000**。

**Step 3：池状态更新**

```
ticks[74,040] = { liquidityGross: 1,000,000, liquidityNet: +1,000,000, initialized: true }
ticks[77,920] = { liquidityGross: 1,000,000, liquidityNet: -1,000,000, initialized: true }
tickBitmap:    bit[74,040] = 1, bit[77,920] = 1
positions[Alice, 74040, 77920] = { liquidity: 1,000,000, ... }
liquidity (global) = 1,000,000  ← 当前价格在区间内，立即生效
```

### 4.3 区间内小额交易（Bob 买 ETH，价格不跨 tick）

Bob 用 **40,200 USDC** 买 ETH（token1 换 token0，zeroForOne = false，价格上涨）。

**swap 循环第一（也是唯一）步：**

- 下一个 tick：77,920（tickUpper），对应价格 $\sqrt{2200}$
- `computeSwapStep(sqrt(2000), sqrt(2200), L=1,000,000, amountRemaining=40,200 USDC, fee=3000)`

**计算到达 sqrt(2200) 需要的 USDC：**

$$\Delta y_{to\_2200} = L \cdot (\sqrt{2200} - \sqrt{2000}) = 1{,}000{,}000 \times (46.90 - 44.72) = 218{,}000 \text{ USDC}$$

40,200 USDC（扣除 0.3% 手续费后约 40,079 USDC）< 218,000 USDC，**不能到达 tick 边界**，在当前 tick 范围内结算：

$$\sqrt{P'} = \sqrt{P} + \frac{\Delta y}{L} = 44.72 + \frac{40{,}079}{1{,}000{,}000} = 44.76$$

$$P' = 44.76^2 \approx 2003.6 \text{ USDC/ETH}$$

$$\Delta x_{ETH} = L \cdot \left(\frac{1}{\sqrt{P'}} - \frac{1}{\sqrt{P}}\right) = 1{,}000{,}000 \times \left(\frac{1}{44.76} - \frac{1}{44.72}\right) \approx 19.96 \text{ ETH}$$

**手续费**：40,200 × 0.3% ≈ 120.6 USDC

$$\text{feeGrowthGlobal1X128} \mathrel{+}= \frac{120.6 \times 2^{128}}{1{,}000{,}000}$$

**交易后状态：**

```
slot0.sqrtPriceX96 = sqrt(2003.6) * 2^96
slot0.tick         = 76,040（重新计算）
liquidity          = 1,000,000（未跨越 tick，不变）
feeGrowthGlobal1X128 += 120.6 / 1,000,000 × 2^128  ← Alice 的手续费累积
```

### 4.4 跨越 Tick 的大额交易（价格冲破 2200）

假设有更大的买单，将价格推过 2200（tickUpper = 77,920）。

**swap 循环（跨越 tick 的步骤）：**

**第一步**：计算从当前价格到 sqrt(2200) 的交易量。
- 消耗约 218,000 USDC，换出约 104 ETH（Alice 的全部 ETH 被买走）
- 价格到达 sqrt(2200)，触达 tick 边界

**跨越 tick（Tick.cross）：**

```solidity
// 翻转 feeGrowthOutside（参考系切换）
info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
return info.liquidityNet;  // 返回 -1,000,000
```

**更新活跃流动性：**

```
liquidityNet = -1,000,000（tickUpper 的值）
zeroForOne = false（向右移动），不取反
state.liquidity = 1,000,000 + (-1,000,000) = 0
```

**第二步**：若还有剩余买单，继续循环。活跃流动性为 0，`computeSwapStep` 不会再计算出有效输出（流动性为 0 时价格可以跳变），直到遇到下一个已初始化的 tick。

**最终状态：**

```
slot0.tick  = 77,920（或更高，取决于剩余交易量）
liquidity   = 0（Alice 的流动性已退出活跃状态）
Alice 头寸  = { liquidity: 1,000,000 }（数量不变，但已不活跃）
Alice 资产  ≈ 0 ETH + 229,000 USDC（初始）+ 218,000 USDC（ETH 卖出所得）+ 手续费
           ≈ 447,000+ USDC（全部变为 USDC）
```

**价格变动轨迹：**

```
价格轴（USDC/ETH）：
  1800        2000  2003.6      2200
    |           |      |          |
    |←──────────|→→→→→→|          |   Bob 的小额交易（不跨 tick）
    |           |                 |
    |←──────────|→→→→→→→→→→→→→→→→|→  大额交易（跨越 tickUpper，流动性退出）
    ↑           ↑                 ↑
  tickLower  tickCurrent      tickUpper
  （进入时                    （退出时
   +1M流动性）                 -1M流动性）
```

### 4.5 资本效率对比

| 指标 | Uniswap V2 | Uniswap V3（Alice，区间 1800-2200） |
|------|-----------|--------------------------------------|
| 总存入资本 | ~$10,000,000 | ~$437,000 |
| 做市深度（2000±10%） | 相同 | **相同** |
| 资本利用率 | ~4.4% | ~100%（区间内价格时） |
| **资本效率提升** | 基准 | **约 23x** |
| 价格区间越窄 | 不支持 | 效率倍数越高（最高数千倍） |

---

## 五、设计亮点总结

### 整体架构

```
UniswapV3Pool
├── Slot0（单存储槽，节省 gas）
│   └── sqrtPriceX96, tick, 预言机索引, 费率, 锁
├── liquidity（当前价格处的活跃流动性）
├── feeGrowthGlobal（全局费用累计器）
├── ticks mapping（tick 点数据）
│   ├── liquidityGross（引用计数，判断是否可清除）
│   ├── liquidityNet（跨越时的流动性变化，O(1)更新）
│   └── feeGrowthOutside（费用归属计算的关键）
├── tickBitmap（位图，O(1)查找下一个tick）
└── positions mapping（LP头寸）
    ├── liquidity
    ├── feeGrowthInsideLast（上次结算快照）
    └── tokensOwed（待领取余额）
```

### 五大核心设计

| 设计 | 方案 | 优点 |
|------|------|------|
| **价格表示** | `sqrtPriceX96`（Q64.96 定点数） | 避免浮点，精度高，128 位乘法不溢出 |
| **价格空间离散化** | Tick（步长 0.01%） | 平衡精度与 gas，支持任意区间 |
| **流动性切换** | `liquidityNet` + `cross()` | O(1) 完成区间激活/退出，无需遍历 |
| **Tick 查找** | `TickBitmap` 位图 | O(1) 查找下一个 tick，swap 高效 |
| **费用分配** | `feeGrowthOutside` 相对记账 | O(1) 计算任意区间应得费用 |

### 与 V2 的本质区别

> Uniswap V3 的集中流动性，本质是将整个价格空间切分为 **无数个微小的 V2 子池**，每个 LP 头寸激活其中若干段，多个 LP 的区间叠加形成有深度差异的流动性分布。交易时，价格在这些子池中依次穿越，每穿越一个 tick 边界，活跃流动性实时增减。这一设计在 O(1) 的时间复杂度下实现了无限精细的做市策略空间。
