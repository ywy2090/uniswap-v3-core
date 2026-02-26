#!/usr/bin/env python3

"""
Uniswap v3 流动性分布范围示例

该脚本展示了使用Uniswap v3 subgraph数据，
显示USDC/ETH 0.3%费率池中当前流动性分布的完整范围。

功能：
- 查询指定池子的所有tick数据
- 计算每个tick范围内锁定的代币数量
- 显示完整的流动性分布情况
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

# Tick基数：每个tick代表0.01%的价格变化
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

# GraphQL查询：获取tick信息
# 使用分页查询，每次跳过$num_skip个结果
tick_query = """query get_ticks($num_skip: Int, $pool_id: ID!) {
  ticks(skip: $num_skip, where: {pool: $pool_id}) {
    tickIdx
    liquidityNet
  }
}"""


def tick_to_price(tick):
    """
    将tick索引转换为价格
    
    参数:
        tick: tick索引
    
    返回:
        价格（token1/token0的比率）
    
    公式: price = 1.0001 ^ tick
    """
    return TICK_BASE ** tick

def fee_tier_to_tick_spacing(fee_tier):
    """
    根据池子的费率等级确定tick间距
    
    并非所有tick都可以被初始化。Tick间距由池子的费率等级决定：
    - 0.01% (100): tick间距为1
    - 0.05% (500): tick间距为10
    - 0.3% (3000): tick间距为60
    - 1% (10000): tick间距为200
    
    参数:
        fee_tier: 费率等级（以万分之一为单位，例如3000表示0.3%）
    
    返回:
        tick间距
    """
    return {
        100: 1,
        500: 10,
        3000: 60,
        10000: 200
    }.get(fee_tier, 60)


# 创建GraphQL客户端，连接到Uniswap v3 subgraph
client = Client(
    transport=RequestsHTTPTransport(
        url='https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3',
        verify=True,
        retries=5,  # 失败时重试5次
    ))

# 获取池子信息
try:
    variables = {"pool_id": POOL_ID}
    response = client.execute(gql(pool_query), variable_values=variables)

    if len(response['pools']) == 0:
        print("pool not found")
        exit(-1)

    pool = response['pools'][0]
    current_tick = int(pool["tick"])  # 当前价格对应的tick
    tick_spacing = fee_tier_to_tick_spacing(int(pool["feeTier"]))  # 计算tick间距

    # 获取代币信息
    token0 = pool["token0"]["symbol"]  # token0的符号（通常是USDC）
    token1 = pool["token1"]["symbol"]  # token1的符号（通常是WETH）
    decimals0 = int(pool["token0"]["decimals"])  # token0的小数位数
    decimals1 = int(pool["token1"]["decimals"])  # token1的小数位数
except Exception as ex:
    print("got exception while querying pool data:", ex)
    exit(-1)

# 获取所有tick信息
# tick_mapping将tick索引映射到该tick的liquidityNet值
tick_mapping = {}
num_skip = 0  # 用于分页查询的偏移量
try:
    while True:
        print("Querying ticks, num_skip={}".format(num_skip))
        variables = {"num_skip": num_skip, "pool_id": POOL_ID}
        response = client.execute(gql(tick_query), variable_values=variables)

        # 如果没有更多结果，退出循环
        if len(response["ticks"]) == 0:
            break
        
        # 更新偏移量，准备下一次查询
        num_skip += len(response["ticks"])
        
        # 将tick数据存储到映射中
        # liquidityNet表示跨过该tick时流动性的净变化
        for item in response["ticks"]:
            tick_mapping[int(item["tickIdx"])] = int(item["liquidityNet"])
except Exception as ex:
    print("got exception while querying tick data:", ex)
    exit(-1)

    
# 从零开始累加流动性
# 注意：如果从当前tick开始迭代，应该从池子的总流动性开始
liquidity = 0

# 找到价格范围的边界
min_tick = min(tick_mapping.keys())  # 最小tick（最低价格）
max_tick = max(tick_mapping.keys())  # 最大tick（最高价格）

# 计算当前tick所在的范围底部
# 这段代码在Python中也可以写成: `current_tick // tick_spacing * tick_spacing`
# 但是，使用floor()更具可移植性
current_range_bottom_tick = math.floor(current_tick / tick_spacing) * tick_spacing

# 计算当前价格
current_price = tick_to_price(current_tick)
# 调整价格以考虑代币的小数位数差异
adjusted_current_price = current_price / (10 ** (decimals1 - decimals0))

# 累计池中的所有代币数量
total_amount0 = 0
total_amount1 = 0


# 猜测显示价格的首选方式：
# 尝试以美元计价显示大多数资产
# 如果失败，尝试使用调整小数位后大于1.0的价格值
stablecoins = ["USDC", "DAI", "USDT", "TUSD", "LUSD", "BUSD", "GUSD", "UST"]
if token0 in stablecoins and token1 not in stablecoins:
    # 如果token0是稳定币而token1不是，则反转价格显示
    invert_price = True
elif adjusted_current_price < 1.0:
    # 如果调整后的价格小于1，反转价格以便更易读
    invert_price = True
else:
    invert_price = False

# 从最底部的tick开始遍历tick映射
tick = min_tick
while tick <= max_tick:
    # 获取该tick的流动性净变化
    liquidity_delta = tick_mapping.get(tick, 0)
    liquidity += liquidity_delta  # 累加流动性

    # 计算该tick对应的价格
    price = tick_to_price(tick)
    adjusted_price = price / (10 ** (decimals1 - decimals0))
    
    # 根据需要反转价格显示
    if invert_price:
        adjusted_price = 1 / adjusted_price
        tokens = "{} for {}".format(token0, token1)
    else:
        tokens = "{} for {}".format(token1, token0)

    # 只打印有流动性的tick
    should_print_tick = liquidity != 0
    if should_print_tick:
        print("ticks=[{}, {}], bottom tick price={:.6f} {}".format(tick, tick + tick_spacing, adjusted_price, tokens))

    # 计算对应于底部和顶部tick的价格平方根
    bottom_tick = tick
    top_tick = bottom_tick + tick_spacing
    sa = tick_to_price(bottom_tick // 2)  # 底部tick的价格平方根
    sb = tick_to_price(top_tick // 2)     # 顶部tick的价格平方根

    if tick < current_range_bottom_tick:
        # 当前价格高于此范围，只有token1被锁定
        # 计算该范围内可能存在的代币数量
        amount1 = liquidity * (sb - sa)
        amount0 = amount1 / (sb * sa)

        # 仅token1被锁定
        total_amount1 += amount1

        if should_print_tick:
            adjusted_amount0 = amount0 / (10 ** decimals0)
            adjusted_amount1 = amount1 / (10 ** decimals1)
            print("        {:.2f} {} locked, potentially worth {:.2f} {}".format(adjusted_amount1, token1, adjusted_amount0, token0))

    elif tick == current_range_bottom_tick:
        # 当前tick范围：通常两种资产都存在
        # 总是打印当前tick的信息
        print("        Current tick, both assets present!")
        print("        Current price={:.6f} {}".format(1 / adjusted_current_price if invert_price else adjusted_current_price, tokens))

        # 打印需要交换以移出当前tick范围的两种资产的实际数量
        current_sqrt_price = tick_to_price(current_tick / 2)
        amount0actual = liquidity * (sb - current_sqrt_price) / (current_sqrt_price * sb)
        amount1actual = liquidity * (current_sqrt_price - sa)
        adjusted_amount0actual = amount0actual / (10 ** decimals0)
        adjusted_amount1actual = amount1actual / (10 ** decimals1)

        total_amount0 += amount0actual
        total_amount1 += amount1actual

        print("        {:.2f} {} and {:.2f} {} remaining in the current tick range".format(
            adjusted_amount0actual, token0, adjusted_amount1actual, token1))


    else:
        # 当前价格低于此范围，只有token0被锁定
        # 计算该范围内可能存在的代币数量
        amount1 = liquidity * (sb - sa)
        amount0 = amount1 / (sb * sa)

        # 仅token0被锁定
        total_amount0 += amount0

        if should_print_tick:
            adjusted_amount0 = amount0 / (10 ** decimals0)
            adjusted_amount1 = amount1 / (10 ** decimals1)
            print("        {:.2f} {} locked, potentially worth {:.2f} {}".format(adjusted_amount0, token0, adjusted_amount1, token1))

    # 移动到下一个tick
    tick += tick_spacing

# 打印池中锁定的代币总量
print("In total: {:.2f} {} and {:.2f} {}".format(
      total_amount0 / 10 ** decimals0, token0, total_amount1 / 10 ** decimals1, token1))
