# Uniswap v3 流动性数学 / Uniswap v3 Liquidity Math

> 💡 **新手？** 从这里开始 → [📖 快速开始指南](快速开始.md)  
> 📚 **想全面了解？** 查看 → [📋 项目完整概览](项目概览.md)

## 概述 / Overview

本项目实现了Uniswap v3流动性数学的核心公式和示例代码。

**中文说明：**
- 本仓库包含Uniswap v3流动性计算的完整实现
- 所有代码文件都已添加详尽的中文注释
- 新增了[`公式原理详解.md`](公式原理详解.md)文档，详细解释了所有公式的推导过程和应用场景
- 适合希望深入理解Uniswap v3数学原理的开发者和研究者

**English:**

See the technical note [Liquidity Math in Uniswap v3](http://atiselsts.github.io/pdfs/uniswap-v3-liquidity-math.pdf) and the [Uniswap v3 whitepaper](https://uniswap.org/whitepaper-v3.pdf) for the description of the purpose of this code.

For a Jupyter Notebook version of the code, see [yj's](https://github.com/uniyj) work here: https://github.com/uniyj/uni-v3-peri/tree/main/atiselsts-uniswap-v3-liquidity-math.

Have questions? Feel free to contact me via email atis.elsts@gmail.com or DM (https://twitter.com/atiselsts_eth). I'm also offering paid consultations on this topic.

## 文件说明 / Contents

### 核心模块 / Core Module

* **[`集中流动性通俗讲解.md`](集中流动性通俗讲解.md)** - **强烈推荐！新手从这里开始** 📚
  - 用生活例子理解集中流动性（货币兑换店比喻）
  - Uniswap v2 vs v3 直观对比
  - 从零开始的公式推导（每一步都有解释）
  - 完整工作流程图解
  - 实战案例：带完整Python代码的一步步操作
  - 适合：初学者、想快速理解核心概念的人

* **[`公式原理详解.md`](公式原理详解.md)** - **深入学习版** 📐
  - 核心概念详解（流动性、价格平方根、Tick机制）
  - 完整的公式推导过程
  - 实际应用案例分析
  - 数学符号对照表
  - 适合：有一定数学基础、想深入理解的人

* **[`uniswap-v3-liquidity-math.py`](uniswap-v3-liquidity-math.py)** - 实现"Liquidity Math in Uniswap v3"论文中的公式和示例
  - Implementation of the equations and examples from the "Liquidity Math in Uniswap v3" paper
  - 流动性计算、代币数量计算、价格边界计算

### Subgraph查询示例 / Subgraph Query Examples

* **[`subgraph-liquidity-query-example.py`](subgraph-liquidity-query-example.py)** - 查询USDC/WETH 0.3%池当前tick范围内锁定的资产数量
  - Query the amounts locked in the current tick range of the USDC/WETH 0.3% pool

* **[`subgraph-liquidity-range-example.py`](subgraph-liquidity-range-example.py)** - 显示USDC/WETH 0.3%池所有非零liquidityNet的tick中锁定的资产
  - Shows the amounts locked in all ticks with nonzero `liquidityNet`

* **[`subgraph-liquidity-single-position-example.py`](subgraph-liquidity-single-position-example.py)** - 查询单个流动性头寸的详细信息
  - Shows details of a single liquidity position

* **[`subgraph-liquidity-positions-example.py`](subgraph-liquidity-positions-example.py)** - 显示USDC/WETH 0.3%池所有活跃头寸中锁定的资产
  - Shows the amounts locked in all active positions

* **[`subgraph-implied-volatility-example.py`](subgraph-implied-volatility-example.py)** - 计算池子的隐含波动率
  - Calculates the implied volatility of the pool

## 安装和使用 / Installation and Usage

**中文说明：**

部分脚本需要 `gql` Python模块。安装依赖：

```bash
pip install -r requirements.txt
```

从命令行执行脚本，例如：

```bash
# Windows
python subgraph-liquidity-range-example.py

# Linux/Mac
./subgraph-liquidity-range-example.py
```

可选：指定不同的池子ID作为命令行参数

```bash
python subgraph-liquidity-range-example.py 0x池子地址
```

**English:**

Some scripts need the `gql` Python module. Install this dependency with:

```bash
pip install -r requirements.txt
```

Execute from the command line, for example with:

```bash
./subgraph-liquidity-range-example.py
```

## 学习路径建议 / Recommended Learning Path

### 🎯 三条学习路径

#### **路径1：快速入门（推荐新手）⭐**

1. **第一步**：阅读[`集中流动性通俗讲解.md`](集中流动性通俗讲解.md)
   - 先看"用生活例子理解集中流动性"
   - 理解Uniswap v2 vs v3的差异
   - 跟着"实战案例"运行Python代码

2. **第二步**：运行`uniswap-v3-liquidity-math.py`
   ```bash
   python uniswap-v3-liquidity-math.py
   ```
   - 观察三个示例的输出
   - 对照代码注释理解每一步

3. **第三步**：尝试修改参数
   - 改变价格范围
   - 改变资产数量
   - 观察结果变化

**预计学习时间**：2-3小时

---

#### **路径2：深入理解（有基础者）⭐⭐**

1. **系统学习**：
   - [`集中流动性通俗讲解.md`](集中流动性通俗讲解.md) - 理解概念和工作流程
   - [`公式原理详解.md`](公式原理详解.md) - 深入数学推导
   - 代码注释 - 看实现细节

2. **实践验证**：
   - 运行所有Python示例脚本
   - 用自己的数据重新计算
   - 比较不同策略的收益

3. **真实数据**：
   - 运行subgraph示例脚本
   - 分析真实池子的流动性分布
   - 研究活跃头寸的策略

**预计学习时间**：1-2天

---

#### **路径3：精通应用（开发者/量化交易者）⭐⭐⭐**

1. **完整掌握**：
   - 所有文档和代码
   - Uniswap v3白皮书
   - 智能合约源码

2. **开发应用**：
   - 实现自己的流动性优化策略
   - 开发自动再平衡机器人
   - 回测历史数据

3. **高级主题**：
   - 无常损失对冲
   - 多头寸策略
   - Gas优化

**预计学习时间**：1-2周

---

### 📚 快速参考

**我想...**

| 目标 | 推荐文档 | 难度 |
|------|---------|------|
| 快速理解集中流动性 | [`集中流动性通俗讲解.md`](集中流动性通俗讲解.md) | ⭐ |
| 理解公式推导 | [`公式原理详解.md`](公式原理详解.md) | ⭐⭐ |
| 看实际应用 | `uniswap-v3-liquidity-math.py` | ⭐ |
| 查看链上数据 | `subgraph-*-example.py` | ⭐⭐ |
| 计算隐含波动率 | `subgraph-implied-volatility-example.py` | ⭐⭐⭐ |

**关键概念 / Key Concepts:**

- ✅ 流动性L的计算和意义
- ✅ 价格平方根(√P)的使用原因
- ✅ Tick机制和价格离散化
- ✅ 集中流动性的资本效率优势
- ✅ 价格变化时的资产重新分配
- ✅ 无常损失(Impermanent Loss)的计算

## Example outputs

### Example output of `uniswap-v3-liquidity-math.py`

```
Example 1: how much of USDC I need when providing 2 ETH at this price and range?
amount of USDC y=5076.10
p_a=1500.00 (75.00% of P), p_b=2500.00 (125.00% of P)

Example 2: I have 2 ETH and 4000 USDC, range top set to 3000 USDC. What's the bottom of the range?
lower bound of the price p_a=1333.33

Example 3: Using the position created in Example 2, what are asset balances at 2500 USDC per ETH?
Amount of ETH x=0.85 amount of USDC y=6572.89
delta_x=-1.15 delta_y=2572.89
Amount of ETH x=0.85 amount of USDC y=6572.89
```

### Example output of `subgraph-liquidity-query-example.py`

```
L=22510401004259913887
tick=195879
Current price: 0.000321 WETH for 1 USDC (3115.361406 USDC for 1 WETH)
Amounts at the current tick range: 1318490.67 USDC and 785.63 WETH
```

### Example output of `subgraph-liquidity-range-example.py`

```
...
tick=195660 price=3184.336897 USDC for WETH
        1193.68 WETH locked (potentially worth 3789699.28 USDC)
tick=195720 price=3165.289029 USDC for WETH
        1199.90 WETH locked (potentially worth 3786639.86 USDC)
tick=195780 price=3146.355100 USDC for WETH
        1218.77 WETH locked (potentially worth 3823192.07 USDC)
tick=195840 price=3127.534429 USDC for WETH
        Current tick, both assets present!
        1332170.50 USDC and 781.24 WETH remaining in the current tick range
        potentially 3770791.99 USDC or 1209.30 WETH in total in the current tick range
tick=195900 price=3108.826338 USDC for WETH
        3748424.25 USDC locked (potentially worth 1209.36 WETH)
tick=195960 price=3090.230154 USDC for WETH
        3782324.42 USDC locked (potentially worth 1227.64 WETH)
tick=196020 price=3071.745208 USDC for WETH
        3762895.47 USDC locked (potentially worth 1228.68 WETH)
tick=196080 price=3053.370833 USDC for WETH
        3740185.70 USDC locked (potentially worth 1228.62 WETH)
...
```

## 常见问题 / FAQ

### 中文FAQ

**Q1: 为什么Uniswap v3使用价格的平方根而不是价格本身？**

A: 使用√P有三个主要优势：
- 数学简化：将复杂的乘除法转换为加减法
- 精度提升：避免极端价格值导致的精度损失
- Gas优化：智能合约中的计算更高效

**Q2: 流动性L到底是什么？**

A: L是一个抽象的数学量，表示在特定价格范围内可用于交易的"深度"。它不是简单的资产价值相加，而是通过特定公式计算得出。L越大，交易时的价格滑点越小。

**Q3: 如何选择最优的价格范围？**

A: 需要权衡：
- 范围越窄：资本效率越高，但价格容易超出范围
- 范围越宽：更安全，但资本效率较低
- 建议：根据资产的历史波动率和个人风险偏好选择

**Q4: 这些公式在实际应用中的精度如何？**

A: 代码使用Python的浮点运算，主要用于教学和原型设计。实际的Uniswap v3智能合约使用Q64.96定点数运算，精度更高。

**Q5: 代码中的"potentially worth"是什么意思？**

A: 表示如果价格移动到该tick范围，锁定的代币理论上可以转换成的另一种代币的数量。这是一个虚拟值，不是实际持有的数量。

**Q6: 如何理解无常损失(Impermanent Loss)？**

A: 在Uniswap v3中，当价格移出你的流动性范围时：
- 你的资产完全变成单一代币
- 相比简单持有，可能产生损失
- 但在范围内时，可以赚取手续费补偿

参考[`集中流动性通俗讲解.md`](集中流动性通俗讲解.md)中的实战案例，有完整的计算示例。

**Q7: 两个中文文档有什么区别？我应该看哪个？**

A: 
- **[`集中流动性通俗讲解.md`](集中流动性通俗讲解.md)** - 入门必读！
  - ✅ 用生活例子解释（货币兑换店）
  - ✅ 可视化图表
  - ✅ 完整Python代码示例
  - ✅ 适合快速理解核心概念
  
- **[`公式原理详解.md`](公式原理详解.md)** - 深入学习版
  - 📐 严谨的数学推导
  - 📐 详细的公式列表
  - 📐 数学符号对照表
  - 📐 适合有数学基础的读者

**建议**：先看通俗讲解，理解了再看公式详解。

### English FAQ

**Q: Why use square root of price?**

A: It simplifies the math, improves precision, and optimizes gas costs in smart contracts.

**Q: What exactly is liquidity L?**

A: L is an abstract mathematical measure of trading depth within a price range, not simply the sum of asset values.

**Q: How accurate are these calculations?**

A: The Python code uses floating-point math for educational purposes. The actual Uniswap v3 contracts use Q64.96 fixed-point arithmetic for higher precision.

---

## 贡献 / Contributing

欢迎提交Issue和Pull Request！特别欢迎：
- 发现并修复注释中的错误
- 改进公式说明的清晰度
- 添加更多实用示例
- 翻译改进

Contributions are welcome! Especially:
- Bug fixes in comments
- Improvements to formula explanations
- Additional practical examples
- Translation improvements

---

## 许可证 / License

请参考原始仓库的许可证信息。

See the original repository for license information.

---

**最后更新 / Last Updated**: 2026-02-06  
**中文注释添加 / Chinese Comments Added**: 2026-02-06
