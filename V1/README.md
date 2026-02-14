# MeEA — 基于 Kalman Filter 的自适应趋势跟踪 EA

MeEA 是一个 MetaTrader 5 Expert Advisor，结合三大核心组件实现自适应趋势跟踪交易：

- **Kalman Filter** — 状态空间模型估计价格趋势水平和斜率
- **Hurst Exponent** — R/S 分析检测市场是否具有持续性（趋势性）
- **Volatility Regime** — 实现波动率百分位排名，分类市场波动状态

只在趋势确认 + 持续性检测通过 + 价格突破置信带时入场，避免在震荡市中频繁交易。

---

## 系统架构

```
市场数据 (close price)
    │
    ▼
┌─────────────────────────────────────────────┐
│              CSignalEngine                  │
│  ┌──────────────┐ ┌──────────────┐          │
│  │ CKalmanFilter│ │CHurstExponent│          │
│  │ level, slope │ │ H exponent   │          │
│  └──────────────┘ └──────────────┘          │
│  ┌──────────────────┐                       │
│  │CVolatilityRegime │                       │
│  │ LOW/NORMAL/HIGH  │                       │
│  └──────────────────┘                       │
│  → 输出: SIGNAL_BUY / SIGNAL_SELL / NONE    │
└──────────────┬──────────────────────────────┘
               │
    ┌──────────┴──────────┐
    ▼                     ▼
┌──────────────┐  ┌───────────────┐
│ CRiskManager │  │CTradeExecutor │
│ 仓位计算     │  │ 订单执行      │
│ 止损距离     │  │ 移动止损      │
│ DD/点差检查  │  │ 平仓管理      │
└──────────────┘  └───────────────┘
```

### 文件职责一览

| 文件 | 职责 |
|------|------|
| `Experts/MeEA.mq5` | EA 主入口：初始化、新 K 线检测、信号调度、出入场逻辑、可视化 |
| `Include/CKalmanFilter.mqh` | Kalman Filter 状态空间模型，predict-update 循环 |
| `Include/CHurstExponent.mqh` | Hurst 指数 R/S 分析，判定市场持续性 |
| `Include/CVolatilityRegime.mqh` | 实现波动率计算与百分位排名，三状态分类 |
| `Include/CSignalEngine.mqh` | 集成三大模块，生成入场/出场信号 |
| `Include/CRiskManager.mqh` | 仓位计算、止损定价、每日回撤/点差/持仓数检查 |
| `Include/CTradeExecutor.mqh` | 市价单执行、止损修改、移动止损、按方向平仓 |

---

## 核心算法说明

### Kalman Filter

线性状态空间模型，状态向量 `X = [level, slope]`：

- **状态转移**: `F = [[1, 1], [0, 1]]` — level 按 slope 递推，slope 保持不变
- **观测矩阵**: `H = [1, 0]` — 只观测 level
- **Predict-Update 循环**:
  1. Predict: `X_pred = F × X`, `P_pred = F × P × F' + Q`
  2. Innovation: `y = price - H × X_pred`
  3. Kalman Gain: `K = P_pred × H' / S`
  4. Update: `X = X_pred + K × y`, `P = (I - K×H) × P_pred`
- **3σ 异常值门控**: 当 innovation `|y| > 3 × √S` 时（如周末跳空），跳过 update 步骤，仅执行 predict（P 矩阵增长，不修正状态）
- **价格尺度自适应 P 矩阵**: 首次观测时 `P[0][0] = (price × 0.01)²`，`P[1][1] = P[0][0] × 0.01`，确保不同价位品种的初始不确定度合理

### Hurst Exponent

基于 R/S（Rescaled Range）分析的 Hurst 指数估计：

1. 使用环形缓冲存储对数收益率 `r = ln(close / prevClose)`
2. 对缓冲中的数据，以 1.5 倍递增的子段长度 n（从 8 开始）进行 R/S 计算
3. 每个子段内：计算均值偏差累积序列的极差 R，除以标准差 S
4. 对多个 (log n, log R/S) 点做线性回归，斜率即 Hurst 指数 H
5. H 钳制到 [0, 1] 范围

