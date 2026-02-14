# MeEA V2.1 - Inventory Controlled Semi-Market-Making EA

V2.1 implements the frozen engineering spec for a controllable grid/inventory model on MT5.

## Core Behavior
- `RANGE_GRID`: two-sided inventory collection.
- `TREND_DE_RISK`: stop adverse adds, reduce adverse inventory first, optional favorable add.
- `FLATTEN`: hard stop all positions.
- `COOLDOWN`: lockout after hard/soft events.

## ActionGroup Priority (single group per bar)
1. `FLATTEN`
2. `DE-RISK`
3. `EXIT`
4. `ADD`

If a higher-priority group executes on the bar, lower groups are skipped.

## Implemented V2.1 Patches
1. Minimum dwell time for `RANGE <-> TREND` switching.
2. EMA slope normalized by ATR (`slope_z`).
3. `trend_dir` sourced only from EMA slope sign.
4. Trend-side add disabled when `soft_lock` or `forced_liq`.
5. Forced liquidation release hysteresis (`<= 0.8 * budget` for consecutive bars).
6. Single `ActionGroup` per new bar.

## File Layout
- `V2/Experts/MeEA_V2.mq5`: main state machine and bar dispatcher.
- `V2/Include/CRegimeEngine.mqh`: bias hysteresis + slope_z + hold bars.
- `V2/Include/CInventoryEngine.mqh`: side inventory stats and forced liquidation.
- `V2/Include/CDeRiskEngine.mqh`: trend anchor and stepped trigger.
- `V2/Include/CRiskManagerV2.mqh`: soft/hard lock, cooldown, spread/margin checks.
- `V2/Include/CTradeExecutor.mqh`: order execution and close helpers.
- `V2/Include/CV2Types.mqh`: state/action enums.

## Notes
- News filter is currently a placeholder (`IsNewsBlocked() == false`).
- This branch is intended for backtest calibration and execution behavior validation first.
