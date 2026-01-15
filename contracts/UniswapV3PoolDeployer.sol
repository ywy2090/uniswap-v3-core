// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

/// @title Uniswap V3 池部署器
/// @notice 负责使用 CREATE2 操作码部署 Uniswap V3 池合约
/// @dev 使用临时存储参数的模式，在部署过程中传递参数到池合约的构造函数
contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    /// @notice 池部署参数的结构体
    /// @dev 这些参数在部署期间临时存储，池合约构造函数会读取它们
    struct Parameters {
        address factory;      // 工厂合约地址
        address token0;       // 第一个代币（地址较小的）
        address token1;       // 第二个代币（地址较大的）
        uint24 fee;          // 交易费率（以百万分之一为单位，如 3000 = 0.3%）
        int24 tickSpacing;   // tick 间距
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    /// @notice 公开的参数存储，池合约在构造时读取
    /// @dev 这是一个临时存储，仅在部署过程中使用
    Parameters public override parameters;

    /// @dev 使用给定参数部署池合约
    /// @notice 通过临时设置 parameters 存储槽，然后在部署池后清除它
    /// 
    /// 工作原理：
    /// 1. 将参数存储到 parameters 变量
    /// 2. 使用 CREATE2 部署池合约（确定性地址）
    /// 3. 池合约的构造函数读取 parameters
    /// 4. 删除 parameters 清理存储
    /// 
    /// @param factory Uniswap V3 工厂合约地址
    /// @param token0 池中第一个代币（按地址排序）
    /// @param token1 池中第二个代币（按地址排序）
    /// @param fee 每次交易收取的费用，以万分之一 bip 为单位（1 bip = 0.01%）
    ///            例如：500 = 0.05%, 3000 = 0.30%, 10000 = 1.00%
    /// @param tickSpacing 可用 tick 之间的间距
    /// @return pool 已部署池合约的地址
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 步骤 1: 将参数存储到公开的 parameters 变量中
        // 池合约的构造函数将通过 IUniswapV3PoolDeployer(msg.sender).parameters() 读取这些参数
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        
        // 步骤 2: 使用 CREATE2 部署池合约
        // CREATE2 的优势：
        // - 地址是确定性的，可以在链下预先计算
        // - salt 使用 token0、token1 和 fee 的哈希，确保相同参数产生相同地址
        // - 防止重复部署相同配置的池
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        
        // 步骤 3: 清除临时参数存储
        // 节省 gas（SSTORE 从非零到零会退还 gas）
        // 也防止参数被后续调用意外读取
        delete parameters;
    }
}
