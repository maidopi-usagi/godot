# Phase 3 Forward+ Vulkan Runtime Smoke

`run_phase3_qa.ps1` 和 `run_phase3_qa.sh` 是 Phase 3 的独立运行时入口。runner 继承基础场景的采图、ROI 指标、日志、counter tag、GPU profile 和原子 JSON 发布逻辑，只补充 spatial reservoir 路径的配置矩阵。

这项门禁验证 P3 spatial route、NRD guide 准备、counter 守恒和有限输出；它不是辐射度、方差、性能或显存的正式硬件 profile。

## 固定合同

scene 固定使用 Forward+、Vulkan、640×360、TAA off。两种配置都固定：

```text
reference mode       off
spatial ReSTIR       on
fresh candidates     1
robust Jacobian      off
spatial radius       2
normal threshold     0.45
depth tolerance      0.01 + 0.01 * |depth|
```

依次运行：

| Segment | Temporal ReSTIR |
|---|---:|
| `temporal_off` | off |
| `temporal_on` | on |

所有 counter snapshot 必须是 `algorithm_mode=4` / `phase3_spatial_restir`。feature flags 分别为 65 和 67。最终图像由 NRD RELAX_DIFFUSE 处理；启用 NVIDIA NRD 的正式构建还必须在 GPU profile 中观察到 `HDDAGI NRD Guide Preparation`。未接 NRD SDK 的构建只能作为 raw fallback 诊断，不能通过本 manifest。

## 运行

Windows PowerShell：

```powershell
tests\manual\hddagi_screen_probe\run_phase3_qa.ps1 `
    -EditorPath bin\godot.windows.editor.dev.x86_64.console.exe
```

Linux/macOS：

```bash
GODOT_BIN="$PWD/bin/godot.linuxbsd.editor.dev.x86_64" \
bash tests/manual/hddagi_screen_probe/run_phase3_qa.sh
```

默认使用真实 display server。只有确认环境可创建 Vulkan RenderingDevice 时才使用 headless。

## Post-exit 门禁

Godot 和 tee 完全退出后，`validate_phase3_result.py` 才给出最终退出码。它验证：

- runner schema/suite、完整 console/engine log、Engine hash 和 provenance；
- Forward+、Vulkan、两种配置状态和非黑有限输出；
- CPU reference 的 float32 reservoir/spatial stream 合同；
- 每个 sample segment 的 mode 4 counter、ray/visibility 守恒、spatial stream 活动和 temporal on/off 语义；
- SHARC Query 的 attempts/hits/ineligible/misses 守恒，`update_misses + update_rejects <= update_rays`，并把 update rays 纳入 HDDA 总 ray 守恒；
- `raw_hdr_nonfinite_or_overflow`、`reservoir_nonfinite`、`reservoir_packing_invalid` 和 `spatial_nonfinite` 均为 0；
- GPU profile 观察到 Surface Select、P2 Fresh/Temporal Stream Merge、P3 Spatial Stream Merge、Raw Resolve 和 NRD Guide Preparation。

默认产物写入已忽略版本控制的 `qa-results/`。定量均值/方差、薄墙与动态边缘、camera cut/resize/UPDATE_ONCE/multiview、长时间 toggle、1080p/4K/XR、逐 pass 时间和显存预算仍需在新 NRD/SHARC 管线下重新标定。
