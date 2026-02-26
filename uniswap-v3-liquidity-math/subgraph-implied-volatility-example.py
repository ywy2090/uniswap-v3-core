#!/usr/bin/env python3

"""
Uniswap v3 隐含波动率计算示例

该脚本展示了如何使用Uniswap v3 subgraph数据，
计算主网上USDC/ETH 0.3%费率池的隐含波动率(Implied Volatility, IV)。

隐含波动率原理：
- IV反映了市场对未来价格波动的预期
- 通过交易量、流动性和手续费率可以估算IV
- 公式：IV = 2 * fee * √(volume/liquidity) * √365

功能：
- 查询池子的历史交易数据
- 计算每日的隐含波动率
- 显示多日的IV趋势
"""

from gql import gql, Client
from gql.transport.requests import RequestsHTTPTransport
import math
import sys
from datetime import datetime

# 默认池子ID是0.3%费率的USDC/ETH池
POOL_ID = "0x8ad599c3a0ff1de082011efddc58f1908eb6e6d8"

# 如果在命令行中传递了参数，使用替代的池子ID
if len(sys.argv) > 1:
    POOL_ID = sys.argv[1]

# 查询的天数
NUM_DAYS = 5

# Uniswap v3 subgraph的URL
URL = 'https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3'

# GraphQL查询：获取池子信息和历史数据
pool_query = """query get_pools($pool_id: ID!, $num_days: Int) {
  pools(where: {id: $pool_id}) {
    tick
    liquidity
    feeTier
    poolDayData (first: $num_days, orderBy: date, orderDirection: desc) {
      volumeUSD
      date
    }
  }
}"""

def tick_to_price(tick):
    """
    将tick索引转换为价格
    
    参数:
        tick: tick索引
    
    返回:
        价格
    """
    return 1.0001 ** tick

def fee_tier_to_tick_spacing(fee_tier):
    """
    根据池子的费率等级确定tick间距
    
    参数:
        fee_tier: 费率等级（以万分之一为单位）
    
    返回:
        tick间距
    """
    return {
        100: 1,      # 0.01%
        500: 10,     # 0.05%
        3000: 60,    # 0.3%
        10000: 200   # 1%
    }.get(fee_tier, 60)

# 创建GraphQL客户端
client = Client(
    transport=RequestsHTTPTransport(
        url=URL,
        verify=True,
        retries=5,
    ))

# 获取池子信息和历史数据
try:
    # 多查询一天，因为最新的一天可能还没结束
    variables = {"pool_id": POOL_ID, "num_days": NUM_DAYS + 1}
    response = client.execute(gql(pool_query), variable_values=variables)

    if len(response['pools']) == 0:
        print("pool not found")
        exit(-1)

    pool = response['pools'][0]
    liquidity = int(pool["liquidity"])     # 当前流动性
    current_tick = int(pool["tick"])       # 当前tick
    fee_tier = int(pool["feeTier"])        # 费率等级
    tick_spacing = fee_tier_to_tick_spacing(fee_tier)
    
    # 跳过最新的一天：因为完整的一天还没有过去
    volumes = pool["poolDayData"][1:]

except Exception as ex:
    print("got exception while querying pool data:", ex)
    exit(-1)


# 计算当前tick范围的边界
bottom_tick = current_tick // tick_spacing * tick_spacing
top_tick = bottom_tick + tick_spacing

# 计算价格平方根
sa = tick_to_price(bottom_tick // 2)  # 底部tick的√P
sb = tick_to_price(top_tick // 2)     # 顶部tick的√P

# 假设所有头寸都是USDC形式，计算锁定的USDC数量
# 使用公式：amount = L * (√P_b - √P_a) / (√P_a * √P_b)
usd_amount_locked = liquidity * (sb - sa) / (sa * sb)

# 转换时考虑USDC的小数位数（6位）
usd_amount_locked *= 1e-6

print(f"{usd_amount_locked:.0f} USDC locked")

# 将费率从基点(bps)转换为单位值
# 例如：3000 bps = 0.3% = 0.003
fee = fee_tier / (100 * 100)

# 计算每日的隐含波动率
# 隐含波动率公式：IV = 2 * fee * √(volume/liquidity) * √365
#
# 原理：
# - 高交易量/低流动性 → 高波动率
# - 费率反映了流动性提供者对风险的补偿要求
# - √365 将日波动率年化
# - 系数2来自期权定价理论
for day_data in volumes[::-1]:  # 反转顺序，从旧到新显示
    volume_usd = float(day_data["volumeUSD"])  # 当日交易量(USD)
    
    # 计算隐含波动率
    iv = 2 * fee * math.sqrt(volume_usd / usd_amount_locked) * math.sqrt(365)
    
    # 转换时间戳为可读日期
    dt = datetime.fromtimestamp(int(day_data["date"]))
    day = dt.strftime("%b %d, %Y")
    
    # 打印结果（IV以百分比形式显示）
    print(f"{day}: USDC volume={volume_usd:.0f} IV={iv:.2f}%")