**解读**: H > 0.55 判定为趋势市场（持续性），H ≈ 0.5 为随机游走，H < 0.5 为均值回归

### Volatility Regime

基于实现波动率（Realized Volatility）的历史百分位排名：

1. 计算近 `Vol_Period` 根 K 线对数收益率的标准差作为当前 RV
2. 将 RV 存入历史环形缓冲（容量 `Vol_HistPeriod`）
3. 计算当前 RV 在历史分布中的百分位排名

| 百分位 | 状态 |
|--------|------|
| < 25% | `VOL_LOW` |
| 25% - 75% | `VOL_NORMAL` |
| > 75% | `VOL_HIGH` |

---

## 信号逻辑

### 入场条件

**做多 (BUY)**：三个条件同时满足
1. Kalman slope > 0（趋势向上）
2. Hurst > `Hurst_Threshold`（市场具有持续性）
3. 当前价格 > Kalman 上置信带（价格突破）

**做空 (SELL)**：三个条件同时满足
1. Kalman slope < 0（趋势向下）
2. Hurst > `Hurst_Threshold`（市场具有持续性）
3. 当前价格 < Kalman 下置信带（价格突破）

### 出场条件

**平多仓**: slope < 0 **AND** Hurst < 0.50（slope 反转 AND 趋势消失）

**平空仓**: slope > 0 **AND** Hurst < 0.50（slope 反转 AND 趋势消失）

使用 AND 逻辑而非 OR，避免 slope 短暂波动引起的 whipsaw 假出场。

### 冷却期

平仓后 **2 根 K 线** 内禁止再入场（`g_closeCooldown = 2`），防止在趋势末端反复开平。

### 反向持仓保护

- 持有多仓时不允许开空
- 持有空仓时不允许开多

---

## 风控机制

### 仓位计算

```
lots = (equity × Risk_PerTrade) / (stopPoints × pointValue)
```

然后根据波动率状态调整：

| 波动率状态 | 系数 | 原因 |
|-----------|------|------|
| `VOL_LOW` | ×0.5 | 低波动率下假突破多，减仓 |
| `VOL_NORMAL` | ×1.0 | 正常状态，不调整 |
| `VOL_HIGH` | ×0.7 | 高波动率下止损更宽，减仓控制风险 |

最终 lots 按经纪商约束（最小/最大手数、步长）规整。

### 止损设置

基于 Kalman 估计误差和置信带乘数：

- 做多止损: `Kalman Level - EstError × KF_ConfBand`
- 做空止损: `Kalman Level + EstError × KF_ConfBand`

其中 `EstError = √P[0][0]`（Kalman 估计不确定度）。

### 移动止损

每根新 K 线（入场当根除外）计算移动止损位：

- 多仓: `Kalman Level - 1 × EstError`
- 空仓: `Kalman Level + 1 × EstError`

**仅收紧方向**：多仓只能上移止损，空仓只能下移止损，不会放宽。

### 约束条件

| 约束 | 参数 | 默认值 | 说明 |
|------|------|--------|------|
| 最大持仓数 | `Max_Positions` | 3 | 超过则禁止开新仓 |
| 每日最大回撤 | `Max_DailyDD` | 3% | 当日亏损超过当日起始 equity 的 3% 则停止交易 |
| 最大点差 | `Max_SpreadPoints` | 30 点 | 点差过大时不开仓 |

---

## 输入参数一览表

### Kalman Filter 参数

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `KF_ProcessNoise` | 0.01 | 过程噪声（Q 矩阵对角元素） | 增大→更灵敏跟踪价格变化；减小→更平滑 |
| `KF_ObservNoise` | 1.0 | 观测噪声（R） | 增大→更平滑，信号更少；减小→更灵敏 |
| `KF_ConfBand` | 2.0 | 置信带乘数（用于入场突破和止损距离） | 增大→入场条件更严格，止损更宽 |

