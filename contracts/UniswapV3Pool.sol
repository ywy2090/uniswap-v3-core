// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

/// @title Uniswap V3 池合约
/// @notice 实现了 Uniswap V3 协议的核心交易池逻辑
/// @dev 包含集中流动性、多级费率、改进的预言机等 V3 核心特性
contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    // ============ 库的使用声明 ============
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    // ============ 不可变状态变量 ============
    
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 创建此池的工厂合约地址
    address public immutable override factory;
    
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 池中第一个代币的地址（按地址排序，较小的）
    address public immutable override token0;
    
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 池中第二个代币的地址（按地址排序，较大的）
    address public immutable override token1;
    
    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 池的交易费率
    /// @dev 以百万分之一为单位，例如 3000 表示 0.30%
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 可用 tick 之间的最小间距
    /// @dev tick 必须是 tickSpacing 的倍数
    /// 不同费率对应不同间距：0.05% => 10, 0.30% => 60, 1.00% => 200
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    /// @notice 单个 tick 允许的最大流动性
    /// @dev 防止单个 tick 的流动性过度集中，避免潜在的溢出问题
    uint128 public immutable override maxLiquidityPerTick;

    // ============ 核心状态变量 ============
    
    /// @notice 池的主要状态，打包在一个存储槽中以节省 gas
    /// @dev 所有变量打包在 256 位（32 字节）内，一次 SLOAD 即可读取全部
    struct Slot0 {
        // 当前价格的平方根（Q64.96 格式）
        // price = (sqrtPriceX96 / 2^96)^2
        // 使用平方根可以更高效地计算代币数量
        uint160 sqrtPriceX96;
        
        // 当前价格对应的 tick
        // tick = log_{1.0001}(price)
        // 每个 tick 代表 0.01% 的价格变化
        int24 tick;
        
        // 观察数组中最近更新的观察记录的索引
        uint16 observationIndex;
        
        // 观察数组当前已使用的容量
        // 初始为 1，可以扩展到 65535
        uint16 observationCardinality;
        
        // 观察数组的下一个容量目标
        // 在 observations.write 中触发扩展
        uint16 observationCardinalityNext;
        
        // 协议费用占交易费用的比例
        // 表示为整数分母 (1/x)%
        // 低 4 位存储 token0 的协议费，高 4 位存储 token1 的协议费
        uint8 feeProtocol;
        
        // 池是否已解锁（用于重入保护）
        // true = 未锁定，false = 已锁定
        bool unlocked;
    }
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 池的主要状态
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice token0 的全局费用增长（每单位流动性）
    /// @dev 使用 Q128 格式存储累积费用
    /// 计算公式：每次交易后 += (feeAmount * 2^128) / liquidity
    uint256 public override feeGrowthGlobal0X128;
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice token1 的全局费用增长（每单位流动性）
    uint256 public override feeGrowthGlobal1X128;

    /// @notice 累积的协议费用
    /// @dev 单独存储两个代币的协议费用
    struct ProtocolFees {
        uint128 token0;  // token0 的协议费用累积
        uint128 token1;  // token1 的协议费用累积
    }
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 协议费用累积
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice 当前价格下的活跃流动性
    /// @dev 只有在当前价格范围内的流动性才是"活跃"的
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice tick => Tick.Info 的映射
    /// @dev 存储每个已初始化的 tick 的信息（流动性、费用增长等）
    mapping(int24 => Tick.Info) public override ticks;
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice tick 位图，用于快速查找已初始化的 tick
    /// @dev 每个 int16 对应 256 个 tick，每一位表示对应的 tick 是否已初始化
    mapping(int16 => uint256) public override tickBitmap;
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 位置（头寸）信息的映射
    /// @dev key = keccak256(abi.encodePacked(owner, tickLower, tickUpper))
    mapping(bytes32 => Position.Info) public override positions;
    
    /// @inheritdoc IUniswapV3PoolState
    /// @notice 预言机观察记录的环形数组
    /// @dev 最多存储 65535 个观察记录，用于计算 TWAP
    Oracle.Observation[65535] public override observations;

    // ============ 修饰符 ============
    
    /// @dev 互斥的重入保护，防止在方法执行期间被重入
    /// @notice 此修饰符还防止在池初始化之前进入函数
    /// 
    /// 重入保护的必要性：
    /// 由于我们使用余额检查来确定 mint、swap 和 flash 等交互的支付状态，
    /// 必须防止重入攻击。例如，恶意合约可能在回调中再次调用池函数。
    modifier lock() {
        // 要求池当前是解锁状态
        // 如果 unlocked = false，说明正在执行中，拒绝重入
        require(slot0.unlocked, 'LOK');
        
        // 设置锁定状态
        slot0.unlocked = false;
        
        // 执行函数体
        _;
        
        // 函数执行完成后解锁
        slot0.unlocked = true;
    }

    /// @dev 只允许工厂所有者调用
    /// @notice 用于需要特殊权限的函数（如设置协议费用）
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    // ============ 构造函数 ============
    
    /// @notice 构造函数
    /// @dev 从部署器（deployer）读取参数并初始化不可变变量
    /// 
    /// 部署流程：
    /// 1. Factory 调用 PoolDeployer.deploy()
    /// 2. Deployer 将参数存储到 parameters 变量
    /// 3. Deployer 使用 CREATE2 创建 Pool
    /// 4. Pool 构造函数从 Deployer 读取 parameters
    /// 5. Deployer 清除 parameters
    constructor() {
        int24 _tickSpacing;
        
        // 从部署器（msg.sender）读取池参数
        // 这是一个巧妙的参数传递模式，避免了构造函数参数
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        // 根据 tick 间距计算每个 tick 的最大流动性
        // 这防止了流动性过度集中在少数 tick 上
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    // ============ 内部辅助函数 ============
    
    /// @dev tick 有效性检查
    /// @notice 验证 tickLower 和 tickUpper 是否在有效范围内
    /// @param tickLower 下限 tick
    /// @param tickUpper 上限 tick
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        // tickLower 必须小于 tickUpper（价格区间有效）
        require(tickLower < tickUpper, 'TLU');
        
        // tickLower 必须 >= 最小 tick (-887272)
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        
        // tickUpper 必须 <= 最大 tick (887272)
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev 返回截断为 32 位的区块时间戳
    /// @notice 即对 2^32 取模，这个方法在测试中会被覆盖
    /// @return 当前区块时间戳（uint32）
    function _blockTimestamp() internal view virtual returns (uint32) {
        // 截断是有意的，预言机设计考虑了时间戳溢出
        // uint32 可以表示约 136 年的时间范围
        return uint32(block.timestamp);
    }

    /// @dev 获取池的 token0 余额
    /// @notice 使用 staticcall 进行 gas 优化
    /// @dev 此函数经过 gas 优化，避免了冗余的 extcodesize 检查
    /// 只进行 returndatasize 检查
    /// @return 池中 token0 的余额
    function balance0() private view returns (uint256) {
        // 使用 staticcall 调用 token0.balanceOf(address(this))
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        
        // 验证调用成功且返回数据至少 32 字节
        require(success && data.length >= 32);
        
        // 解码并返回余额
        return abi.decode(data, (uint256));
    }

    /// @dev 获取池的 token1 余额
    /// @notice 使用 staticcall 进行 gas 优化
    /// @dev 此函数经过 gas 优化，避免了冗余的 extcodesize 检查
    /// @return 池中 token1 的余额
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    // ============ 查询函数 ============
    
    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 获取指定 tick 区间内的累积值快照
    /// @dev 用于计算 LP 头寸在特定价格区间内的表现
    /// 
    /// 返回值说明：
    /// - tickCumulativeInside: tick 在区间内的累积值
    /// - secondsPerLiquidityInsideX128: 区间内每单位流动性的秒数
    /// - secondsInside: 价格在区间内的总秒数
    /// 
    /// 计算逻辑取决于当前 tick 的位置：
    /// 1. 当前 tick < tickLower: 价格在区间下方
    /// 2. tickLower <= 当前 tick < tickUpper: 价格在区间内
    /// 3. 当前 tick >= tickUpper: 价格在区间上方
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        // 验证 tick 范围有效
        checkTicks(tickLower, tickUpper);

        // 声明变量存储下限和上限 tick 的累积值
        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            // 读取下限和上限 tick 的信息
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            
            // 从下限 tick 读取"外部"累积值
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            
            // 要求下限 tick 已初始化（有流动性引用它）
            require(initializedLower);

            bool initializedUpper;
            // 从上限 tick 读取"外部"累积值
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            
            // 要求上限 tick 已初始化
            require(initializedUpper);
        }

        // 缓存 slot0 以节省 gas
        Slot0 memory _slot0 = slot0;

        // 情况 1: 当前价格低于下限（价格在区间下方）
        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } 
        // 情况 2: 当前价格在区间内
        else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            
            // 获取当前的累积值
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            
            // 计算区间内的累积值
            // inside = total - below - above
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } 
        // 情况 3: 当前价格高于上限（价格在区间上方）
        else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    /// @notice 观察历史价格数据（预言机功能）
    /// @dev 返回指定时间点的累积 tick 和流动性数据
    /// 
    /// 用途：计算 TWAP（时间加权平均价格）
    /// 
    /// @param secondsAgos 要查询的历史时间点数组（距今的秒数）
    /// @return tickCumulatives tick 累积值数组
    /// @return secondsPerLiquidityCumulativeX128s 每单位流动性的秒数累积值数组
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 增加观察数组的容量
    /// @dev 任何人都可以调用此函数来扩展预言机的历史数据容量
    /// 
    /// 扩容说明：
    /// - 初始容量为 1
    /// - 最大容量为 65535
    /// - 扩容需要支付 gas（为新槽位预写入数据）
    /// - 扩容后可以存储更长时间的历史价格数据
    /// 
    /// @param observationCardinalityNext 目标容量
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        // 获取当前的目标容量
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        
        // 尝试扩展观察数组
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        
        // 更新目标容量
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        
        // 如果容量实际发生了变化，触发事件
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    // ============ 池初始化 ============
    
    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 初始化池的价格
    /// @dev 只能调用一次，设置初始的 sqrtPrice
    /// 注意：不使用 lock 修饰符，因为它会将 unlocked 初始化为 true
    /// 
    /// 初始化后：
    /// - 设置初始价格和对应的 tick
    /// - 初始化预言机（容量为 1）
    /// - 解锁池，允许后续操作
    /// 
    /// @param sqrtPriceX96 初始的平方根价格（Q64.96 格式）
    function initialize(uint160 sqrtPriceX96) external override {
        // 要求池尚未初始化（sqrtPriceX96 == 0）
        require(slot0.sqrtPriceX96 == 0, 'AI');

        // 根据平方根价格计算对应的 tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // 初始化预言机，返回初始容量（1, 1）
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        // 初始化 slot0
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,               // 设置初始价格
            tick: tick,                                 // 设置初始 tick
            observationIndex: 0,                        // 观察索引从 0 开始
            observationCardinality: cardinality,        // 当前容量为 1
            observationCardinalityNext: cardinalityNext, // 下一个容量为 1
            feeProtocol: 0,                             // 初始协议费为 0
            unlocked: true                              // 解锁池
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    // ============ 头寸管理内部函数 ============
    
    /// @notice 修改头寸参数结构体
    struct ModifyPositionParams {
        address owner;          // 头寸所有者
        int24 tickLower;        // 价格区间下限
        int24 tickUpper;        // 价格区间上限
        int128 liquidityDelta;  // 流动性变化量（正数=添加，负数=移除）
    }

    /// @dev 修改头寸（添加或移除流动性）
    /// @notice 这是 mint 和 burn 函数的核心逻辑
    /// 
    /// 功能：
    /// 1. 更新头寸的流动性
    /// 2. 更新相关 tick 的数据
    /// 3. 如果当前价格在区间内，更新活跃流动性
    /// 4. 计算需要的代币数量
    /// 
    /// @param params 修改参数
    /// @return position 头寸的存储指针
    /// @return amount0 token0 的数量（正=用户需支付给池，负=池需支付给用户）
    /// @return amount1 token1 的数量
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        // 验证 tick 范围有效
        checkTicks(params.tickLower, params.tickUpper);

        // 缓存 slot0 以节省 gas（避免多次 SLOAD）
        Slot0 memory _slot0 = slot0;

        // 更新头寸信息
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        // 如果流动性有变化，计算需要的代币数量
        if (params.liquidityDelta != 0) {
            // 情况 1: 当前价格低于区间下限
            // 流动性只能从左到右跨越进入区间（需要 token0）
            if (_slot0.tick < params.tickLower) {
                // 只需要 token0
                // 公式: amount0 = liquidity * (1/sqrt(P_lower) - 1/sqrt(P_upper))
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } 
            // 情况 2: 当前价格在区间内
            else if (_slot0.tick < params.tickUpper) {
                // 缓存当前流动性
                uint128 liquidityBefore = liquidity;

                // 写入预言机观察记录
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 需要 token0 和 token1
                // amount0: 从当前价格到上限需要的 token0
                // amount1: 从下限到当前价格需要的 token1
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新活跃流动性（因为当前价格在此区间内）
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } 
            // 情况 3: 当前价格高于区间上限
            // 流动性只能从右到左跨越进入区间（需要 token1）
            else {
                // 只需要 token1
                // 公式: amount1 = liquidity * (sqrt(P_upper) - sqrt(P_lower))
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev 更新头寸并处理相关 tick
    /// @notice 获取并更新头寸，同时更新 tick 的流动性数据
    /// 
    /// 主要步骤：
    /// 1. 获取/创建头寸
    /// 2. 如果流动性变化，更新上下限 tick
    /// 3. 计算并更新头寸的费用
    /// 4. 如果移除流动性，清理不需要的 tick
    /// 
    /// @param owner 头寸所有者
    /// @param tickLower 下限 tick
    /// @param tickUpper 上限 tick  
    /// @param liquidityDelta 流动性变化量
    /// @param tick 当前 tick（避免重复 SLOAD）
    /// @return position 头寸的存储引用
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取头寸（如果不存在会创建）
        // key = keccak256(owner, tickLower, tickUpper)
        position = positions.get(owner, tickLower, tickUpper);

        // 缓存全局费用增长以节省 gas
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        // 标记 tick 是否发生"翻转"（从未初始化到已初始化，或反之）
        bool flippedLower;
        bool flippedUpper;
        
        // 如果流动性有变化，需要更新 tick
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            
            // 获取当前的预言机累积值
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新下限 tick
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,  // 不是上限
                maxLiquidityPerTick
            );
            
            // 更新上限 tick
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,   // 是上限
                maxLiquidityPerTick
            );

            // 如果下限 tick 发生翻转，更新 tickBitmap
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            // 如果上限 tick 发生翻转，更新 tickBitmap
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算价格区间内的费用增长
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 更新头寸的流动性和费用
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 如果是移除流动性（负数），清理不需要的 tick 数据
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    // ============ 流动性管理 ============
    
    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 添加流动性（铸造头寸）
    /// @dev 通过 _modifyPosition 间接应用 noDelegateCall
    /// 
    /// 执行流程：
    /// 1. 验证流动性数量 > 0
    /// 2. 调用 _modifyPosition 计算需要的代币数量
    /// 3. 记录添加流动性前的余额
    /// 4. 调用回调函数，让调用者转入代币
    /// 5. 验证代币已转入（余额检查）
    /// 6. 触发 Mint 事件
    /// 
    /// 重要：使用余额检查而非返回值验证支付
    /// 
    /// @param recipient 流动性接收者（头寸所有者）
    /// @param tickLower 价格区间下限
    /// @param tickUpper 价格区间上限
    /// @param amount 要添加的流动性数量
    /// @param data 传递给回调函数的数据
    /// @return amount0 需要支付的 token0 数量
    /// @return amount1 需要支付的 token1 数量
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 验证流动性数量必须大于 0
        require(amount > 0);
        
        // 修改头寸，计算需要的代币数量
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()  // 正数表示添加
                })
            );

        // 转换为无符号整数
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 记录转账前的余额
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        
        // 调用回调函数，让调用者转入代币
        // 调用者必须在回调中转入 amount0 的 token0 和 amount1 的 token1
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        
        // 验证代币已转入（余额增加了预期的数量）
        // 使用余额检查而非信任回调的返回值，更安全
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 收取累积的费用
    /// @dev 从头寸的 tokensOwed 中提取费用
    /// 
    /// 说明：
    /// - burn() 会将代币记入 tokensOwed，但不实际转账
    /// - collect() 执行实际的代币转账
    /// - 可以部分收取（amount < tokensOwed）
    /// 
    /// @param recipient 接收者地址
    /// @param tickLower 头寸下限
    /// @param tickUpper 头寸上限
    /// @param amount0Requested 请求的 token0 数量
    /// @param amount1Requested 请求的 token1 数量
    /// @return amount0 实际转出的 token0 数量
    /// @return amount1 实际转出的 token1 数量
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // 无需 checkTicks，因为无效头寸的 tokensOwed 永远为 0
        
        // 获取头寸
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 计算实际可收取的数量（不能超过 tokensOwed）
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // 转出 token0
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        
        // 转出 token1
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 移除流动性（销毁头寸）
    /// @dev 通过 _modifyPosition 间接应用 noDelegateCall
    /// 
    /// 执行流程：
    /// 1. 调用 _modifyPosition，负的 liquidityDelta 表示移除
    /// 2. 计算应返还的代币数量
    /// 3. 将数量记入头寸的 tokensOwed（不立即转账）
    /// 4. 触发 Burn 事件
    /// 5. 用户需要后续调用 collect() 来提取代币
    /// 
    /// 注意：burn 不直接转账，而是更新 tokensOwed
    /// 这种设计允许用户累积费用后一次性提取，节省 gas
    /// 
    /// @param tickLower 头寸下限
    /// @param tickUpper 头寸上限
    /// @param amount 要移除的流动性数量
    /// @return amount0 可收取的 token0 数量
    /// @return amount1 可收取的 token1 数量
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 修改头寸，计算应返还的代币数量
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()  // 负数表示移除
                })
            );

        // 转换为正数（_modifyPosition 返回负数）
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // 将应返还的代币数量记入 tokensOwed
        // 不立即转账，用户需要调用 collect() 提取
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    // ============ 交易相关结构体 ============
    
    /// @notice 交易缓存，存储交易开始时的状态
    struct SwapCache {
        uint8 feeProtocol;           // 输入代币的协议费率
        uint128 liquidityStart;      // 交易开始时的流动性
        uint32 blockTimestamp;       // 当前区块时间戳
        int56 tickCumulative;        // tick 累积值（首次跨越 tick 时计算）
        uint160 secondsPerLiquidityCumulativeX128;  // 流动性累积值
        bool computedLatestObservation;  // 是否已计算最新观察值
    }

    /// @notice 交易状态，随着交易进行不断更新
    struct SwapState {
        int256 amountSpecifiedRemaining;  // 剩余待交易的数量
        int256 amountCalculated;          // 已计算的输出数量
        uint160 sqrtPriceX96;             // 当前平方根价格
        int24 tick;                       // 当前 tick
        uint256 feeGrowthGlobalX128;      // 输入代币的全局费用增长
        uint128 protocolFee;              // 协议费累积
        uint128 liquidity;                // 当前活跃流动性
    }

    /// @notice 单步交易计算结果
    struct StepComputations {
        uint160 sqrtPriceStartX96;   // 步骤开始时的价格
        int24 tickNext;              // 下一个目标 tick
        bool initialized;            // tickNext 是否已初始化
        uint160 sqrtPriceNextX96;    // 下一个 tick 的价格
        uint256 amountIn;            // 此步骤的输入数量
        uint256 amountOut;           // 此步骤的输出数量
        uint256 feeAmount;           // 此步骤的费用
    }

    // ============ 交易功能 ============
    
    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 执行代币交易（swap）
    /// @dev 这是 Uniswap V3 最复杂的函数之一
    /// 
    /// 交易算法：
    /// 1. 验证输入参数
    /// 2. 设置初始状态
    /// 3. 循环执行交易步骤：
    ///    a. 找到下一个已初始化的 tick
    ///    b. 计算到该 tick 的交易量
    ///    c. 如果跨越了 tick，更新流动性
    ///    d. 更新价格和状态
    /// 4. 更新全局状态
    /// 5. 执行代币转账（通过回调）
    /// 6. 验证支付
    /// 
    /// 关键概念：
    /// - exactInput: 指定输入数量（amountSpecified > 0）
    /// - exactOutput: 指定输出数量（amountSpecified < 0）
    /// - zeroForOne: token0 换 token1（true）或反向（false）
    /// 
    /// @param recipient 输出代币的接收者
    /// @param zeroForOne 交易方向（true = token0 → token1）
    /// @param amountSpecified 指定的数量（正数=精确输入，负数=精确输出）
    /// @param sqrtPriceLimitX96 价格限制（滑点保护）
    /// @param data 传递给回调的数据
    /// @return amount0 token0 的变化量（正=转入池，负=转出池）
    /// @return amount1 token1 的变化量
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        // 验证：指定数量不能为 0
        require(amountSpecified != 0, 'AS');

        // 读取并缓存 slot0
        Slot0 memory slot0Start = slot0;

        // 验证：池必须已解锁（重入保护）
        require(slot0Start.unlocked, 'LOK');
        
        // 验证：价格限制必须合理
        // 如果是 token0 → token1（zeroForOne = true）：
        //   - 价格会下降，限制价格必须 < 当前价格
        //   - 限制价格必须 > 最小价格
        // 如果是 token1 → token0（zeroForOne = false）：
        //   - 价格会上升，限制价格必须 > 当前价格
        //   - 限制价格必须 < 最大价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        // 设置锁定状态
        slot0.unlocked = false;

        // 初始化交易缓存
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity,
                blockTimestamp: _blockTimestamp(),
                // 从 feeProtocol 中提取相应代币的协议费率
                // feeProtocol 的低 4 位存储 token0，高 4 位存储 token1
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        // 判断是精确输入还是精确输出
        bool exactInput = amountSpecified > 0;

        // 初始化交易状态
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,
                amountCalculated: 0,
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
                protocolFee: 0,
                liquidity: cache.liquidityStart
            });

        // 循环执行交易，直到：
        // 1. 输入/输出用尽，或
        // 2. 达到价格限制
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            // 记录步骤开始时的价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // 找到下一个已初始化的 tick
            // 使用 TickBitmap 快速查找（O(1) 复杂度）
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // 确保不超出 tick 范围
            // tickBitmap 不知道这些边界，需要手动检查
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取下一个 tick 的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算交易到目标价格的各项数值
            // 目标价格 = min(下一个tick的价格, 价格限制)
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            // 更新剩余数量和已计算数量
            if (exactInput) {
                // 精确输入：减少剩余输入，增加输出
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 精确输出：增加剩余输出，增加输入
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // 如果启用了协议费，计算并扣除协议费
            if (cache.feeProtocol > 0) {
                // 协议费 = 总费用 / feeProtocol
                // 例如：feeProtocol = 4，则协议费 = 25%
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // 更新全局费用追踪
            // feeGrowth = (费用 * 2^128) / 流动性
            // 使用 Q128 格式存储高精度的每单位流动性费用
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // 如果到达了下一个 tick，需要更新 tick
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 如果该 tick 已初始化，执行 tick 跨越
                if (step.initialized) {
                    // 首次跨越 tick 时，计算预言机数据
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    
                    // 跨越 tick，获取流动性净变化
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    
                    // 如果向左移动（token0 → token1），取反流动性变化
                    // 因为 liquidityNet 是为从左到右定义的
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // 更新活跃流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                // 更新当前 tick
                // 注意：向左移动时 tick = tickNext - 1
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 价格变化了但没有跨越 tick，重新计算 tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 如果 tick 发生了变化，更新 slot0 并写入预言机
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            
            // 更新 slot0 的多个字段
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // tick 未变化，只更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果流动性发生了变化，更新全局流动性
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // 更新全局费用增长和协议费
        // 溢出是可接受的，协议需要在达到 type(uint128).max 之前提取费用
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 计算最终的 amount0 和 amount1
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // 执行代币转账
        if (zeroForOne) {
            // token0 → token1 的交易
            // 先转出 token1 给接收者（如果 amount1 < 0）
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            // 记录转账前的 token0 余额
            uint256 balance0Before = balance0();
            
            // 调用回调，让调用者转入 token0
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            
            // 验证 token0 已转入（余额检查）
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            // token1 → token0 的交易
            // 先转出 token0 给接收者
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            // 记录转账前的 token1 余额
            uint256 balance1Before = balance1();
            
            // 调用回调，让调用者转入 token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            
            // 验证 token1 已转入
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        // 触发交易事件
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        
        // 解锁池
        slot0.unlocked = true;
    }

    // ============ 闪电贷 ============
    
    /// @inheritdoc IUniswapV3PoolActions
    /// @notice 闪电贷功能
    /// @dev 允许借出池中的代币，只要在同一交易中归还 + 费用
    /// 
    /// 执行流程：
    /// 1. 记录借出前的余额
    /// 2. 转出借款代币给接收者
    /// 3. 调用回调函数（借款者在此使用资金）
    /// 4. 验证归还 + 费用
    /// 5. 更新费用累积
    /// 
    /// 用途：
    /// - 套利
    /// - 清算
    /// - 抵押品互换
    /// - 复杂的 DeFi 策略
    /// 
    /// @param recipient 接收借款的地址
    /// @param amount0 借出的 token0 数量
    /// @param amount1 借出的 token1 数量
    /// @param data 传递给回调的数据
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        
        // 要求池中有流动性
        require(_liquidity > 0, 'L');

        // 计算闪电贷费用（与交易费率相同）
        // fee0 = amount0 * fee / 1e6（向上取整）
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        
        // 记录借出前的余额
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // 转出借款代币
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // 调用闪电贷回调
        // 借款者必须在回调中：
        // 1. 使用借款执行操作
        // 2. 归还借款 + 费用
        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        // 获取归还后的余额
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        // 验证归还了借款 + 费用
        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // 计算实际支付的金额（可能大于最小要求）
        // 减法是安全的，因为我们知道 balanceAfter >= balanceBefore + fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        // 处理 token0 的费用分配
        if (paid0 > 0) {
            // 提取 token0 的协议费率（低 4 位）
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            
            // 计算协议费（如果启用）
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            
            // 更新全局费用增长（扣除协议费后的部分）
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        
        // 处理 token1 的费用分配
        if (paid1 > 0) {
            // 提取 token1 的协议费率（高 4 位）
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            
            // 计算协议费
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            
            // 更新全局费用增长
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    // ============ 协议管理 ============
    
    /// @inheritdoc IUniswapV3PoolOwnerActions
    /// @notice 设置协议费率
    /// @dev 只有工厂所有者可以调用
    /// 
    /// 协议费说明：
    /// - 协议费是从交易费中抽取的一部分
    /// - 取值范围：0（关闭）或 4-10
    /// - 值表示分母，例如 4 表示 1/4 = 25% 的交易费归协议
    /// - 两个代币可以设置不同的协议费率
    /// - 协议费率打包存储：低 4 位 = token0，高 4 位 = token1
    /// 
    /// @param feeProtocol0 token0 的协议费率
    /// @param feeProtocol1 token1 的协议费率
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        // 验证费率有效：0（关闭）或 4-10
        // 范围限制：最少 10%（1/10），最多 25%（1/4）
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        
        // 记录旧值用于事件
        uint8 feeProtocolOld = slot0.feeProtocol;
        
        // 打包存储：低 4 位 = token0，高 4 位 = token1
        // 例如：feeProtocol0 = 4, feeProtocol1 = 5
        //      结果 = 4 + (5 << 4) = 4 + 80 = 84
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    /// @notice 收取累积的协议费用
    /// @dev 只有工厂所有者可以调用
    /// 
    /// 特殊设计：
    /// - 如果请求金额等于全部累积费用，会保留 1 wei
    /// - 这样可以节省 gas（避免清零存储槽）
    /// - 清零存储槽（SSTORE 非零→零）虽然有 gas 退款，但仍比保持非零贵
    /// 
    /// @param recipient 接收费用的地址
    /// @param amount0Requested 请求的 token0 数量
    /// @param amount1Requested 请求的 token1 数量
    /// @return amount0 实际转出的 token0 数量
    /// @return amount1 实际转出的 token1 数量
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        // 计算实际可收取的数量（不超过累积的协议费）
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        // 收取 token0 协议费
        if (amount0 > 0) {
            // 如果收取全部，保留 1 wei 以节省 gas
            if (amount0 == protocolFees.token0) amount0--;
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        
        // 收取 token1 协议费
        if (amount1 > 0) {
            // 如果收取全部，保留 1 wei
            if (amount1 == protocolFees.token1) amount1--;
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
