#!/usr/bin/env python3
"""
Uniswap v3 流动性数学计算模块

本模块实现了Uniswap v3中流动性相关的数学计算。
详细信息请参考技术文档 "Liquidity Math in Uniswap v3" 和 Uniswap v3 白皮书。

主要功能：
- 根据代币数量和价格范围计算流动性
- 根据流动性和价格计算代币数量
- 计算价格边界
"""

#
# 流动性数学函数改编自:
# https://github.com/Uniswap/uniswap-v3-periphery/blob/main/contracts/libraries/LiquidityAmounts.sol
#

def get_liquidity_0(x, sa, sb):
    """
    仅使用token0计算流动性（当价格低于范围时）
    
    参数:
        x: token0的数量
        sa: 价格下限的平方根 (√P_a)
        sb: 价格上限的平方根 (√P_b)
    
    返回:
        流动性 L
    
    公式: L = x * √P_a * √P_b / (√P_b - √P_a)
    """
    return x * sa * sb / (sb - sa)

def get_liquidity_1(y, sa, sb):
    """
    仅使用token1计算流动性（当价格高于范围时）
    
    参数:
        y: token1的数量
        sa: 价格下限的平方根 (√P_a)
        sb: 价格上限的平方根 (√P_b)
    
    返回:
        流动性 L
    
    公式: L = y / (√P_b - √P_a)
    """
    return y / (sb - sa)

def get_liquidity(x, y, sp, sa, sb):
    """
    根据两种代币的数量和价格范围计算流动性
    
    参数:
        x: token0的数量
        y: token1的数量
        sp: 当前价格的平方根 (√P)
        sa: 价格下限的平方根 (√P_a)
        sb: 价格上限的平方根 (√P_b)
    
    返回:
        流动性 L
    
    根据当前价格位置的不同情况计算流动性：
    - 如果价格低于范围：仅使用token0
    - 如果价格在范围内：同时使用token0和token1，取较小值
    - 如果价格高于范围：仅使用token1
    """
    if sp <= sa:
        # 当前价格低于或等于价格下限，仅使用token0
        liquidity = get_liquidity_0(x, sa, sb)
    elif sp < sb:
        # 当前价格在范围内，两种代币都会被使用
        liquidity0 = get_liquidity_0(x, sp, sb)
        liquidity1 = get_liquidity_1(y, sa, sp)
        # 取两者中的较小值，确保两种代币都足够
        liquidity = min(liquidity0, liquidity1)
    else:
        # 当前价格高于或等于价格上限，仅使用token1
        liquidity = get_liquidity_1(y, sa, sb)
    return liquidity


#
# 根据流动性和价格范围计算代币数量
#
def calculate_x(L, sp, sa, sb):
    """
    根据流动性计算token0的数量
    
    参数:
        L: 流动性
        sp: 当前价格的平方根 (√P)
        sa: 价格下限的平方根 (√P_a)
        sb: 价格上限的平方根 (√P_b)
    
    返回:
        token0的数量 x
    
    公式: x = L * (√P_b - √P) / (√P * √P_b)
    
    注意：如果价格超出范围，会使用范围边界值
    """
    sp = max(min(sp, sb), sa)     # 如果价格在范围外，使用范围端点值
    return L * (sb - sp) / (sp * sb)

def calculate_y(L, sp, sa, sb):
    """
    根据流动性计算token1的数量
    
    参数:
        L: 流动性
        sp: 当前价格的平方根 (√P)
        sa: 价格下限的平方根 (√P_a)
        sb: 价格上限的平方根 (√P_b)
    
    返回:
        token1的数量 y
    
    公式: y = L * (√P - √P_a)
    
    注意：如果价格超出范围，会使用范围边界值
    """
    sp = max(min(sp, sb), sa)     # 如果价格在范围外，使用范围端点值
    return L * (sp - sa)


#
# 计算价格下限的两种不同方法
# calculate_a1() 使用流动性作为输入，calculate_a2() 不需要流动性
#
def calculate_a1(L, sp, sb, x, y):
    """
    方法1：使用流动性计算价格下限 P_a
    
    参数:
        L: 流动性
        sp: 当前价格的平方根 (√P)
        sb: 价格上限的平方根 (√P_b)
        x: token0的数量
        y: token1的数量
    
    返回:
        价格下限 P_a
    
    推导过程（Wolfram Alpha）:
    求解 L = y / (√P - √a) 得到 a
    结果: √a = √P - y / L
    """
    # https://www.wolframalpha.com/input/?i=solve+L+%3D+y+%2F+%28sqrt%28P%29+-+a%29+for+a
    # sqrt(a) = sqrt(P) - y / L
    return (sp - y / L) ** 2

