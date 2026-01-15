// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title UnsafeMath - 不安全的数学函数库
/// @notice 包含不检查输入或输出的常用数学函数
/// @dev 这些函数不进行溢出或下溢检查，调用者必须确保安全性
/// 
/// ⚠️ 警告：
/// 使用这个库需要非常小心！函数不会检查：
/// - 除数为 0
/// - 溢出
/// - 下溢
/// 
/// 为什么使用"不安全"的数学？
/// 1. Gas 优化：省略检查可以节省大量 gas
/// 2. 在某些场景下，溢出是可接受的或已被外部逻辑处理
/// 3. Solidity 0.8.0 之前没有内置溢出检查，这个库用于兼容
/// 
/// 使用场景：
/// - 调用者已经验证了参数的安全性
/// - 在紧凑的 gas 预算下
/// - 需要特定的溢出行为（如循环计数器）
library UnsafeMath {
    /// @notice 返回 ceil(x / y)（向上取整的除法）
    /// @dev 除以 0 的行为未定义，必须在外部检查
    /// 
    /// 数学原理：
    /// - ceil(x / y) = floor(x / y) + (x % y > 0 ? 1 : 0)
    /// - 如果有余数，结果加 1
    /// 
    /// 汇编实现（节省 gas）：
    /// - div(x, y)：计算 floor(x / y)
    /// - mod(x, y)：计算 x % y
    /// - gt(mod(x, y), 0)：检查余数是否 > 0，返回 0 或 1
    /// - add(...)：将商和余数标志相加
    /// 
    /// 示例：
    /// - divRoundingUp(7, 3) = 3（7/3 = 2余1，向上取整为 3）
    /// - divRoundingUp(6, 3) = 2（6/3 = 2余0，不需要向上）
    /// - divRoundingUp(0, 5) = 0（0/5 = 0）
    /// 
    /// ⚠️ 注意：
    /// - divRoundingUp(x, 0) 会导致 EVM 错误（除以零）
    /// - 调用前必须确保 y != 0
    /// 
    /// @param x 被除数
    /// @param y 除数（必须 > 0，否则行为未定义）
    /// @return z 商，向上取整 ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            // z = div(x, y) + (mod(x, y) > 0 ? 1 : 0)
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}
