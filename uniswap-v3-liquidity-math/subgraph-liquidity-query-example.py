#!/usr/bin/env python3

"""
Uniswap v3 流动性查询示例

该脚本展示了使用Uniswap v3 subgraph的流动性数据，
打印USDC/ETH 0.3%费率池中当前的虚拟资产数量。

功能：
- 查询池子的当前流动性和价格信息
- 计算当前tick范围内的资产数量
- 显示可读格式的价格和资产余额

注意：该脚本使用urllib而不是gql库进行HTTP请求
"""

import json
import urllib.request
import math
import sys

# 查看USDC/ETH 0.3%费率池
POOL_ID = '0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8'

# 如果在命令行中传递了参数，使用替代的池子ID
if len(sys.argv) > 1:
    POOL_ID = sys.argv[1]

# Uniswap v3 subgraph的URL
URL = "https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3"
# Tick基数
TICK_BASE = 1.0001

# GraphQL查询：获取池子信息
query = """query pools($pool_id: ID!) {
  pools (where: {id: $pool_id}) {
    tick
    liquidity
    feeTier
    token0 {
      symbol
      decimals
    }
    token1 {
      symbol
      decimals
    }
  }
}"""

def tick_to_price(tick):
    """
    将Uniswap v3的tick转换为价格（即代币数量之间的比率：token1/token0）
    
    参数:
        tick: tick索引
    
    返回:
        价格
    """
    return TICK_BASE ** tick

def fee_tier_to_tick_spacing(fee_tier):
    """
    根据池子的费率等级确定tick间距
    
    并非所有tick都可以被初始化。Tick间距由池子的费率等级决定。
    
    参数:
        fee_tier: 费率等级（以万分之一为单位）
    
    返回:
        tick间距
    """
    return {
        100: 1,      # 0.01%费率 -> tick间距1
        500: 10,     # 0.05%费率 -> tick间距10
        3000: 60,    # 0.3%费率 -> tick间距60
        10000: 200   # 1%费率 -> tick间距200
    }.get(fee_tier, 60)


# 查询subgraph
# 构建HTTP请求
req = urllib.request.Request(URL)
req.add_header('Content-Type', 'application/json; charset=utf-8')

# 准备GraphQL查询数据
jsondata = {"query": query, "variables": {"pool_id": POOL_ID}}
jsondataasbytes = json.dumps(jsondata).encode('utf-8')
req.add_header('Content-Length', len(jsondataasbytes))

# 发送请求并获取响应
response = urllib.request.urlopen(req, jsondataasbytes)
obj = json.load(response)
pool = obj['data']['pools'][0]

# 从响应中提取流动性数据
L = int(pool["liquidity"])  # 池子的总流动性
tick = int(pool["tick"])    # 当前价格对应的tick
tick_spacing = fee_tier_to_tick_spacing(int(pool["feeTier"]))  # tick间距

print("L={}".format(L))
print("tick={}".format(tick))

# 获取代币信息
token0 = pool["token0"]["symbol"]  # 例如：USDC
token1 = pool["token1"]["symbol"]  # 例如：WETH
decimals0 = int(pool["token0"]["decimals"])  # USDC有6位小数
decimals1 = int(pool["token1"]["decimals"])  # WETH有18位小数

# 计算当前tick所在的范围
# 这段代码在Python中也可以写成: `tick // tick_spacing * tick_spacing`
# 但是，使用floor()更具可移植性
bottom_tick = math.floor(tick / tick_spacing) * tick_spacing  # 范围底部tick
top_tick = bottom_tick + tick_spacing                          # 范围顶部tick

# 计算当前价格并调整为人类可读的格式
price = tick_to_price(tick)
# 调整价格以考虑代币的小数位数差异
adjusted_price = price / (10 ** (decimals1 - decimals0))

# 计算对应于底部和顶部tick的价格平方根
sa = tick_to_price(bottom_tick // 2)  # √P_a (底部tick)
sb = tick_to_price(top_tick // 2)     # √P_b (顶部tick)
sp = price ** 0.5                      # √P (当前价格)

# 计算当前tick范围内两种资产的实际数量
# 使用Uniswap v3流动性数学公式
amount0 = L * (sb - sp) / (sp * sb)  # token0的数量
amount1 = L * (sp - sa)              # token1的数量

# 调整为人类可读的格式（考虑小数位数）
adjusted_amount0 = amount0 / 10 ** decimals0
adjusted_amount1 = amount1 / 10 ** decimals1

# 打印当前价格（两种表示方式）
print("Current price: {:.6f} {} for 1 {} ({:.6f} {} for 1 {})".format(
    adjusted_price, token1, token0, 1 / adjusted_price, token0, token1))

# 打印当前tick范围内锁定的代币数量
print("Amounts at the current tick range: {:.2f} {} and {:.2f} {}".format(
    adjusted_amount0, token0, adjusted_amount1, token1))
