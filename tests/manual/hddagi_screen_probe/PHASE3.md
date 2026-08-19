# HDDAGI Screen Probe Phase 3：Spatial Reservoir

Phase 3 的第一道门禁是 `phase3_reference.py`。它定义 spatial reservoir stream merge 的可执行 CPU 合同，但不能单独证明 GPU pass、NRD 执行或图像质量。运行时门禁见 [PHASE3_QA.md](PHASE3_QA.md)。

## 当前图

```text
Surface Select
  -> Phase 2 Fresh Reservoir
  -> optional Phase 2 Temporal Stream Merge
  -> Phase 3 Spatial Stream Merge
  -> Raw Resolve (radiance + hit distance)
  -> NRD guide preparation
  -> NRD RELAX_DIFFUSE
  -> Apply
```

P3 只扩展 estimator 的 spatial stream merge。最终降噪由 NRD 负责，P3 不再拥有 moments、variance、temporal filter 或 edge-aware spatial filter。输出 alpha 保留 RELAX 所需的 hit distance；降噪结果不会回写 reservoir。

## CPU 合同

`phase3_reference.py` 覆盖：

- center 与邻域 stream 的确定性选择；
- receiver/endpoint identity、normal/depth、visibility 和版本拒绝；
- pairwise MIS/Jacobian、M cap、零 target mass 和 finite 守恒；
- spatial center/neighbor selection 与最大 M；
- 固定 float32/packing 路径和长时间 stress。

这些测试保留 estimator 的数学门禁，并与 NRD 的后处理职责分离。

## GPU smoke

`phase3_qa_runner.gd` 只跑 temporal off/on 两种 spatial 配置。两种配置都必须：

- 报告 `algorithm_mode=4` / `phase3_spatial_restir`；
- 有 fresh、spatial stream、visibility 和 selected output 活动；
- 满足 `hdda_rays = fresh + temporal visibility + spatial visibility + sharc_update_rays`；
- 所有 nonfinite/packing-invalid counter 为 0；
- 产生非黑、有限输出；
- 在启用 NRD 的正式构建中观察到 `HDDAGI NRD Guide Preparation`。

## 仍需完成的定量门禁

- 相对 Phase 2 的均值偏差与时空方差；
- thin-wall、法线/深度边界和动态遮挡；
- camera cut、resize、UPDATE_ONCE、multiview/XR；
- 1080p/4K 的逐 pass 时间、NRD/SHARC 显存峰值；
- 长时间 toggle 和资源生命周期；
- 新硬件 profile 的重新标定。