def calculate_a2(sp, sb, x, y):
    """
    方法2：不使用流动性计算价格下限 P_a
    
    参数:
        sp: 当前价格的平方根 (√P)
        sb: 价格上限的平方根 (√P_b)
        x: token0的数量
        y: token1的数量
    
    返回:
        价格下限 P_a
    
    推导过程（Wolfram Alpha）:
    求解 x√P√b/(√b-√P) = y/(√P-√a) 得到 a
    简化后: √a = y/(√b·x) + √P - y/(√P·x)
    """
    # https://www.wolframalpha.com/input/?i=solve+++x+sqrt%28P%29+sqrt%28b%29+%2F+%28sqrt%28b%29++-+sqrt%28P%29%29+%3D+y+%2F+%28sqrt%28P%29+-+a%29%2C+for+a
    # sqrt(a) = (y/sqrt(b) + sqrt(P) x - y/sqrt(P))/x
    #    简化为:
    # sqrt(a) = y/(sqrt(b) x) + sqrt(P) - y/(sqrt(P) x)
    sa = y / (sb * x) + sp - y / (sp * x)
    return sa ** 2

#
# 计算价格上限的两种不同方法
# calculate_b1() 使用流动性作为输入，calculate_b2() 不需要流动性
#
def calculate_b1(L, sp, sa, x, y):
    """
    方法1：使用流动性计算价格上限 P_b
    
    参数:
        L: 流动性
        sp: 当前价格的平方根 (√P)
        sa: 价格下限的平方根 (√P_a)
        x: token0的数量
        y: token1的数量
    
    返回:
        价格上限 P_b
    
    推导过程（Wolfram Alpha）:
    求解 L = x√P√b/(√b-√P) 得到 b
    结果: √b = (L√P) / (L - √P·x)
    """
    # https://www.wolframalpha.com/input/?i=solve+L+%3D+x+sqrt%28P%29+sqrt%28b%29+%2F+%28sqrt%28b%29+-+sqrt%28P%29%29+for+b
    # sqrt(b) = (L sqrt(P)) / (L - sqrt(P) x)
    return ((L * sp) / (L - sp * x)) ** 2

def calculate_b2(sp, sa, x, y):
    """
    方法2：不使用流动性计算价格上限 P_b
    
    参数:
        sp: 当前价格的平方根 (√P)
        sa: 价格下限的平方根 (√P_a)
        x: token0的数量
        y: token1的数量
    
    返回:
        价格上限 P_b
    
    推导过程（Wolfram Alpha）:
    求解 x√P·b/(b-√P) = y/(√P-√a) 得到 b
    结果: √b = (√P·y)/(√a·√P·x - P·x + y)
    """
    # 找到 b 的平方根:
    # https://www.wolframalpha.com/input/?i=solve+++x+sqrt%28P%29+b+%2F+%28b++-+sqrt%28P%29%29+%3D+y+%2F+%28sqrt%28P%29+-+sqrt%28a%29%29%2C+for+b
    # sqrt(b) = (sqrt(P) y)/(sqrt(a) sqrt(P) x - P x + y)
    P = sp ** 2
    return (sp * y / ((sa * sp - P) * x + y)) ** 2

#
# 计算价格比率 c 和 d
# c = √P_b / √P (价格上限与当前价格的比率)
# d = √P_a / √P (价格下限与当前价格的比率)
#
def calculate_c(p, d, x, y):
    """
    根据价格、d值和代币数量计算 c 值
    
    参数:
        p: 当前价格 P
        d: 价格比率 d = √P_a / √P
        x: token0的数量
        y: token1的数量
    
    返回:
        价格比率 c = √P_b / √P
    """
    return y / ((d - 1) * p * x + y)

def calculate_d(p, c, x, y):
    """
    根据价格、c值和代币数量计算 d 值
    
    参数:
        p: 当前价格 P
        c: 价格比率 c = √P_b / √P
        x: token0的数量
        y: token1的数量
    
    返回:
        价格比率 d = √P_a / √P
    """
    return 1 + y * (1 - c) / (c * p * x)


