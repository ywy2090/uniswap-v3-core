// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title LiquidityMath - 流动性数学库
/// @notice 用于流动性计算的安全数学函数
/// @dev 处理有符号的流动性变化，防止溢出和下溢
library LiquidityMath {
    /// @notice 将有符号的流动性变化量添加到流动性上，如果溢出或下溢则回滚
    /// @dev 这是一个安全的加减法，支持正负增量
    /// 
    /// 功能说明：
    /// - 支持添加流动性（y > 0）
    /// - 支持移除流动性（y < 0）
    /// - 自动检测溢出和下溢
    /// 
    /// 使用场景：
    /// 1. mint() 时：增加流动性（y > 0）
    /// 2. burn() 时：减少流动性（y < 0）
    /// 3. 跨越 tick 时：根据 liquidityNet 调整活跃流动性
    /// 
    /// 安全检查：
    /// - 减法：确保结果 < 原值（防止下溢）
    /// - 加法：确保结果 >= 原值（防止溢出）
    /// 
    /// 示例：
    /// - addDelta(1000, 500) = 1500（添加 500）
    /// - addDelta(1000, -300) = 700（移除 300）
    /// - addDelta(100, -200) = revert 'LS'（下溢）
    /// - addDelta(2^128-1, 1) = revert 'LA'（溢出）
    /// 
    /// @param x 变化前的流动性
    /// @param y 流动性变化量（正数=增加，负数=减少）
    /// @return z 变化后的流动性
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            // 减少流动性的情况
            // 转换：-y 变成正数，然后从 x 中减去
            require((z = x - uint128(-y)) < x, 'LS');
            // 检查：z < x 确保没有下溢
            // 'LS' = Liquidity Sub（流动性减法失败）
        } else {
            // 增加流动性的情况
            require((z = x + uint128(y)) >= x, 'LA');
            // 检查：z >= x 确保没有溢出
            // 'LA' = Liquidity Add（流动性加法失败）
        }
    }
}
