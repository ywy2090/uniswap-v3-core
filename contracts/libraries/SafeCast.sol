// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title SafeCast - 安全类型转换库
/// @notice 包含在类型之间安全转换的方法
/// @dev 所有转换都会检查溢出，如果不安全则回滚
/// 
/// 为什么需要安全转换？
/// Solidity 的类型转换（如 uint256 → uint160）在溢出时不会报错，
/// 而是直接截断高位，可能导致严重的逻辑错误。
/// 
/// 示例危险转换：
/// uint256 x = 2^200;
/// uint160 y = uint160(x);  // 不安全！高位被截断，y ≠ x
/// 
/// 安全转换：
/// uint160 y = SafeCast.toUint160(x);  // 会回滚，因为 x 太大
library SafeCast {
    /// @notice 将 uint256 安全转换为 uint160，溢出时回滚
    /// @dev uint160 的最大值 = 2^160 - 1 ≈ 1.46 * 10^48
    /// 
    /// 使用场景：
    /// - 将计算结果转换为 sqrtPriceX96（uint160）
    /// - 确保价格在有效范围内
    /// 
    /// 转换逻辑：
    /// 1. 尝试转换：z = uint160(y)
    /// 2. 验证：z == y（如果相等，说明没有数据丢失）
    /// 3. 如果 z != y，说明 y 太大，转换会丢失数据，回滚
    /// 
    /// 示例：
    /// - toUint160(100) = 100 ✓
    /// - toUint160(2^160 - 1) = 2^160 - 1 ✓
    /// - toUint160(2^160) = revert（溢出）
    /// 
    /// @param y 要转换的 uint256
    /// @return z 转换后的 uint160
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y);
    }

    /// @notice 将 int256 安全转换为 int128，溢出或下溢时回滚
    /// @dev int128 的范围：-2^127 到 2^127 - 1
    ///      约 -1.7 * 10^38 到 1.7 * 10^38
    /// 
    /// 使用场景：
    /// - 流动性增量（liquidityDelta）使用 int128
    /// - 限制流动性变化的范围
    /// 
    /// 转换逻辑：
    /// 1. 尝试转换：z = int128(y)
    /// 2. 验证：z == y
    /// 3. 如果 y 超出 int128 范围，转换会改变值，回滚
    /// 
    /// 示例：
    /// - toInt128(1000) = 1000 ✓
    /// - toInt128(-1000) = -1000 ✓
    /// - toInt128(2^127 - 1) = 2^127 - 1 ✓（最大值）
    /// - toInt128(2^127) = revert（溢出）
    /// - toInt128(-2^127) = -2^127 ✓（最小值）
    /// - toInt128(-2^127 - 1) = revert（下溢）
    /// 
    /// @param y 要转换的 int256
    /// @return z 转换后的 int128
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y);
    }

    /// @notice 将 uint256 安全转换为 int256，溢出时回滚
    /// @dev int256 的正数范围：0 到 2^255 - 1
    ///      uint256 的范围：0 到 2^256 - 1
    ///      因此只有当 uint256 < 2^255 时才能安全转换
    /// 
    /// 使用场景：
    /// - 将无符号数量转换为有符号类型进行计算
    /// - amount 转换为 amountSpecified（可正可负）
    /// 
    /// 转换逻辑：
    /// 1. 检查：y < 2^255（确保在 int256 的正数范围内）
    /// 2. 执行转换：z = int256(y)
    /// 
    /// 为什么是 2^255？
    /// - int256 使用最高位作为符号位
    /// - 正数：0 到 2^255 - 1
    /// - 负数：-2^255 到 -1
    /// - 如果 uint256 >= 2^255，转换后会被解释为负数
    /// 
    /// 示例：
    /// - toInt256(100) = 100 ✓
    /// - toInt256(2^255 - 1) = 2^255 - 1 ✓（最大安全值）
    /// - toInt256(2^255) = revert（会变成负数）
    /// - toInt256(2^256 - 1) = revert（最大 uint256，无法表示为正的 int256）
    /// 
    /// @param y 要转换的 uint256
    /// @return z 转换后的 int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2**255);
        z = int256(y);
    }
}
