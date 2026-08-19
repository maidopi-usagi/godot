# HDDAGI Screen Probe Phase 1：Fresh Reference

Phase 1 是不读取 temporal/spatial reservoir 的 fresh-only 参考 estimator。它用于隔离 transport 与能量合同，并为后续 Phase 2/3 和 NRD 提供可重复基线。

## 路径

```text
Surface Select
  -> N fresh cosine HDDA traces
  -> Raw Resolve (RGB radiance + alpha hit distance)
  -> NRD guide preparation
  -> raw Apply in reference mode
```

`screen_probe_reference_mode=true` 时最终输出故意绕过 NRD，以便直接验证 raw signal；正常 production 则由 NRD RELAX_DIFFUSE 处理同一 raw signal。

## CPU 与 GPU 门禁

`phase1_reference.py` 验证确定性采样序列、候选均值、energy domain 和 shader 合同。GPU `phase1_fresh` 场景：

- 扫描 1/2/4/8 个 fresh cosine candidates；
- 用常量中性 sky + 白平面比较 analytic `D=(0.18,0.18,0.18)`；
- 覆盖 `dynamic_gi_energy=0/0.5/2` 和 CameraAttributes exposure；
- 使用有色方向 sky 避免只测零方差输入；
- 运行 1000 帧 count-1 稳定性序列；
- 覆盖 camera cut、同尺寸 render-buffer reconfigure、exposure step、`UPDATE_ONCE` SubViewport、resize、外层 screen-probe disable/re-enable；
- 检查 fresh ray、hit/miss、raw HDR reduction 和 finite 守恒；
- 检查 Surface Select、Fresh Trace、Raw Resolve、NRD Guide Preparation 和 Apply 的 GPU 标记。

## 当前验收状态

`expected_phase1_metrics.json` 已显式标记为 unbaselined。旧硬件 profile 属于已删除的自制降噪路径，不能作为 NRD/SHARC 管线的通过证据。CPU reference 与结构检查仍可执行；恢复 `acceptance_ready=true` 前必须在目标硬件上重新采集图像、时间和显存数据。
