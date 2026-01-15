// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

/// @title 防止委托调用（Delegatecall）的基础合约
/// @notice 提供一个修饰符来阻止通过 delegatecall 调用子合约的方法
/// @dev 这是一个重要的安全机制，防止恶意合约通过 delegatecall 操纵池的状态
abstract contract NoDelegateCall {
    /// @dev 合约的原始部署地址（不可变）
    /// @notice 在构造函数中记录部署时的地址，用于运行时验证
    address private immutable original;

    constructor() {
        // 不可变变量在合约初始化代码中计算，然后内联到已部署的字节码中
        // 换句话说，这个变量在运行时检查时不会改变
        // 记录合约部署时的地址作为"原始地址"
        original = address(this);
    }

    /// @dev 检查当前执行上下文是否为委托调用
    /// @notice 私有方法，而不是直接内联到修饰符中，因为修饰符会被复制到每个使用它的方法中
    ///         使用不可变变量意味着地址字节会在修饰符使用的每个地方被复制
    ///         使用私有方法可以减少合约大小
    function checkNotDelegateCall() private view {
        // 如果是通过 delegatecall 调用的，address(this) 会是调用者的地址
        // 而不是原始部署地址，因此这个检查会失败
        // 原理：delegatecall 在调用者的上下文中执行代码，address(this) 指向调用者
        require(address(this) == original);
    }

    /// @notice 防止通过 delegatecall 调用被修饰的方法
    /// @dev 添加此修饰符的函数不能通过 delegatecall 调用
    /// 用途：保护关键函数（如 swap、mint 等）防止在错误的上下文中执行
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}
