# HDDAGI Screen Probe Phase 2：Temporal Reservoir

Phase 2 在 Phase 1 fresh-only estimator 上加入 temporal reservoir stream reuse。最终 full-resolution signal 不再经过项目内自制 temporal filter，而是统一交给 NRD RELAX_DIFFUSE。

## 运行时图

```text
Surface Select
  -> Phase 2 Fresh Reservoir
  -> Temporal Stream Merge
  -> Raw Resolve (RGB radiance + alpha hit distance)
  -> NRD guide preparation
  -> NRD RELAX_DIFFUSE
  -> Apply
```

`reference_mode=false`、temporal on、spatial off 时进入 `algorithm_mode=3` / `phase2_temporal_restir`。temporal off 使用 Phase 1 fresh production route；spatial on 进入 Phase 3。

## Estimator 合同

每个有效 surface 先生成一个 fresh vector-RIS stream。历史 stream 只有在以下条件全部满足时才参与 merge：

- history generation、owner、algorithm 和 packing version 一致；
- jitter-neutral reprojection 落在有效 previous footprint；
- receiver surface 与 endpoint identity 通过 normal/depth/version 校验；
- visibility ray 重新验证；
- Jacobian、age 和 M cap 均在配置范围内；
- target mass 和所有中间量有限。

最终 reservoir 只保存 estimator state，不读取 NRD 输出。NRD 是 estimator 之后的显示侧降噪器，不反馈到 fresh/temporal stream。

## QA

`phase2_reference.py` 保留 float32 stream、packing、permutation/compression、fresh RIS、temporal merge/M cap、hit/sky Jacobian、rejection/version、jitter-neutral reprojection、2×2 history footprint 和 1000-frame finite stress。

`phase2_temporal` GPU runner 保留：

- constant 与 colored steady-state 对比；
- P1 N=2 对 P2 N=1 + visibility 的固定 ray-budget 合同；
- dynamic blocker/light/sky convergence；
- robust Jacobian、age rejection、TAA stationary/motion/cut；
- camera cut、resize、`UPDATE_ONCE` 和 feature toggle；
- raw HDR、reservoir counter、schema digest、packing 与 nonfinite 门禁；
- Surface Select、P2 Fresh Reservoir、Temporal Stream Merge、Raw Resolve、NRD Guide Preparation 和 Apply 的 task 合同。

## 当前验收状态

`expected_phase2_metrics.json` 已显式标记为 unbaselined。旧 RTX 3080 图像和时间阈值是在被删除的自制 temporal filter 上采集的，不能外推到 NRD。CPU reference 与结构检查仍有效；只有重新完成目标硬件上的图像、性能、显存和长时间运行后，才能恢复正式 acceptance。
