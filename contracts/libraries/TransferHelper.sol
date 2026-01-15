// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.0;

import '../interfaces/IERC20Minimal.sol';

/// @title TransferHelper - 代币转账辅助库
/// @notice 包含与不一致返回 true/false 的 ERC20 代币交互的辅助方法
/// @dev 解决某些 ERC20 代币不遵守标准的问题
/// 
/// 问题背景：
/// ERC20 标准规定 transfer 和 transferFrom 应该返回 bool：
/// - true = 成功
/// - false = 失败
/// 
/// 但现实中存在三种代币：
/// 1. 标准代币：返回 true/false
/// 2. 不返回值的代币：如 USDT（只会 revert，不返回 bool）
/// 3. 总是返回 true 的代币（即使失败也返回 true）
/// 
/// 这个库的解决方案：
/// - 使用低级 call 而非直接调用
/// - 检查 call 是否成功
/// - 兼容有返回值和无返回值的代币
/// - 如果有返回值，检查是否为 true
library TransferHelper {
    /// @notice 从 msg.sender 转账代币到接收者
    /// @dev 调用代币合约的 transfer，如果转账失败则用 'TF' 报错
    /// 
    /// 工作流程：
    /// 1. 使用 call 调用 token.transfer(to, value)
    /// 2. 检查 call 是否成功（success == true）
    /// 3. 检查返回数据：
    ///    - data.length == 0：代币没有返回值（如 USDT），认为成功
    ///    - data.length > 0：解码 bool，必须为 true
    /// 4. 如果任何检查失败，revert 'TF'
    /// 
    /// 为什么使用 call？
    /// - 直接调用会要求返回值类型匹配
    /// - call 可以处理任何返回值（或无返回值）
    /// 
    /// 安全性：
    /// - 检查 success 防止静默失败
    /// - 检查返回值防止恶意代币返回 false
    /// - 兼容标准和非标准代币
    /// 
    /// 错误代码：
    /// - 'TF' = Transfer Failed（转账失败）
    /// 
    /// 示例场景：
    /// 1. 标准代币（返回 true）：
    ///    call 成功 → data 解码为 true → 通过 ✓
    /// 
    /// 2. USDT（无返回值）：
    ///    call 成功 → data.length == 0 → 通过 ✓
    /// 
    /// 3. 余额不足：
    ///    call 失败（revert）→ success == false → revert 'TF' ✗
    /// 
    /// 4. 恶意代币（返回 false）：
    ///    call 成功 → data 解码为 false → revert 'TF' ✗
    /// 
    /// @param token 要转账的代币合约地址
    /// @param to 接收者地址
    /// @param value 转账数量
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        // 使用低级 call 调用 transfer(address,uint256)
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, value));
        
        // 验证：
        // 1. call 必须成功（success == true）
        // 2. 返回数据为空（无返回值代币）或解码为 true（标准代币）
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TF');
    }
}
