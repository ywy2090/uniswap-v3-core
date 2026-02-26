#!/usr/bin/env python3

"""
Uniswap v3 单个流动性头寸示例

该脚本展示了使用Uniswap v3 subgraph数据，
查询和显示USDC/DAI 0.05%费率池中单个流动性头寸的信息。

功能：
- 根据头寸ID查询头寸详情
- 计算该头寸在当前价格下的代币数量
- 显示头寸的价格范围和资产组成
"""

from gql import gql, Client
from gql.transport.requests import RequestsHTTPTransport
import math
import sys

# 默认头寸ID
POSITION_ID = "2"

# 如果在命令行中传递了参数，使用替代的头寸ID
if len(sys.argv) > 1:
    POSITION_ID = sys.argv[1]

# Tick基数：每个tick代表0.01%的价格变化
TICK_BASE = 1.0001

# GraphQL查询：获取头寸信息
position_query = """query get_position($position_id: ID!) {
  positions(where: {id: $position_id}) {
    liquidity
    tickLower { tickIdx }
    tickUpper { tickIdx }
    pool { id }
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

# GraphQL查询：获取池子的当前tick和价格平方根
pool_query = """query get_pools($pool_id: ID!) {
  pools(where: {id: $pool_id}) {
    tick
    sqrtPrice
  }
}"""

def tick_to_price(tick):
    """
    将tick索引转换为价格
    
    参数:
        tick: tick索引
    
    返回:
        价格（token1/token0的比率）
    """
    return TICK_BASE ** tick

# 创建GraphQL客户端
client = Client(
    transport=RequestsHTTPTransport(
        url='https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3',
        verify=True,
        retries=5,
    ))

# 获取头寸信息
try:
    variables = {"position_id": POSITION_ID}
    response = client.execute(gql(position_query), variable_values=variables)

    if len(response['positions']) == 0:
        print("position not found")
        exit(-1)

    position = response['positions'][0]
    liquidity = int(position["liquidity"])  # 头寸的流动性
    tick_lower = int(position["tickLower"]["tickIdx"])  # 价格范围下限tick
    tick_upper = int(position["tickUpper"]["tickIdx"])  # 价格范围上限tick
    pool_id = position["pool"]["id"]  # 池子ID

    # 获取代币信息
    token0 = position["token0"]["symbol"]
    token1 = position["token1"]["symbol"]
    decimals0 = int(position["token0"]["decimals"])
    decimals1 = int(position["token1"]["decimals"])

except Exception as ex:
    print("got exception while querying position data:", ex)
    exit(-1)

#print("pool id=", pool_id)

# 获取池子信息以得到当前价格
try:
    variables = {"pool_id": pool_id}
    response = client.execute(gql(pool_query), variable_values=variables)

    if len(response['pools']) == 0:
        print("pool not found")
        exit(-1)

    pool = response['pools'][0]
    current_tick = int(pool["tick"])  # 当前价格对应的tick
    # sqrtPrice存储为Q64.96格式的定点数，需要除以2^96
    current_sqrt_price = int(pool["sqrtPrice"]) / (2 ** 96)

except Exception as ex:
    print("got exception while querying pool data:", ex)
    exit(-1)

# 计算并打印当前价格
current_price = tick_to_price(current_tick)
adjusted_current_price = current_price / (10 ** (decimals1 - decimals0))
print("Current price={:.6f} {} for {} at tick {}".format(adjusted_current_price, token1, token0, current_tick))

# 计算头寸价格范围边界的平方根
sa = tick_to_price(tick_lower / 2)  # √P_a
sb = tick_to_price(tick_upper / 2)  # √P_b

# 根据当前价格位置计算头寸中的代币数量
if tick_upper <= current_tick:
    # 当前价格高于头寸范围上限：只有token1被锁定
    amount0 = 0
    amount1 = liquidity * (sb - sa)
elif tick_lower < current_tick < tick_upper:
    # 当前价格在头寸范围内：两种代币都存在
    amount0 = liquidity * (sb - current_sqrt_price) / (current_sqrt_price * sb)
    amount1 = liquidity * (current_sqrt_price - sa)
else:
    # 当前价格低于头寸范围下限：只有token0被锁定
    amount0 = liquidity * (sb - sa) / (sa * sb)
    amount1 = 0

# 打印头寸信息
adjusted_amount0 = amount0 / (10 ** decimals0)  # 调整小数位数
adjusted_amount1 = amount1 / (10 ** decimals1)  # 调整小数位数
print("  position {: 7d} in range [{},{}]: {:.2f} {} and {:.2f} {} at the current price".format(
      int(POSITION_ID), tick_lower, tick_upper,
      adjusted_amount0, token0, adjusted_amount1, token1))