### Hurst Exponent 参数

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `Hurst_Period` | 200 | R/S 分析回看窗口（K 线数） | 增大→更稳定但反应慢；减小→反应快但噪声大 |
| `Hurst_Threshold` | 0.55 | 趋势判定阈值 | 提高→更严格，交易更少；降低→更宽松 |

### Volatility Regime 参数

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `Vol_Period` | 100 | 当前 RV 计算窗口 | 增大→更平滑的波动率估计 |
| `Vol_HistPeriod` | 500 | 历史 RV 百分位窗口 | 增大→更稳定的百分位基准 |

### Risk Management 参数

| 参数 | 默认值 | 说明 | 调优建议 |
|------|--------|------|----------|
| `Risk_PerTrade` | 0.01 (1%) | 每笔交易风险占 equity 比例 | 保守交易者可降至 0.005 |
| `Max_Positions` | 3 | 最大同时持仓数 | 根据账户规模调整 |
| `Max_DailyDD` | 0.03 (3%) | 每日最大回撤比例 | 更保守可降至 0.02 |
| `Max_SpreadPoints` | 30 | 允许的最大点差（points） | 根据交易品种调整 |

### Execution 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `Slippage` | 10 | 允许滑点（points） |
| `MagicNumber` | 20240101 | EA 标识号，用于区分不同 EA 的持仓 |

### Timeframe & Visualization

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `TF_Entry` | `PERIOD_H1` | 信号生成时间周期 |
| `ShowVisuals` | true | 在图表上显示 Kalman 带和交易箭头 |

---

## 安装与使用

### 文件部署

将项目文件复制到 MetaTrader 5 数据目录（通过 MT5 菜单 `文件` → `打开数据目录` 获取路径）：

```
<MT5 数据目录>/MQL5/
├── Experts/MeEA.mq5          ← 复制到 Experts/
└── Include/
    ├── CKalmanFilter.mqh      ← 复制到 Include/
    ├── CHurstExponent.mqh
    ├── CVolatilityRegime.mqh
    ├── CSignalEngine.mqh
    ├── CRiskManager.mqh
    └── CTradeExecutor.mqh     ← 复制到 Include/
```

### 编译

1. 打开 MetaEditor（MT5 内按 F4）
2. 打开 `Experts/MeEA.mq5`
3. 按 F7 编译，确认无错误

### 回测设置建议

1. 打开 Strategy Tester（Ctrl+R）
2. 选择 `MeEA` EA
3. 推荐设置：
   - 品种：主要货币对（如 EURUSD, GBPUSD）
   - 时间周期：H1（与 `TF_Entry` 默认值一致）
   - 建模方式：每个 tick 基于真实 tick（最精确）
   - 回测区间：至少 1 年以上数据，确保充分预热
   - 初始资金：10000 或以上

### 图表可视化

启用 `ShowVisuals = true` 后，图表上将显示：

- **蓝色实线** — Kalman Level（滤波后的趋势水平）
- **灰色虚线** — 上下置信带（Level ± ConfBand × EstError）
- **绿色上箭头** — BUY 入场信号
- **红色下箭头** — SELL 入场信号
- **图表注释** — 实时显示 Kalman Level、Slope、Hurst、波动率状态和百分位

---

## 文件结构

