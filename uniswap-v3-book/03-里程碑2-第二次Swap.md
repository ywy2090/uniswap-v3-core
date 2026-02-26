# 里程碑 2：第二次 Swap

> 来源：[uniswapv3book.com/milestone_2](https://uniswapv3book.com/milestone_2/introduction.html)  
> 完整源码：[milestone_2 分支](https://github.com/Jeiwan/uniswapv3-code/tree/milestone_2)  
> 与上一里程碑的变更：[查看 diff](https://github.com/Jeiwan/uniswapv3-code/compare/milestone_1...milestone_2)

---

## 介绍

在这个里程碑中，我们将实现第二次交换（反向交换）：**卖出 ETH 换取 USDC**。

主要改进：

1. **支持双向交换**：池合约需要支持两个方向的交换
2. **用 Solidity 实现数学计算**：不再硬编码数值
3. **Tick Bitmap 索引**：用于高效查找有流动性的 tick
4. **Quoter 合约**：让用户在不实际交换的情况下计算输出数量
5. **更新 UI**：支持双向交换和输出数量计算

---

## 输出数量计算

### 卖出 ETH 的公式

当卖出 token0（ETH）时，需要找到目标价格。

已知 $\Delta x$（卖出的 ETH 数量），求 $\sqrt{P_{next}}$：

$$\sqrt{P_{next}} = \frac{L \cdot \sqrt{P_{cur}}}{L + \Delta x \cdot \sqrt{P_{cur}}}$$

```python
# 卖出 ETH 换取 USDC
amount_in = 0.01337 * eth

price_next = int((liq * q96 * sqrtp_cur) // (liq * q96 + amount_in * sqrtp_cur))

print("新价格:", (price_next / q96) ** 2)   # 4993.78
print("新 sqrtP:", price_next)
print("新 tick:", price_to_tick((price_next / q96) ** 2))  # 85163

amount_in = calc_amount0(liq, price_next, sqrtp_cur)
amount_out = calc_amount1(liq, price_next, sqrtp_cur)
# ETH in: 0.01337
# USDC out: 66.80838889019013
```

---

## Solidity 中的数学

### 面临的挑战

Solidity 不支持小数部分的数，数学运算比较复杂：

1. **整数类型限制**：只有整数和无符号整数类型
2. **Gas 消耗**：算法越复杂，消耗 Gas 越多
3. **溢出风险**：乘以 `uint256` 数字时可能溢出

### 使用第三方数学库

我们使用两个第三方数学合约：

1. **[TickMath](https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol)**（来自 Uniswap V3 原始仓库）
   - `getSqrtRatioAtTick`：从 tick 计算 $\sqrt{P}$
   - `getTickAtSqrtRatio`：从 $\sqrt{P}$ 计算 tick

2. **[PRBMath](https://github.com/paulrberg/prb-math)**
   - `mulDiv`：处理乘法溢出

### TickMath 核心功能

```solidity
// 将 tick 转换为 sqrtPrice（Q64.96 格式）
function getSqrtRatioAtTick(int24 tick)
    internal pure returns (uint160 sqrtPriceX96);

// 将 sqrtPrice 转换为 tick
function getTickAtSqrtRatio(uint160 sqrtPriceX96)
    internal pure returns (int24 tick);
```

---

## Tick Bitmap 索引

### 为什么需要 Bitmap？

为了高效地找到有流动性的 tick，Uniswap V3 使用 **Bitmap（位图）** 技术。

**Bitmap 原理**：
- 用二进制数字中的每一位（0 或 1）表示一个 tick 是否已初始化
- 1 = 该 tick 有流动性；0 = 未初始化
- 每个 `uint256` 可以存储 256 个 tick 的状态

### 数据结构

```solidity
// 在 Pool 合约中
contract UniswapV3Pool {
    using TickBitmap for mapping(int16 => uint256);
    mapping(int16 => uint256) public tickBitmap;
}
```

这是一个 mapping，key 是 `int16`，value 是 `uint256`（256 位 word）。

### 位置计算

```solidity
function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
    wordPos = int16(tick >> 8);   // 整除 256（取 word 位置）
    bitPos = uint8(uint24(tick % 256));  // 取余（在 word 中的位置）
}
```

例如，tick = 85176：
```python
tick = 85176
word_pos = tick >> 8   # 332
bit_pos = tick % 256   # 184
```

### 翻转标志（flipTick）

添加流动性时，需要设置 tick 的 bitmap 标志：

```solidity
function flipTick(
    mapping(int16 => uint256) storage self,
    int24 tick,
    int24 tickSpacing
) internal {
    require(tick % tickSpacing == 0);
    (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
    uint256 mask = 1 << bitPos;
    self[wordPos] ^= mask;  // 使用 XOR 翻转位
}
```

### 查找下一个已初始化的 Tick

```solidity
function nextInitializedTickWithinOneWord(
    mapping(int16 => uint256) storage self,
    int24 tick,
    int24 tickSpacing,
    bool lte  // true: 向左搜索（卖 token0），false: 向右搜索（卖 token1）
) internal view returns (int24 next, bool initialized) {
    int24 compressed = tick / tickSpacing;
    
    if (lte) {
        // 向当前 tick 左侧搜索
        (int16 wordPos, uint8 bitPos) = position(compressed);
        uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
        uint256 masked = self[wordPos] & mask;
        
        initialized = masked != 0;
        next = initialized
            ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
            : (compressed - int24(uint24(bitPos))) * tickSpacing;
    } else {
        // 向当前 tick 右侧搜索
        (int16 wordPos, uint8 bitPos) = position(compressed + 1);
        uint256 mask = ~((1 << bitPos) - 1);
        uint256 masked = self[wordPos] & mask;
        
        initialized = masked != 0;
        next = initialized
            ? (compressed + 1 + int24(uint24((BitMath.leastSignificantBit(masked) - bitPos)))) * tickSpacing
            : (compressed + 1 + int24(uint24((type(uint8).max - bitPos)))) * tickSpacing;
    }
}
```

---

## 通用化 Minting

### 更新 Tick.update

`Tick.update` 现在返回 `flipped` 标志，表示 tick 是否从无流动性变为有流动性（或反之）：

```solidity
function update(
    mapping(int24 => Tick.Info) storage self,
    int24 tick,
    uint128 liquidityDelta
) internal returns (bool flipped) {
    ...
    flipped = (liquidityAfter == 0) != (liquidityBefore == 0);
    ...
}
```

### 在 mint 中更新 Bitmap

```solidity
function mint(...) {
    ...
    bool flippedLower = ticks.update(lowerTick, amount);
    bool flippedUpper = ticks.update(upperTick, amount);

    if (flippedLower) tickBitmap.flipTick(lowerTick, 1);
    if (flippedUpper) tickBitmap.flipTick(upperTick, 1);
    ...
}
```

### 用 Solidity 计算代币数量

不再硬编码，而是用公式计算：

$$\Delta x = L \cdot \frac{\sqrt{P_b} - \sqrt{P_a}}{\sqrt{P_a} \cdot \sqrt{P_b}}$$

$$\Delta y = L \cdot (\sqrt{P_b} - \sqrt{P_a})$$

```solidity
// src/lib/Math.sol
function calcAmount0Delta(
    uint160 sqrtPriceAX96,
    uint160 sqrtPriceBX96,
    uint128 liquidity
) internal pure returns (uint256 amount0) {
    if (sqrtPriceAX96 > sqrtPriceBX96)
        (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

    require(sqrtPriceAX96 > 0);

    amount0 = divRoundingUp(
        mulDivRoundingUp(
            (uint256(liquidity) << FixedPoint96.RESOLUTION),
            (sqrtPriceBX96 - sqrtPriceAX96),
            sqrtPriceBX96
        ),
        sqrtPriceAX96
    );
}

function calcAmount1Delta(
    uint160 sqrtPriceAX96,
    uint160 sqrtPriceBX96,
    uint128 liquidity
) internal pure returns (uint256 amount1) {
    if (sqrtPriceAX96 > sqrtPriceBX96)
        (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

    amount1 = mulDivRoundingUp(
        liquidity,
        (sqrtPriceBX96 - sqrtPriceAX96),
        FixedPoint96.Q96
    );
}
```

在 `mint` 函数中使用这些函数：

```solidity
amount0 = Math.calcAmount0Delta(
    slot0_.sqrtPriceX96,
    TickMath.getSqrtRatioAtTick(upperTick),
    amount
);
amount1 = Math.calcAmount1Delta(
    slot0_.sqrtPriceX96,
    TickMath.getSqrtRatioAtTick(lowerTick),
    amount
);
```

---

## 广义的兑换

### 更新后的 swap 函数

```solidity
function swap(
    address recipient,
    bool zeroForOne,    // true: 卖 token0 换 token1，false: 反之
    uint256 amountSpecified,  // 用户想卖的代币数量
    bytes calldata data
) public returns (int256 amount0, int256 amount1) {
    ...
}
```

### 状态结构

```solidity
struct SwapState {
    uint256 amountSpecifiedRemaining;  // 还需要买的数量
    uint256 amountCalculated;          // 已计算的输出数量
    uint160 sqrtPriceX96;             // 新的当前价格
    int24 tick;                        // 新的当前 tick
}

struct StepState {
    uint160 sqrtPriceStartX96;  // 本轮开始价格
    int24 nextTick;             // 下一个已初始化 tick
    uint160 sqrtPriceNextX96;   // 下一个 tick 的价格
    uint256 amountIn;           // 本价格范围可处理的输入量
    uint256 amountOut;          // 本价格范围提供的输出量
}
```

### 填单循环

```solidity
SwapState memory state = SwapState({
    amountSpecifiedRemaining: amountSpecified,
    amountCalculated: 0,
    sqrtPriceX96: slot0_.sqrtPriceX96,
    tick: slot0_.tick
});

while (state.amountSpecifiedRemaining > 0) {
    StepState memory step;

    step.sqrtPriceStartX96 = state.sqrtPriceX96;

    // 找到下一个有流动性的 tick
    (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
        state.tick, 1, zeroForOne
    );

    step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

    // 在当前价格范围内计算交换
    (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
        state.sqrtPriceX96,
        step.sqrtPriceNextX96,
        liquidity,
        state.amountSpecifiedRemaining
    );

    state.amountSpecifiedRemaining -= step.amountIn;
    state.amountCalculated += step.amountOut;
    state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
}
```

### SwapMath.computeSwapStep

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

    // 根据方向计算下一个价格
    sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
        sqrtPriceCurrentX96,
        liquidity,
        amountRemaining,
        zeroForOne
    );

    amountIn = Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);
    amountOut = Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);

    if (!zeroForOne) {
        (amountIn, amountOut) = (amountOut, amountIn);
    }
}
```

### 根据输入数量找目标价格

$$\text{当卖出 token0 时：} \sqrt{P_{next}} = \frac{L \cdot \sqrt{P_{cur}}}{L + \Delta x \cdot \sqrt{P_{cur}}}$$

$$\text{当卖出 token1 时：} \sqrt{P_{next}} = \sqrt{P_{cur}} + \frac{\Delta y}{L}$$

```solidity
function getNextSqrtPriceFromInput(
    uint160 sqrtPriceX96,
    uint128 liquidity,
    uint256 amountIn,
    bool zeroForOne
) internal pure returns (uint160 sqrtPriceNextX96) {
    sqrtPriceNextX96 = zeroForOne
        ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPriceX96, liquidity, amountIn)
        : getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, liquidity, amountIn);
}
```

---

## Quoter 合约

### 设计思路

由于 Uniswap V3 的流动性分散在多个价格范围，无法用公式直接计算交换数量。必须**模拟真实交换**来计算输出数量。

Quoter 合约调用 Pool 的 `swap` 函数，然后在回调中**主动 revert**，通过 revert 的原因返回计算结果。

```solidity
contract UniswapV3Quoter {
    struct QuoteParams {
        address pool;
        uint256 amountIn;
        bool zeroForOne;
    }

    function quote(QuoteParams memory params)
        public
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            int24 tickAfter
        )
    {
        try
            IUniswapV3Pool(params.pool).swap(
                address(this),
                params.zeroForOne,
                params.amountIn,
                abi.encode(params.pool)
            )
        {} catch (bytes memory reason) {
            return abi.decode(reason, (uint256, uint160, int24));
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory data
    ) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0
            ? uint256(-amount1Delta)
            : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter) = IUniswapV3Pool(pool).slot0();

        // 通过 revert 返回计算结果（使用 Yul 内联汇编优化 gas）
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            mstore(add(ptr, 0x40), tickAfter)
            revert(ptr, 96)
        }
    }
}
```

### Quoter 限制

由于 `quote` 调用了非 pure/view 的 `swap` 函数，Ethers.js 会将 `quote` 的调用作为交易发送。需要强制静态调用：

```javascript
quoter.callStatic.quote({ pool: config.poolAddress, amountIn: ..., zeroForOne: ... })
```

---

## Web 用户界面

### 双向交换 UI

```jsx
<form className="SwapForm">
  <SwapInput
    amount={zeroForOne ? amount0 : amount1}
    readOnly={false}
    setAmount={setAmount_(zeroForOne ? setAmount0 : setAmount1, zeroForOne)}
    token={zeroForOne ? pair[0] : pair[1]} />
  <ChangeDirectionButton zeroForOne={zeroForOne} setZeroForOne={setZeroForOne} />
  <SwapInput
    amount={zeroForOne ? amount1 : amount0}
    readOnly={true}  {/* 输出数量由 Quoter 计算，只读 */}
    token={zeroForOne ? pair[1] : pair[0]} />
  <button onClick={swap_}>Swap</button>
</form>
```

### 使用 Quoter 计算输出数量

```javascript
const updateAmountOut = debounce((amount) => {
  if (amount === 0 || amount === "0") return;

  setLoading(true);

  // 注意：使用 callStatic 强制静态调用
  quoter.callStatic
    .quote({
      pool: config.poolAddress,
      amountIn: ethers.utils.parseEther(amount),
      zeroForOne: zeroForOne
    })
    .then(({ amountOut }) => {
      zeroForOne
        ? setAmount1(ethers.utils.formatEther(amountOut))
        : setAmount0(ethers.utils.formatEther(amountOut));
      setLoading(false);
    });
});
```

---

*[← 里程碑 1：首次 Swap](./02-里程碑1-首次Swap.md) | [里程碑 3：跨 Tick Swap →](./04-里程碑3-跨Tick-Swap.md)*