#
# 使用已知的良好数值组合测试上述函数
#
# 预期会有一些误差，原因如下：
#  -- 使用浮点数学是为了简单性，而不是精确计算！
#  -- 为了简单起见，忽略了tick和tick范围
#  -- 测试值来自 Uniswap v3 UI，是近似值
#
def test(x, y, p, a, b):
    """
    测试流动性计算函数的准确性
    
    参数:
        x: token0的数量
        y: token1的数量
        p: 当前价格
        a: 价格下限
        b: 价格上限
    
    该函数会计算流动性，然后使用不同的方法重新计算价格边界，
    并比较计算结果与输入值之间的误差。
    """
    # 计算价格的平方根
    sp = p ** 0.5
    sa = a ** 0.5
    sb = b ** 0.5

    # 计算流动性
    L = get_liquidity(x, y, sp, sa, sb)
    print("L: {:.2f}".format(L))

    # 使用方法1计算价格下限并验证误差
    ia = calculate_a1(L, sp, sb, x, y)
    error = 100.0 * (1 - ia / a)
    print("a: {:.2f} vs {:.2f}, error {:.6f}%".format(a, ia, error))

    # 使用方法2计算价格下限并验证误差
    ia = calculate_a2(sp, sb, x, y)
    error = 100.0 * (1 - ia / a)
    print("a: {:.2f} vs {:.2f}, error {:.6f}%".format(a, ia, error))

    # 使用方法1计算价格上限并验证误差
    ib = calculate_b1(L, sp, sa, x, y)
    error = 100.0 * (1 - ib / b)
    print("b: {:.2f} vs {:.2f}, error {:.6f}%".format(b, ib, error))

    # 使用方法2计算价格上限并验证误差
    ib = calculate_b2(sp, sa, x, y)
    error = 100.0 * (1 - ib / b)
    print("b: {:.2f} vs {:.2f}, error {:.6f}%".format(b, ib, error))

    # 计算价格比率
    c = sb / sp  # c = √P_b / √P
    d = sa / sp  # d = √P_a / √P
    
    # 验证 c 值的计算
    ic = calculate_c(p, d, x, y)
    error = 100.0 * (1 - ic / c)
    print("c^2: {:.2f} vs {:.2f}, error {:.6f}%".format(c**2, ic**2, error))

    # 验证 d 值的计算
    id = calculate_d(p, c, x, y)
    error = 100.0 * (1 - id**2 / d**2)
    print("d^2: {:.2f} vs {:.2f}, error {:.6f}%".format(d**2, id**2, error))

    # 使用流动性重新计算代币数量并验证误差
    ix = calculate_x(L, sp, sa, sb)
    error = 100.0 * (1 - ix / x)
    print("x: {:.2f} vs {:.2f}, error {:.6f}%".format(x, ix, error))

    iy = calculate_y(L, sp, sa, sb)
    error = 100.0 * (1 - iy / y)
    print("y: {:.2f} vs {:.2f}, error {:.6f}%".format(y, iy, error))
    print("")


def test_1():
    """测试案例1：使用简单的数值"""
    print("test case 1")
    p = 20.0      # 当前价格
    a = 19.027    # 价格下限
    b = 25.993    # 价格上限
    x = 1         # token0数量
    y = 4         # token1数量
    test(x, y, p, a, b)

def test_2():
    """测试案例2：使用来自Uniswap v3 UI的真实数值"""
    print("test case 2")
    p = 3227.02   # 当前价格
    a = 1626.3    # 价格下限
    b = 4846.3    # 价格上限
    x = 1         # token0数量
    y = 5096.06   # token1数量
    test(x, y, p, a, b)

def tests():
    """运行所有测试案例"""
    test_1()
    test_2()

#
# 示例1：来自技术文档
#
def example_1():
    """
    示例1：当提供2个ETH时，在给定的价格和范围下需要多少USDC？
    
    场景：
    - 当前价格: 1 ETH = 2000 USDC
    - 价格范围: 1500-2500 USDC
    - 提供的ETH数量: 2 ETH
    
    目标：计算需要提供的USDC数量
    """
    print("Example 1: how much of USDC I need when providing 2 ETH at this price and range?")
    p = 2000  # 当前价格：2000 USDC/ETH
    a = 1500  # 价格下限：1500 USDC/ETH
    b = 2500  # 价格上限：2500 USDC/ETH
    x = 2     # 提供2个ETH (token0)

    # 计算价格的平方根
    sp = p ** 0.5
    sa = a ** 0.5
    sb = b ** 0.5
    
    # 首先使用token0计算流动性
    L = get_liquidity_0(x, sp, sb)
    # 然后根据流动性计算需要的token1（USDC）数量
    y = calculate_y(L, sp, sa, sb)
    print("amount of USDC y={:.2f}".format(y))

    # 验证使用计算得到的y值，给定的价格范围是否正确
    c = sb / sp  # 价格上限比率
    d = sa / sp  # 价格下限比率
    ic = calculate_c(p, d, x, y)
    id = calculate_d(p, c, x, y)
    C = ic ** 2  # 转换回价格比率
    D = id ** 2  # 转换回价格比率
    print("p_a={:.2f} ({:.2f}% of P), p_b={:.2f} ({:.2f}% of P)".format(
        D * p, D * 100, C * p, C * 100))
    print("")