```
MeEA/
├── Experts/MeEA.mq5              # EA 主程序
├── Include/
│   ├── CKalmanFilter.mqh          # Kalman Filter 状态空间模型
│   ├── CHurstExponent.mqh         # Hurst 指数 R/S 分析
│   ├── CVolatilityRegime.mqh      # 波动率状态分类
│   ├── CSignalEngine.mqh          # 信号引擎（集成以上三模块）
│   ├── CRiskManager.mqh           # 风控与仓位管理
│   └── CTradeExecutor.mqh         # 交易执行器
├── backtest/                      # Python 回测系统
│   ├── __init__.py
│   ├── __main__.py                # python -m backtest 入口
│   ├── config.py                  # 参数与品种配置
│   ├── kalman_filter.py           # ← CKalmanFilter.mqh
│   ├── hurst_exponent.py          # ← CHurstExponent.mqh
│   ├── volatility_regime.py       # ← CVolatilityRegime.mqh
│   ├── signal_engine.py           # ← CSignalEngine.mqh
│   ├── risk_manager.py            # ← CRiskManager.mqh + 保证金模拟
│   ├── position.py                # 持仓/交易数据结构
│   ├── backtester.py              # bar-by-bar 回测引擎
│   ├── data_loader.py             # CSV 加载 / yfinance 下载
│   ├── reporting.py               # 绩效报告
│   ├── visualize.py               # matplotlib 图表
│   ├── main.py                    # CLI 入口
│   └── data/                      # 数据目录
├── requirements.txt               # Python 依赖
└── README.md                      # 本文档
```

---

## Python 回测系统

### 简介

`backtest/` 目录提供了一套纯 Python 实现的回测系统，将 MQL5 EA 的核心逻辑 1:1 移植到 Python 中，用于：

- **快速策略验证** — 无需 MT5 即可在本地验证信号逻辑和参数调优
- **数据灵活性** — 支持本地 CSV 和 yfinance 在线下载
- **可视化分析** — matplotlib 生成权益曲线、回撤、Hurst 等多维度图表

每个 Python 模块对应一个 MQL5 组件，算法逻辑保持一致（详见下方映射表）。

### 环境安装

```bash
# Python 3.10+
pip install -r requirements.txt
```

依赖库：`numpy`, `pandas`, `matplotlib`, `yfinance`（仅在线下载时需要）

### 使用示例

**1. 使用本地 CSV 数据回测**

```bash
python -m backtest --symbol EURUSD --equity 10000 --leverage 100 \
    --data backtest/data/EURUSD_H1.csv
```

**2. 通过 yfinance 下载日线数据回测**

```bash
python -m backtest --symbol GBPUSD --equity 5000 --leverage 200 \
    --download --start 2023-01-01 --end 2024-12-31
```

**3. 覆盖策略参数**

```bash
python -m backtest --symbol EURUSD --equity 10000 --leverage 100 \
    --data data.csv --risk 0.02 --max-positions 5 --hurst-threshold 0.60
```

**其他选项：**

| 选项 | 说明 |
|------|------|
| `--no-plot` | 跳过图表显示 |
| `--save-plot PATH` | 将图表保存为图片文件 |
| `--export-trades PATH` | 将交易记录导出为 CSV |

完整参数列表可通过 `python -m backtest --help` 查看。

### 支持品种

| 品种 | 类型 | 合约大小 | 默认点差 |
|------|------|----------|----------|
| EURUSD | 外汇 | 100,000 | 15 点 |
| GBPUSD | 外汇 | 100,000 | 18 点 |
| USDJPY | 外汇 | 100,000 | 15 点 |
| AUDUSD | 外汇 | 100,000 | 18 点 |
| XAUUSD | 黄金 | 100 | 30 点 |

### 回测报告说明

回测完成后终端输出的报告包含以下指标：

**Account（账户）**
- `Initial / Final Equity` — 初始/最终权益
- `Period` — 回测时间范围

**Trade Statistics（交易统计）**
- `Total Trades` — 总交易笔数（含多/空分类）
- `Win Rate` — 胜率
- `Avg Win / Avg Loss` — 平均盈利/亏损金额
- `Profit/Loss Ratio` — 盈亏比（平均盈利 ÷ 平均亏损）
- `Max Consec. Wins / Losses` — 最大连胜/连亏次数

