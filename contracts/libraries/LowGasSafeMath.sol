// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0;

/// @title LowGasSafeMath - 低 Gas 安全数学库
/// @notice 包含进行安全数学运算的方法，溢出或下溢时回滚，同时优化 gas 消耗
/// @dev 针对 Solidity 0.7.x 设计（没有内置溢出检查）
/// 
/// 背景：
/// - Solidity 0.8.0 之前，算术运算不会自动检查溢出
/// - 需要手动添加检查或使用 SafeMath 库
/// - 这个库提供了 gas 优化的安全检查
/// 
/// 与 OpenZeppelin SafeMath 的区别：
/// - 更少的 gas 消耗（优化的检查逻辑）
/// - 专门为 Uniswap V3 的使用场景优化
/// - 更简洁的错误处理（直接 require，没有错误消息）
/// 
/// Solidity 0.8.0+ 注意：
/// 如果升级到 0.8.0+，这个库可以移除，使用内置的溢出检查
library LowGasSafeMath {
    /// @notice 返回 x + y，如果和溢出 uint256 则回滚
    /// @dev 检查逻辑：z >= x
    ///      如果 z < x，说明发生了溢出（环绕到更小的值）
    /// 
    /// 示例：
    /// - add(100, 50) = 150 ✓
    /// - add(2^256 - 1, 1) = revert（溢出）
    /// - add(2^256 - 10, 5) = 2^256 - 5 ✓
    /// 
    /// @param x 被加数
    /// @param y 加数
    /// @return z x 和 y 的和
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    /// @notice 返回 x - y，如果下溢则回滚
    /// @dev 检查逻辑：z <= x
    ///      如果 z > x，说明发生了下溢（环绕到更大的值）
    /// 
    /// 示例：
    /// - sub(100, 50) = 50 ✓
    /// - sub(50, 100) = revert（下溢）
    /// - sub(0, 1) = revert（下溢）
    /// 
    /// @param x 被减数
    /// @param y 减数
    /// @return z x 和 y 的差
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    /// @notice 返回 x * y，如果溢出则回滚
    /// @dev 检查逻辑：x == 0 || (z / x == y)
    ///      - 如果 x = 0，任何数乘 0 都是 0，安全
    ///      - 否则，验证 z / x == y（反向检查）
    ///      - 如果 z / x != y，说明发生了溢出
    /// 
    /// 为什么这样检查？
    /// 如果 x * y 溢出，那么 (x * y) / x 不会等于 y
    /// 
    /// 示例：
    /// - mul(10, 20) = 200 ✓
    /// - mul(0, 999999) = 0 ✓
    /// - mul(2^128, 2^128) = revert（溢出）
    /// 
    /// @param x 被乘数
    /// @param y 乘数
    /// @return z x 和 y 的积
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(x == 0 || (z = x * y) / x == y);
    }

    /// @notice 返回 x + y（有符号），如果溢出或下溢则回滚
    /// @dev 检查逻辑：(z >= x) == (y >= 0)
    ///      这是一个巧妙的检查：
    ///      - 如果 y >= 0（加正数），那么 z 应该 >= x
    ///      - 如果 y < 0（加负数），那么 z 应该 < x
    ///      - 如果不满足这个关系，说明溢出或下溢了
    /// 
    /// 四种情况：
    /// 1. y >= 0 且 z >= x：正常（加正数，结果更大）✓
    /// 2. y >= 0 且 z < x：溢出（加正数，结果反而变小）✗
    /// 3. y < 0 且 z < x：正常（加负数，结果更小）✓
    /// 4. y < 0 且 z >= x：下溢（加负数，结果反而更大）✗
    /// 
    /// 示例：
    /// - add(100, 50) = 150 ✓
    /// - add(100, -50) = 50 ✓
    /// - add(2^255 - 1, 1) = revert（正数溢出）
    /// - add(-2^255, -1) = revert（负数下溢）
    /// 
    /// @param x 被加数
    /// @param y 加数
    /// @return z x 和 y 的和
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x + y) >= x == (y >= 0));
    }

    /// @notice 返回 x - y（有符号），如果溢出或下溢则回滚
    /// @dev 检查逻辑：(z <= x) == (y >= 0)
    ///      类似加法，但逻辑相反：
    ///      - 如果 y >= 0（减正数），那么 z 应该 <= x
    ///      - 如果 y < 0（减负数），那么 z 应该 > x
    ///      - 如果不满足，说明溢出或下溢了
    /// 
    /// 四种情况：
    /// 1. y >= 0 且 z <= x：正常（减正数，结果更小）✓
    /// 2. y >= 0 且 z > x：下溢（减正数，结果反而更大）✗
    /// 3. y < 0 且 z > x：正常（减负数 = 加正数，结果更大）✓
    /// 4. y < 0 且 z <= x：溢出（减负数，结果反而更小）✗
    /// 
    /// 示例：
    /// - sub(100, 50) = 50 ✓
    /// - sub(100, -50) = 150 ✓（减负数 = 加正数）
    /// - sub(-2^255, 1) = revert（负数下溢）
    /// - sub(2^255 - 1, -2) = revert（正数溢出）
    /// 
    /// @param x 被减数
    /// @param y 减数
    /// @return z x 和 y 的差
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x - y) <= x == (y >= 0));
    }
}