#
# 示例2：来自技术文档
#
def example_2():
    """
    示例2：我有2个ETH和4000 USDC，价格上限设为3000 USDC。价格下限是多少？
    
    场景：
    - 当前价格: 1 ETH = 2000 USDC
    - 价格上限: 3000 USDC/ETH
    - 可用资产: 2 ETH 和 4000 USDC
    
    目标：计算价格下限
    """
    print("Example 2: I have 2 ETH and 4000 USDC, range top set to 3000 USDC. What's the bottom of the range?")
    p = 2000   # 当前价格：2000 USDC/ETH
    b = 3000   # 价格上限：3000 USDC/ETH
    x = 2      # 2个ETH
    y = 4000   # 4000 USDC

    # 计算价格的平方根
    sp = p ** 0.5
    sb = b ** 0.5

    # 使用方法2计算价格下限（不需要流动性）
    a = calculate_a2(sp, sb, x, y)
    print("lower bound of the price p_a={:.2f}".format(a))
    print("")


#
# 示例3：来自技术文档
#
def example_3():
    """
    示例3：使用示例2中创建的头寸，当价格变为2500 USDC/ETH时，资产余额是多少？
    
    场景：
    - 初始价格: 1 ETH = 2000 USDC
    - 价格范围: 1333.33-3000 USDC/ETH
    - 初始资产: 2 ETH 和 4000 USDC
    - 新价格: 2500 USDC/ETH
    
    目标：计算新价格下的资产余额
    """
    print("Example 3: Using the position created in Example 2, what are asset balances at 2500 USDC per ETH?")
    p = 2000     # 初始价格
    a = 1333.33  # 价格下限（来自示例2的计算结果）
    b = 3000     # 价格上限
    x = 2        # 初始ETH数量
    y = 4000     # 初始USDC数量

    # 计算初始价格的平方根
    sp = p ** 0.5
    sa = a ** 0.5
    sb = b ** 0.5
    
    # 计算初始流动性
    L = get_liquidity(x, y, sp, sa, sb)

    # 新的价格
    P1 = 2500
    sp1 = P1 ** 0.5

    # 方法1：直接使用流动性公式计算新价格下的资产数量
    x1 = calculate_x(L, sp1, sa, sb)
    y1 = calculate_y(L, sp1, sa, sb)
    print("Amount of ETH x={:.2f} amount of USDC y={:.2f}".format(x1, y1))

    # 方法2：使用白皮书中的增量计算方法

    # 增量数学仅在价格在范围内（包括端点）时有效，
    # 因此首先将价格的平方根限制在范围内
    sp = max(min(sp, sb), sa)
    sp1 = max(min(sp1, sb), sa)

    # 计算价格变化
    delta_p = sp1 - sp           # 价格平方根的变化
    delta_inv_p = 1/sp1 - 1/sp   # 价格平方根倒数的变化
    
    # 根据流动性和价格变化计算资产变化
    delta_x = delta_inv_p * L    # ETH数量的变化
    delta_y = delta_p * L        # USDC数量的变化
    
    # 计算新的资产余额
    x1 = x + delta_x
    y1 = y + delta_y
    print("delta_x={:.2f} delta_y={:.2f}".format(delta_x, delta_y))
    print("Amount of ETH x={:.2f} amount of USDC y={:.2f}".format(x1, y1))


def examples():
    """运行所有示例"""
    example_1()
    example_2()
    example_3()

def main():
    """主函数：运行测试和示例"""
    # 使用从Uniswap UI获取的一些值进行测试
    tests()
    # 演示技术文档中给出的示例
    examples()

if __name__ == "__main__":
    main()
