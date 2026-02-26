# 里程碑 3：跨 Tick Swap

> 来源：[uniswapv3book.com/milestone_3](https://uniswapv3book.com/milestone_3/introduction.html)  
> 完整源码：[milestone_3 分支](https://github.com/Jeiwan/uniswapv3-code/tree/milestone_3)  
> 与上一里程碑的变更：[查看 diff](https://github.com/Jeiwan/uniswapv3-code/compare/milestone_2...milestone_3)

---

## 介绍

在这个里程碑中，我们将完成 Uniswap V3 的核心功能——**跨价格范围的交换**。

主要改进：

1. **更新 `swap` 函数**：当当前价格范围流动性不足时，跨越到下一个价格范围
2. **更新 `mint` 函数**：支持在不同价格范围提供流动性
3. **滑点保护**：在 `mint` 和 `swap` 函数中实现
4. **流动性计算**：在智能合约中计算 $L$
5. **定点数**：深入了解定点数
6. **闪电贷**：实现闪电贷功能

---

## 跨 Tick 交易

### 跨 Tick 交换如何工作

Uniswap V3 池包含许多重叠的价格范围。每个池跟踪**当前价格**（`sqrtPriceX96`）和**当前 tick**，以及**当前流动性**（`liquidity`）。

当用户交换代币时，价格沿曲线移动。如果移动范围超出当前价格范围：
- 当前价格范围变为**不活跃**，其流动性从 `liquidity` 中减去
- 价格移入下一个价格范围，该范围被**激活**，其流动性加入 `liquidity`

**三种价格范围示意：**
```
[Lower Range: 只含 USDC] [Current Range: 两种代币] [Upper Range: 只含 ETH]
         |______________|_______________|___________|
         4000          4545           5500         6250
                              ↑ 当前价格
```

### 更新 computeSwapStep

需要处理两种情况：
1. 当前价格范围**足够**满足整个交换
2. 当前价格范围**不够**，需要跨越到下一个范围

```solidity
function computeSwapStep(
    uint160 sqrtPriceCurrentX96,
    uint160 sqrtPriceTargetX96,
    uint128 liquidity,
    uint256 amountRemaining
) internal pure returns (
    uint160 sqrtPriceNextX96,
    uint256 amountIn,
    uint256 amountOut
) {
    bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;

    // 计算当前范围能处理的最大输入量
    amountIn = zeroForOne
        ? Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity)
        : Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity);

    if (amountRemaining >= amountIn) {
        // 当前范围不够：使用整个范围（到达边界）
        sqrtPriceNextX96 = sqrtPriceTargetX96;
    } else {
        // 当前范围足够：在范围内计算精确价格
        sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
            sqrtPriceCurrentX96,
            liquidity,
            amountRemaining,
            zeroForOne
        );
    }

    amountIn = Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);
    amountOut = Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);
}
```

### 更新 swap 循环

在循环结束时处理跨 tick 的情况：

```solidity
while (
    state.amountSpecifiedRemaining > 0 &&
    state.sqrtPriceX96 != sqrtPriceLimitX96
) {
    StepState memory step;
    step.sqrtPriceStartX96 = state.sqrtPriceX96;

    // 找下一个已初始化 tick
    (step.nextTick, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
        state.tick, 1, zeroForOne
    );

    step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

    // 计算本步骤的交换量
    (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
        state.sqrtPriceX96,
        (zeroForOne
            ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
            : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
            ? sqrtPriceLimitX96
            : step.sqrtPriceNextX96,
        state.liquidity,
        state.amountSpecifiedRemaining
    );

    state.amountSpecifiedRemaining -= step.amountIn;
    state.amountCalculated += step.amountOut;

    // 如果到达边界，跨越到下一个价格范围
    if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        if (step.initialized) {
            // 穿越 tick：更新流动性
            int128 liquidityDelta = ticks.cross(step.nextTick);
            if (zeroForOne) liquidityDelta = -liquidityDelta;

            state.liquidity = LiquidityMath.addLiquidity(
                state.liquidity,
                liquidityDelta
            );

            if (state.liquidity == 0) revert NotEnoughLiquidity();
        }

        // 更新 tick（向下时减 1）
        state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
    } else {
        state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
    }
}

// 交换结束后更新全局流动性
if (liquidity_ != state.liquidity) liquidity = state.liquidity;
```

### 流动性跟踪和 Tick 穿越

**Tick.Info 结构更新**：

```solidity
struct Info {
    bool initialized;
    uint128 liquidityGross;   // tick 的总流动性（用于判断是否翻转）
    int128 liquidityNet;      // 穿越时加减的流动性（正负值）
}
```

**约定：**
- 穿越**下界 tick**（lower tick）：**增加**流动性
- 穿越**上界 tick**（upper tick）：**减少**流动性
- 但当 `zeroForOne = true`（价格下降）时符号取反

```solidity
function cross(
    mapping(int24 => Tick.Info) storage self,
    int24 tick
) internal view returns (int128 liquidityDelta) {
    Tick.Info storage info = self[tick];
    liquidityDelta = info.liquidityNet;
}
```

### 测试场景

#### 场景 1：单价格范围

```solidity
function testBuyETHOnePriceRange() public {
    LiquidityRange[] memory liquidity = new LiquidityRange[](1);
    liquidity[0] = liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000);
    
    // 交换小额，价格保持在范围内
    assertSwapState(ExpectedStateAfterSwap({
        sqrtPriceX96: 5604415652688968742392013927525,  // ~5003.82
        tick: 85183,
        currentLiquidity: liquidity[0].amount
    }));
}
```

#### 场景 2：连续价格范围（大额交换）

```solidity
function testBuyETHConsecutivePriceRanges() public {
    LiquidityRange[] memory liquidity = new LiquidityRange[](2);
    liquidity[0] = liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000);
    liquidity[1] = liquidityRange(5500, 6250, 1 ether, 5000 ether, 5000);
    
    // 大额交换，价格穿越到第二个范围
    assertSwapState(ExpectedStateAfterSwap({
        sqrtPriceX96: 6190476002219365604851182401841,  // ~6105.05
        tick: 87173,
        currentLiquidity: liquidity[1].amount  // 只有第二个范围的流动性
    }));
}
```

#### 场景 3：重叠价格范围（更深流动性）

```solidity
function testBuyETHPartiallyOverlappingPriceRanges() public {
    LiquidityRange[] memory liquidity = new LiquidityRange[](2);
    liquidity[0] = liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000);
    liquidity[1] = liquidityRange(5001, 6250, 1 ether, 5000 ether, 5000);
    
    // 重叠区域流动性更深，价格移动更慢
    // 获得更多代币（相比连续范围场景）
}
```

---

## 滑点保护

### 什么是滑点？

**滑点**是你发送交易时看到的价格与实际执行价格之间的差异。产生原因：
1. 区块之间的延迟
2. **三明治攻击**：攻击者在你的交易前后插入交易，操纵价格

### Swap 中的滑点保护

在 `swap` 函数中添加 `sqrtPriceLimitX96` 参数：

```solidity
function swap(
    address recipient,
    bool zeroForOne,
    uint256 amountSpecified,
    uint160 sqrtPriceLimitX96,  // 新参数：价格不能超过这个限制
    bytes calldata data
) public returns (int256 amount0, int256 amount1) {
    // 验证限制价格合法性
    if (
        zeroForOne
            ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 ||
                sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
            : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 &&
                sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
    ) revert InvalidPriceLimit();

    // 循环条件：还有剩余数量 AND 价格未到达限制
    while (
        state.amountSpecifiedRemaining > 0 &&
        state.sqrtPriceX96 != sqrtPriceLimitX96
    ) {
        ...
    }
}
```

注意：当触发滑点保护时，交换**不会失败**，而是部分执行。

### Mint 中的滑点保护

添加流动性也需要滑点保护，在 **Manager 合约**（而非 Pool 合约）中实现：

```solidity
struct MintParams {
    address poolAddress;
    int24 lowerTick;
    int24 upperTick;
    uint256 amount0Desired;   // 希望提供的 token0 数量
    uint256 amount1Desired;   // 希望提供的 token1 数量
    uint256 amount0Min;       // 最少接受的 token0 数量
    uint256 amount1Min;       // 最少接受的 token1 数量
}

function mint(MintParams calldata params)
    public
    returns (uint256 amount0, uint256 amount1)
{
    IUniswapV3Pool pool = IUniswapV3Pool(params.poolAddress);

    (uint160 sqrtPriceX96, ) = pool.slot0();
    uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(params.lowerTick);
    uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(params.upperTick);

    // 计算流动性
    uint128 liquidity = LiquidityMath.getLiquidityForAmounts(
        sqrtPriceX96,
        sqrtPriceLowerX96,
        sqrtPriceUpperX96,
        params.amount0Desired,
        params.amount1Desired
    );

    (amount0, amount1) = pool.mint(...);

    // 检查实际数量不低于最小值
    if (amount0 < params.amount0Min || amount1 < params.amount1Min)
        revert SlippageCheckFailed(amount0, amount1);
}
```

---

## 实现流动性计算

在 Manager 合约中，我们使用 `LiquidityMath.getLiquidityForAmounts` 来计算流动性。

**三种情况：**

1. **当前价格 < 下界**：只需要 token0

$$L = \Delta x \cdot \frac{\sqrt{P_a} \cdot \sqrt{P_b}}{\sqrt{P_b} - \sqrt{P_a}}$$

2. **当前价格 > 上界**：只需要 token1

$$L = \frac{\Delta y}{\sqrt{P_b} - \sqrt{P_a}}$$

3. **当前价格在范围内**：需要两种代币，取两者计算结果的较小值

```solidity
function getLiquidityForAmounts(
    uint160 sqrtPriceX96,
    uint160 sqrtPriceLowerX96,
    uint160 sqrtPriceUpperX96,
    uint256 amount0,
    uint256 amount1
) internal pure returns (uint128 liquidity) {
    if (sqrtPriceX96 <= sqrtPriceLowerX96) {
        liquidity = getLiquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, amount0);
    } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
        uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceUpperX96, amount0);
        uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceX96, amount1);
        liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    } else {
        liquidity = getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, amount1);
    }
}
```

---

## 定点数的更多内容

### Q64.96 格式

Uniswap V3 使用 **Q64.96** 定点数格式存储 $\sqrt{P}$：
- 64 位整数部分
- 96 位小数部分
- 总共 160 位，适合存储在 `uint160` 中

换算关系：
$$\sqrt{P}_{Q64.96} = \sqrt{P} \cdot 2^{96}$$

使用 `FixedPoint96.RESOLUTION = 96`（即 $2^{96}$）进行换算。

### 精度处理

为避免累积舍入误差，计算时通常使用**向上取整**（rounding up）：

```solidity
function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator)
    internal pure returns (uint256 result)
{
    result = PRBMath.mulDiv(a, b, denominator);
    if (mulmod(a, b, denominator) > 0) {
        require(result < type(uint256).max);
        result++;
    }
}
```

---

## 实现闪电贷

### 闪电贷原理

**闪电贷**：在单个交易中借出代币，交易结束时必须还回（连同手续费）。如果不还，整个交易回滚。

这利用了区块链交易的**原子性**：要么全部成功，要么全部失败。

### 实现

```solidity
function flash(
    uint256 amount0,
    uint256 amount1,
    bytes calldata data
) public {
    uint256 balance0Before = IERC20(token0).balanceOf(address(this));
    uint256 balance1Before = IERC20(token1).balanceOf(address(this));

    if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
    if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

    // 调用回调，让借款人使用资金并还款
    IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(data);

    // 验证还款
    if (IERC20(token0).balanceOf(address(this)) < balance0Before)
        revert FlashLoanNotPaid();
    if (IERC20(token1).balanceOf(address(this)) < balance1Before)
        revert FlashLoanNotPaid();

    emit Flash(msg.sender, amount0, amount1);
}
```

---

*[← 里程碑 2：第二次 Swap](./03-里程碑2-第二次Swap.md) | [里程碑 4：多池交换 →](./05-里程碑4-多池交换.md)*