**Returns（收益）**
- `Net Profit` — 净利润
- `Gross Profit / Gross Loss` — 总盈利/总亏损
- `Profit Factor` — 利润因子（总盈利 ÷ 总亏损）
- `CAGR` — 年化复合增长率

**Risk（风险）**
- `Sharpe Ratio` — 夏普比率（年化，基于 252 交易日）
- `Sortino Ratio` — 索提诺比率（仅考虑下行风险）
- `Max Drawdown` — 最大回撤百分比
- `Max DD Duration` — 最大回撤持续时长（K 线数）
- `Max Single Loss` — 单笔最大亏损

**Position / Margin（仓位/保证金）**
- `Avg Hold Duration` — 平均持仓时长（K 线数）
- `Max Concurrent Positions` — 最大同时持仓数
- `Max Margin Usage` — 最大保证金使用率

### 图表说明

回测默认生成 4 子图的组合图表：

| 子图 | 内容 |
|------|------|
| 1 — Price & Kalman | 收盘价（黑色）、Kalman Level（蓝色）、置信带（灰色虚线）、交易标记（绿 = 盈利、红 = 亏损） |
| 2 — Equity | 权益曲线（深蓝色），灰色虚线标记初始资金 |
| 3 — Hurst | Hurst 指数（紫色），橙色虚线 = 趋势阈值，灰色虚线 = 0.50 随机游走基准 |
| 4 — Drawdown | 回撤面积图（红色填充） |

### MQL5 ↔ Python 模块映射

| MQL5 文件 | Python 模块 | 说明 |
|-----------|-------------|------|
| `Include/CKalmanFilter.mqh` | `backtest/kalman_filter.py` | Kalman Filter 状态空间模型 |
| `Include/CHurstExponent.mqh` | `backtest/hurst_exponent.py` | Hurst 指数 R/S 分析 |
| `Include/CVolatilityRegime.mqh` | `backtest/volatility_regime.py` | 波动率状态分类 |
| `Include/CSignalEngine.mqh` | `backtest/signal_engine.py` | 信号引擎 |
| `Include/CRiskManager.mqh` | `backtest/risk_manager.py` | 风控与仓位管理 + 保证金模拟 |
| `Include/CTradeExecutor.mqh` | `backtest/backtester.py` | 交易执行（内嵌于回测引擎） |
| `Experts/MeEA.mq5` | `backtest/main.py` | 主入口与调度 |
| — | `backtest/position.py` | 持仓/交易数据结构（Python 新增） |
| — | `backtest/data_loader.py` | 数据加载（Python 新增） |
| — | `backtest/reporting.py` | 绩效报告（Python 新增） |
| — | `backtest/visualize.py` | 图表可视化（Python 新增） |
| — | `backtest/config.py` | 参数配置（Python 新增） |

### 与 MQL5 回测的差异

| 方面 | MQL5 Strategy Tester | Python 回测系统 |
|------|---------------------|-----------------|
| **价格模型** | 支持 Tick 级别模拟 | Bar-by-bar（基于 OHLC），使用 Close 价成交 |
| **点差** | 来自经纪商的真实 tick 点差 | 使用品种配置中的固定点差模拟 |
| **滑点** | 真实市场滑点 | 按 `slippage_points` 参数固定模拟 |
| **保证金** | 经纪商真实保证金计算 | 简化公式：`lots × contract_size × price / leverage` |
| **手数规整** | 按经纪商 lot_step 规整 | 同样按 `lot_step` 规整，逻辑一致 |
| **数据来源** | MT5 历史数据中心 | CSV 文件或 yfinance（日线） |
| **执行速度** | 较慢（完整 Tick 模拟） | 较快（纯 Python，bar-by-bar） |

> **注意**: Python 回测结果可能与 MT5 Strategy Tester 有偏差，主要原因是价格模型精度差异和点差/滑点模拟方式不同。Python 回测更适合快速验证信号逻辑和参数方向，精确绩效评估建议以 MT5 回测为准。
