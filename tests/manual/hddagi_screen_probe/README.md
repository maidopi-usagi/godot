# HDDAGI Screen Probe Manual QA

这是一个独立、可重复运行的 Forward+ Vulkan 项目，用于验证 HDDAGI screen-probe estimator、NRD final denoise 和资源生命周期。它不参与 `tests/SCsub`，也不能替代正式视觉或辐射度验收。

## 场景

- `baseline`：temporal/spatial reuse 关闭，采集静止相机基线。
- `motion`：移动后停止，记录稳定性与 ghost proxy。
- `feature_off_toggle`：覆盖 screen probes on/off、temporal/spatial estimator 切换和恢复。
- `phase1_fresh`：reference mode 下扫描 1/2/4/8 fresh candidates，执行 analytic raw-HDR、energy/exposure 和生命周期门禁。
- `phase2_temporal`：验证 temporal reservoir、固定 ray budget、dynamic convergence、robust/age/TAA 和 GPU/CPU 合同。
- `phase3_spatial`：独立 runner 验证 spatial reservoir 的 temporal off/on 两种配置以及 NRD guide/final 路径。

基础 `all` 展开 `baseline`、`motion` 和 `feature_off_toggle`。八个旧专用假色 debug 视图已随旧管线删除；基础 `DEBUG_DRAW_HDDAGI_SCREEN_PROBES` 仍用于观察最终 NRD 输出（未接 NRD SDK 时为 raw fallback）。

## Windows PowerShell

```powershell
tests\manual\hddagi_screen_probe\run_qa.ps1 `
    -EditorPath bin\godot.windows.editor.dev.x86_64.console.exe `
    -Scenario all
```

Phase 1、2、3 使用各自 wrapper：

```powershell
tests\manual\hddagi_screen_probe\run_phase1_qa.ps1 `
    -EditorPath bin\godot.windows.editor.dev.x86_64.console.exe

tests\manual\hddagi_screen_probe\run_phase2_qa.ps1 `
    -EditorPath bin\godot.windows.editor.dev.x86_64.console.exe

tests\manual\hddagi_screen_probe\run_phase3_qa.ps1 `
    -EditorPath bin\godot.windows.editor.dev.x86_64.console.exe
```

## Linux/macOS

```bash
GODOT_BIN="$PWD/bin/godot.linuxbsd.editor.dev.x86_64" \
SCENARIO=all \
bash tests/manual/hddagi_screen_probe/run_qa.sh
```

Phase-specific shell wrappers are `run_phase1_qa.sh`、`run_phase2_qa.sh` 和 `run_phase3_qa.sh`。

## 输出与判定

runner 输出包含：

- 引擎、提交、renderer、GPU/API 与分辨率；
- cropped ROI 的均值、方差、相邻帧差异与 motion proxy；
- tagged screen-probe counter；
- SHARC Query 的 attempts/hits/ineligible/misses 守恒，以及 Update 的 rays/misses/rejects；
- 完整 console/engine log 扫描；
- GPU profile task 汇总；
- process-wide video/texture/buffer memory；
- manifest、validator、runner 和工作树 provenance。

Godot 与 tee 完全退出后，`validate_result.py` 或 `validate_phase3_result.py` 才决定最终退出码。默认产物写入已忽略版本控制的 `qa-results/`。

SHARC Query 的 `hits` 只在调用方真正采用 cache 并提前结束时计数，因此每个 snapshot 必须满足 `sharc_query_attempts = sharc_query_hits + sharc_query_ineligible + sharc_query_misses`。这条守恒同时防止把 cache-miss 条件误写成 early termination。`sharc_update_rays` 只统计实际发出的 update trace；miss 与 reject 互斥且两者之和不得超过 update rays，剩余量是成功写入的稳定 hit。

Phase 0/1/2 的硬件 manifests 已标记为 unbaselined：旧阈值来自被替换的自制降噪/缓存实现，不能作为 NRD/SHARC 的验收证据。CPU reference 和结构门禁仍会运行；恢复正式 acceptance 前必须重采目标硬件的图像、GPU 时间、显存和长时间稳定性。Phase 3 manifest 是 NRD-enabled build 的 portable structural smoke，仍不代表正式画质或性能 profile。

更多合同见 [PHASE1.md](PHASE1.md)、[PHASE2.md](PHASE2.md)、[PHASE3.md](PHASE3.md) 和 [PHASE3_QA.md](PHASE3_QA.md)。
