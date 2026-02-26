#!/usr/bin/env python3

"""
Uniswap v3 所有活跃流动性头寸示例

该脚本展示了使用Uniswap v3 subgraph数据，
显示USDC/ETH 0.3%费率池中所有活跃的流动性头寸。

功能：
- 查询池子中所有活跃头寸（流动性>0）
- 计算每个头寸在当前价格下的代币数量
- 统计池子中的总资产和总流动性
"""

from gql import gql, Client
from gql.transport.requests import RequestsHTTPTransport
import math
import sys

# 默认池子ID是0.3%费率的USDC/ETH池
POOL_ID = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"

# 如果在命令行中传递了参数，使用替代的池子ID
if len(sys.argv) > 1:
    POOL_ID = sys.argv[1]

# Tick基数
TICK_BASE = 1.0001

# GraphQL查询：获取池子信息
pool_query = """query get_pools($pool_id: ID!) {
  pools(where: {id: $pool_id}) {
    tick
    sqrtPrice
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

# GraphQL查询：仅返回开放的头寸（流动性 > 0）
position_query = """query get_positions($num_skip: Int, $pool_id: ID!) {
  positions(skip: $num_skip, where: {pool: $pool_id, liquidity_gt: 0}) {
    id
    tickLower { tickIdx }
    tickUpper { tickIdx }
    liquidity
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

# 获取池子信息
try:
    variables = {"pool_id": POOL_ID}
    response = client.execute(gql(pool_query), variable_values=variables)

    if len(response['pools']) == 0:
        print("pool not found")
        exit(-1)

    pool = response['pools'][0]
    pool_liquidity = int(pool["liquidity"])  # 池子的总流动性
    current_tick = int(pool["tick"])  # 当前价格对应的tick

    # 获取代币信息
    token0 = pool["token0"]["symbol"]
    token1 = pool["token1"]["symbol"]
    decimals0 = int(pool["token0"]["decimals"])
    decimals1 = int(pool["token1"]["decimals"])
except Exception as ex:
    print("got exception while querying pool data:", ex)
    exit(-1)

# 获取所有头寸信息
positions = []  # 存储所有头寸的列表
num_skip = 0    # 分页查询的偏移量
try:
    while True:
        print("Querying positions, num_skip={}".format(num_skip))
        variables = {"num_skip": num_skip, "pool_id": POOL_ID}
        response = client.execute(gql(position_query), variable_values=variables)

        # 如果没有更多结果，退出循环
        if len(response["positions"]) == 0:
            break
        
        # 更新偏移量
        num_skip += len(response["positions"])
        
        # 提取头寸数据并存储
        for item in response["positions"]:
            tick_lower = int(item["tickLower"]["tickIdx"])  # 价格下限tick
            tick_upper = int(item["tickUpper"]["tickIdx"])  # 价格上限tick
            liquidity = int(item["liquidity"])              # 流动性
            id = int(item["id"])                            # 头寸ID
            positions.append((tick_lower, tick_upper, liquidity, id))
except Exception as ex:
    print("got exception while querying position data:", ex)
    exit(-1)

# 计算并打印当前价格
current_price = tick_to_price(current_tick)
current_sqrt_price = tick_to_price(current_tick / 2)  # 当前价格的平方根
adjusted_current_price = current_price / (10 ** (decimals1 - decimals0))
print("Current price={:.6f} {} for {} at tick {}".format(adjusted_current_price, token1, token0, current_tick))


# 累计所有活跃流动性和池中的总资产数量
active_positions_liquidity = 0  # 活跃头寸的总流动性
total_amount0 = 0               # token0的总数量
total_amount1 = 0               # token1的总数量

# 打印所有活跃头寸
for tick_lower, tick_upper, liquidity, id in sorted(positions):

    # 计算价格范围边界的平方根
    sa = tick_to_price(tick_lower / 2)  # √P_a
    sb = tick_to_price(tick_upper / 2)  # √P_b

    if tick_upper <= current_tick:
        # 当前价格高于头寸范围：只有token1被锁定
        amount1 = liquidity * (sb - sa)
        total_amount1 += amount1

    elif tick_lower < current_tick < tick_upper:
        # 当前价格在头寸范围内：两种代币都存在（活跃头寸）
        amount0 = liquidity * (sb - current_sqrt_price) / (current_sqrt_price * sb)
        amount1 = liquidity * (current_sqrt_price - sa)
        adjusted_amount0 = amount0 / (10 ** decimals0)
        adjusted_amount1 = amount1 / (10 ** decimals1)

        total_amount0 += amount0
        total_amount1 += amount1
        active_positions_liquidity += liquidity  # 累加活跃流动性

        # 打印活跃头寸的详细信息
        print("  position {: 7d} in range [{},{}]: {:.2f} {} and {:.2f} {} at the current price".format(
              id, tick_lower, tick_upper,
              adjusted_amount0, token0, adjusted_amount1, token1))
    else:
        # 当前价格低于头寸范围：只有token0被锁定
        amount0 = liquidity * (sb - sa) / (sa * sb)
        total_amount0 += amount0


# 打印统计信息
print("In total (including inactive positions): {:.2f} {} and {:.2f} {}".format(
      total_amount0 / 10 ** decimals0, token0, total_amount1 / 10 ** decimals1, token1))
print("Total liquidity from active positions: {}, from pool: {} (should be equal)".format(
      active_positions_liquidity, pool_liquidity))
