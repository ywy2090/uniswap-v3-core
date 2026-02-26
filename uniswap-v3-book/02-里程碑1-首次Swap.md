# 里程碑 1：首次 Swap

> 来源：[uniswapv3book.com/milestone_1](https://uniswapv3book.com/milestone_1/introduction.html)  
> 完整源码：[milestone_1 分支](https://github.com/Jeiwan/uniswapv3-code/tree/milestone_1)

---

## 介绍

在这个里程碑中，我们将构建一个可以接收用户流动性并在价格范围内进行交换的池合约。为保持简单：

- 只在一个价格范围内提供流动性
- 只允许在一个方向进行交换
- 手动计算所有必要的数学

**模型设定：**
1. 从池中购买一些 ETH（使用 USDC）
2. 流动性提供的价格范围：**4545 - 5500 USDC/ETH**
3. 当前价格设为：**5000 USDC/ETH**
4. ETH/USDC 池合约，ETH 为 $x$ 储备，USDC 为 $y$ 储备

---

## 流动性计算

### 价格范围计算

在 Uniswap V3 中，整个价格范围被分成 tick。每个 tick 对应一个价格，有一个索引。

**需要找到三个 tick：**
- 下界（$P_{lower}$ = $4545）
- 上界（$P_{upper}$ = $5500）
- 当前（$P_{current}$ = $5000）

从理论介绍中，我们知道：

$$\sqrt{P} = \sqrt{\frac{y}{x}}$$

使用公式 $i = \lfloor \log_{1.0001} P \rfloor$ 计算 tick：

```python
import math

def price_to_tick(p):
    return math.floor(math.log(p, 1.0001))

price_to_tick(5000)  # 85176
price_to_tick(4545)  # 84222
price_to_tick(5500)  # 86129
```

**Q64.96 格式的 sqrtPrice：**

```python
q96 = 2**96

def price_to_sqrtp(p):
    return int(math.sqrt(p) * q96)

price_to_sqrtp(5000)   # 5602277097478614198912276234240
price_to_sqrtp(4545)   # 5341294542274603921957108213760
price_to_sqrtp(5500)   # 5875717789736564987741329268736
```

### 代币数量计算

我们将存入：**1 ETH** 和 **5000 USDC**

### 流动性数量计算 $L$

流动性 $L$ 的计算公式（针对有限价格范围）：

$$L_x = \frac{\Delta x \cdot \sqrt{P_{cur}} \cdot \sqrt{P_{upp}}}{\sqrt{P_{upp}} - \sqrt{P_{cur}}}$$

$$L_y = \frac{\Delta y}{\sqrt{P_{cur}} - \sqrt{P_{low}}}$$

最终取两者中的**较小值**。

```python
sqrtp_low = price_to_sqrtp(4545)
sqrtp_cur = price_to_sqrtp(5000)
sqrtp_upp = price_to_sqrtp(5500)

def liquidity0(amount, pa, pb):
    if pa > pb:
        pa, pb = pb, pa
    return (amount * (pa * pb) / q96) / (pb - pa)

def liquidity1(amount, pa, pb):
    if pa > pb:
        pa, pb = pb, pa
    return amount * q96 / (pb - pa)

eth = 10**18
amount_eth = 1 * eth
amount_usdc = 5000 * eth

liq0 = liquidity0(amount_eth, sqrtp_cur, sqrtp_upp)
liq1 = liquidity1(amount_usdc, sqrtp_cur, sqrtp_low)
liq = int(min(liq0, liq1))
# 1517882343751509868544
```

### 重新计算代币数量

```python
def calc_amount0(liq, pa, pb):
    if pa > pb:
        pa, pb = pb, pa
    return int(liq * q96 * (pb - pa) / pa / pb)

def calc_amount1(liq, pa, pb):
    if pa > pb:
        pa, pb = pb, pa
    return int(liq * (pb - pa) / q96)

amount0 = calc_amount0(liq, sqrtp_upp, sqrtp_cur)
amount1 = calc_amount1(liq, sqrtp_low, sqrtp_cur)
# (998976618347425408, 5000000000000000000000)
# 约 0.999 ETH 和 5000 USDC
```

---

## 提供流动性

### Pool 合约实现

```solidity
// src/UniswapV3Pool.sol
contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    address public immutable token0;
    address public immutable token1;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }
    Slot0 public slot0;

    uint128 public liquidity;
    
    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }
}
```

### mint 函数

`mint` 函数允许用户向池中添加流动性：

```solidity
function mint(
    address owner,
    int24 lowerTick,
    int24 upperTick,
    uint128 amount,
    bytes calldata data
) external returns (uint256 amount0, uint256 amount1) {
    if (lowerTick >= upperTick || lowerTick < MIN_TICK || upperTick > MAX_TICK)
        revert InvalidTickRange();
    
    if (amount == 0) revert ZeroLiquidity();

    ticks.update(lowerTick, amount);
    ticks.update(upperTick, amount);

    Position.Info storage position = positions.get(owner, lowerTick, upperTick);
    position.update(amount);

    // 硬编码金额（后续里程碑中会动态计算）
    amount0 = 0.998976618347425280 ether;
    amount1 = 5000 ether;

    liquidity += uint128(amount);

    uint256 balance0Before;
    uint256 balance1Before;
    if (amount0 > 0) balance0Before = balance0();
    if (amount1 > 0) balance1Before = balance1();
    
    IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
        amount0,
        amount1,
        data
    );

    if (amount0 > 0 && balance0Before + amount0 > balance0())
        revert InsufficientInputAmount();
    if (amount1 > 0 && balance1Before + amount1 > balance1())
        revert InsufficientInputAmount();

    emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
}
```

**关键概念：**
- 使用**回调**（callback）机制：池合约调用 `uniswapV3MintCallback`，调用者负责转账代币
- 这样设计允许核心合约不依赖 ERC20 的 `transferFrom`

---

## 首次 Swap

### 计算交换数量

我们将用 42 USDC 购买 ETH。

**已知：** $L = 1517882343751509868544$，$\sqrt{P_{cur}}$，$\Delta y = 42$

**计算新的 $\sqrt{P}$：**

$$\sqrt{P_{next}} = \sqrt{P_{cur}} + \frac{\Delta y}{L}$$

```python
amount_in = 42 * eth
price_diff = (amount_in * q96) // liq
price_next = sqrtp_cur + price_diff

print("新价格:", (price_next / q96) ** 2)   # 5003.91
print("新 sqrtP:", price_next)              # 5604469350942327889444743441197
print("新 tick:", price_to_tick((price_next / q96) ** 2))  # 85184

amount_in = calc_amount1(liq, price_next, sqrtp_cur)
amount_out = calc_amount0(liq, price_next, sqrtp_cur)
# USDC in: 42.0
# ETH out: 0.008396714242162444
```

### swap 函数实现

```solidity
function swap(address recipient, bytes calldata data)
    public
    returns (int256 amount0, int256 amount1)
{
    // 硬编码目标 tick 和价格
    int24 nextTick = 85184;
    uint160 nextPrice = 5604469350942327889444743441197;

    amount0 = -0.008396714242162444 ether;
    amount1 = 42 ether;

    // 更新当前 tick 和 sqrtP
    (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);

    // 发送 token0（ETH）给接收者
    IERC20(token0).transfer(recipient, uint256(-amount0));

    // 通过回调从调用者获取 token1（USDC）
    uint256 balance1Before = balance1();
    IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
        amount0,
        amount1,
        data
    );
    if (balance1Before + uint256(amount1) < balance1())
        revert InsufficientInputAmount();

    emit Swap(
        msg.sender, recipient,
        amount0, amount1,
        slot0.sqrtPriceX96, liquidity, slot0.tick
    );
}
```

### 测试

```solidity
function testSwapBuyEth() public {
    // 设置参数...
    
    // 给测试合约 42 USDC
    token1.mint(address(this), 42 ether);
    
    // 执行交换
    (int256 amount0Delta, int256 amount1Delta) = pool.swap(address(this));

    // 验证金额
    assertEq(amount0Delta, -0.008396714242162444 ether, "ETH out 错误");
    assertEq(amount1Delta, 42 ether, "USDC in 错误");
    
    // 验证状态
    (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
    assertEq(sqrtPriceX96, 5604469350942327889444743441197, "sqrtP 错误");
    assertEq(tick, 85184, "tick 错误");
}
```

---

## 管理器合约

### 为什么需要管理器合约？

Pool 合约是核心合约，期望调用者完成所有计算并提供正确的参数。它也使用回调而非 `transferFrom`。只有合约才能实现回调，所以普通用户（非合约地址）无法直接调用 Pool 合约。

**管理器合约** 作为用户和池之间的中介。

### 传递回调数据

首先，定义回调数据结构：

```solidity
// src/UniswapV3Pool.sol
struct CallbackData {
    address token0;
    address token1;
    address payer;
}
```

在 `mint` 和 `swap` 中传递编码数据：

```solidity
IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
    amount0,
    amount1,
    data  // 编码的 CallbackData
);
```

### 管理器合约实现

```solidity
// src/UniswapV3Manager.sol
contract UniswapV3Manager {
    function mint(
        address poolAddress_,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        bytes calldata data
    ) public {
        UniswapV3Pool(poolAddress_).mint(
            msg.sender,
            lowerTick,
            upperTick,
            liquidity,
            data
        );
    }

    function swap(address poolAddress_, bytes calldata data) public {
        UniswapV3Pool(poolAddress_).swap(msg.sender, data);
    }

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        UniswapV3Pool.CallbackData memory extra = abi.decode(
            data, (UniswapV3Pool.CallbackData)
        );
        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {
        UniswapV3Pool.CallbackData memory extra = abi.decode(
            data, (UniswapV3Pool.CallbackData)
        );
        if (amount0 > 0) {
            IERC20(extra.token0).transferFrom(extra.payer, msg.sender, uint256(amount0));
        }
        if (amount1 > 0) {
            IERC20(extra.token1).transferFrom(extra.payer, msg.sender, uint256(amount1));
        }
    }
}
```

---

## 部署

### 选择本地区块链网络

我们使用 **Anvil**（Foundry 工具包的一部分）：

```bash
anvil --code-size-limit 50000
```

Anvil 默认创建 10 个账户，每个账户有 10,000 ETH。它在 `127.0.0.1:8545` 暴露 JSON-RPC API。

### 部署脚本

```solidity
// scripts/DeployDevelopment.sol
contract DeployDevelopment is Script {
    function run() public {
        uint256 wethBalance = 1 ether;
        uint256 usdcBalance = 5042 ether;
        int24 currentTick = 85176;
        uint160 currentSqrtP = 5602277097478614198912276234240;

        vm.startBroadcast();

        // 部署代币
        ERC20Mintable token0 = new ERC20Mintable("Wrapped Ether", "WETH", 18);
        ERC20Mintable token1 = new ERC20Mintable("USD Coin", "USDC", 18);

        // 部署池
        UniswapV3Pool pool = new UniswapV3Pool(
            address(token0),
            address(token1),
            currentSqrtP,
            currentTick
        );

        // 部署管理器
        UniswapV3Manager manager = new UniswapV3Manager();

        // 铸造代币
        token0.mint(msg.sender, wethBalance);
        token1.mint(msg.sender, usdcBalance);

        vm.stopBroadcast();

        console.log("WETH address", address(token0));
        console.log("USDC address", address(token1));
        console.log("Pool address", address(pool));
        console.log("Manager address", address(manager));
    }
}
```

执行部署：

```bash
forge script scripts/DeployDevelopment.s.sol \
  --broadcast \
  --fork-url http://localhost:8545 \
  --private-key $PRIVATE_KEY \
  --code-size-limit 50000
```

### 与合约交互

使用 `cast` 工具查询链上状态：

```bash
# 查询当前价格和 tick
cast call POOL_ADDRESS "slot0()" | xargs cast --abi-decode "a()(uint160,int24)"

# 查询代币余额
cast call TOKEN_ADDRESS "balanceOf(address)" WALLET_ADDRESS
```

---

## 用户界面

### 工具概述

- **MetaMask**：以太坊钱包浏览器扩展，提供账户管理、签名和 provider 功能
- **Ethers.js**：以太坊 JavaScript 工具库，简化合约交互

### 连接 MetaMask

```javascript
const connect = () => {
  if (typeof window.ethereum === 'undefined') {
    return setStatus('not_installed');
  }

  Promise.all([
    window.ethereum.request({ method: 'eth_requestAccounts' }),
    window.ethereum.request({ method: 'eth_chainId' }),
  ]).then(function ([accounts, chainId]) {
    setAccount(accounts[0]);
    setChain(chainId);
    setStatus('connected');
  });
};
```

### 提供流动性

```javascript
const addLiquidity = (account, { token0, token1, manager }, { managerAddress, poolAddress }) => {
  const amount0 = ethers.utils.parseEther("0.998976618347425280");
  const amount1 = ethers.utils.parseEther("5000");
  const lowerTick = 84222;
  const upperTick = 86129;
  const liquidity = ethers.BigNumber.from("1517882343751509868544");
  const extra = ethers.utils.defaultAbiCoder.encode(
    ["address", "address", "address"],
    [token0.address, token1.address, account]
  );

  // 检查授权并调用 mint
  Promise.all([
    token0.allowance(account, managerAddress),
    token1.allowance(account, managerAddress)
  ]).then(([allowance0, allowance1]) => {
    return Promise.resolve()
      .then(() => {
        if (allowance0.lt(amount0)) {
          return token0.approve(managerAddress, amount0).then(tx => tx.wait());
        }
      })
      .then(() => {
        if (allowance1.lt(amount1)) {
          return token1.approve(managerAddress, amount1).then(tx => tx.wait());
        }
      })
      .then(() => {
        return manager.mint(poolAddress, lowerTick, upperTick, liquidity, extra)
          .then(tx => tx.wait());
      });
  });
};
```

### 交换代币

```javascript
const swap = (amountIn, account, { tokenIn, manager, token0, token1 }, { managerAddress, poolAddress }) => {
  const amountInWei = ethers.utils.parseEther(amountIn);
  const extra = ethers.utils.defaultAbiCoder.encode(
    ["address", "address", "address"],
    [token0.address, token1.address, account]
  );

  tokenIn.allowance(account, managerAddress)
    .then((allowance) => {
      if (allowance.lt(amountInWei)) {
        return tokenIn.approve(managerAddress, amountInWei).then(tx => tx.wait());
      }
    })
    .then(() => {
      return manager.swap(poolAddress, extra).then(tx => tx.wait());
    });
};
```

### 订阅合约事件

```javascript
const subscribeToEvents = (pool, callback) => {
  pool.on("Mint", (sender, owner, tickLower, tickUpper, amount, amount0, amount1, event) =>
    callback(event)
  );
  pool.on("Swap", (sender, recipient, amount0, amount1, sqrtPriceX96, liquidity, tick, event) =>
    callback(event)
  );
};

// 查询历史事件
Promise.all([
  pool.queryFilter("Mint", "earliest", "latest"),
  pool.queryFilter("Swap", "earliest", "latest"),
]).then(([mints, swaps]) => {
  // 处理历史事件
});
```

---

*[← 背景知识](./01-背景知识.md) | [里程碑 2：第二次 Swap →](./03-里程碑2-第二次Swap.md)*
