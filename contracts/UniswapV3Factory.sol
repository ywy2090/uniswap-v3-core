// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Factory.sol';

import './UniswapV3PoolDeployer.sol';
import './NoDelegateCall.sol';

import './UniswapV3Pool.sol';

/// @title Uniswap V3 标准工厂合约
/// @notice 负责部署 Uniswap V3 池，并管理池的所有权和协议费用控制
/// @dev 继承了 PoolDeployer（提供部署能力）和 NoDelegateCall（安全保护）
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall {
    /// @inheritdoc IUniswapV3Factory
    /// @notice 工厂合约的所有者地址
    /// @dev 所有者拥有特殊权限：启用新费率、设置协议费用等
    address public override owner;

    /// @inheritdoc IUniswapV3Factory
    /// @notice 费率 => tick 间距的映射
    /// @dev 存储每个费率等级对应的 tick 间距
    /// 例如：feeAmountTickSpacing[500] = 10 表示 0.05% 费率对应 10 个 tick 的间距
    /// tick 间距越小，价格粒度越细，但 gas 成本越高
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    
    /// @inheritdoc IUniswapV3Factory
    /// @notice 三维映射：(token0 => (token1 => (fee => pool)))
    /// @dev 根据代币对和费率查找池地址
    /// 注意：token0 和 token1 可以反向查询（双向映射）
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    /// @notice 部署工厂合约并初始化默认费率等级
    /// @dev 构造函数中启用三个标准费率：0.05%、0.30%、1.00%
    constructor() {
        // 设置部署者为初始所有者
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        // 初始化标准费率等级
        // 费率 0.05% (500) => tick间距 10
        // 适用于稳定币对（如 USDC/USDT），价格波动小，需要细粒度
        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        
        // 费率 0.30% (3000) => tick间距 60
        // 适用于主流代币对（如 ETH/USDC），最常用的费率
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        
        // 费率 1.00% (10000) => tick间距 200
        // 适用于高波动性/山寨币对，风险补偿更高
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 创建一个新的交易池
    /// @dev 使用 noDelegateCall 防止通过委托调用创建池
    /// 
    /// 创建流程：
    /// 1. 验证代币地址有效性
    /// 2. 对代币地址排序（确保 token0 < token1）
    /// 3. 检查费率是否已启用
    /// 4. 确保池不存在
    /// 5. 使用 CREATE2 部署池（确定性地址）
    /// 6. 双向记录池地址映射
    /// 
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址  
    /// @param fee 交易费率（以百万分之一为单位）
    /// @return pool 新创建的池的地址
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        // 验证：两个代币地址必须不同
        require(tokenA != tokenB);
        
        // 对代币地址排序，确保 token0 < token1
        // 这样保证相同的代币对只有一个顺序，避免重复池
        // 例如：USDC/ETH 和 ETH/USDC 会被标准化为同一个池
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        // 验证：token0 不能是零地址（排序后 token1 自动也不是零地址）
        require(token0 != address(0));
        
        // 查找该费率对应的 tick 间距
        int24 tickSpacing = feeAmountTickSpacing[fee];
        
        // 验证：fee 必须是已启用的费率（tickSpacing != 0 表示已启用）
        require(tickSpacing != 0);
        
        // 验证：该代币对和费率的池必须不存在
        require(getPool[token0][token1][fee] == address(0));
        
        // 使用 CREATE2 部署池合约
        // CREATE2 保证相同参数产生相同地址（确定性）
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        
        // 双向存储池地址映射
        // 正向：token0 => token1 => fee => pool
        getPool[token0][token1][fee] = pool;
        
        // 反向：token1 => token0 => fee => pool（指向同一个池）
        // 这是一个刻意的设计选择，避免了比较地址的成本
        // 用户可以用任意顺序查询代币对
        getPool[token1][token0][fee] = pool;
        
        // 触发池创建事件
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 转移工厂合约的所有权
    /// @dev 只有当前所有者可以调用
    /// @param _owner 新所有者的地址
    function setOwner(address _owner) external override {
        // 验证：只有当前所有者可以转移所有权
        require(msg.sender == owner);
        
        // 触发所有权变更事件
        emit OwnerChanged(owner, _owner);
        
        // 更新所有者地址
        owner = _owner;
    }

    /// @inheritdoc IUniswapV3Factory
    /// @notice 启用一个新的费率等级
    /// @dev 只有所有者可以调用
    /// 
    /// 参数约束：
    /// - fee < 100% (1000000)
    /// - 0 < tickSpacing < 16384
    /// - 该费率尚未启用
    /// 
    /// @param fee 要启用的费率（以百万分之一为单位）
    /// @param tickSpacing 该费率对应的 tick 间距
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        // 验证：只有所有者可以启用新费率
        require(msg.sender == owner);
        
        // 验证：费率必须小于 100%（1000000 = 100%）
        require(fee < 1000000);
        
        // tick 间距上限为 16384，防止以下情况：
        // - tickSpacing 太大会导致 TickBitmap#nextInitializedTickWithinOneWord 
        //   从有效的 tick 溢出 int24 容器
        // - 16384 个 tick 代表价格变化超过 5 倍（每个 tick 是 1 bip = 0.01%）
        // 计算：1.0001^16384 ≈ 5.05
        require(tickSpacing > 0 && tickSpacing < 16384);
        
        // 验证：该费率必须尚未启用（防止覆盖现有配置）
        require(feeAmountTickSpacing[fee] == 0);

        // 存储费率和 tick 间距的映射
        feeAmountTickSpacing[fee] = tickSpacing;
        
        // 触发费率启用事件
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
