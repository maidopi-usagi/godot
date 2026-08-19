# HDDAGI Screen Probes：NRD + SHARC 现行设计

> 状态：2026-08-19 实现版。旧 World Reservoir Cache、单体 screen-probe shader、P2A/P3 自制时空降噪和 moments 管线已经删除；旧方案只保留在 Git 历史中。

## 1. 目标与非目标

当前图只保留两类自研逻辑：

- HDDAGI screen-probe 的采样、几何关联与可选 temporal/spatial ReSTIR；
- Godot RenderingDevice 与 NVIDIA SDK 之间的资源、矩阵、同步和生命周期适配。

降噪由 NVIDIA NRD RELAX diffuse 负责，世界空间 radiance cache 由 NVIDIA SHARC 负责。TAA/FSR 仍位于最终显示链，它们不是 NRD 的替代对象。NRD 不替代 ray/sample producer；SHARC 也不替代 HDDAGI light-probe 数据。

本次破坏性替换不兼容旧 WRC 内部纹理、buffer、调参、debug 枚举、counter schema 或 QA profile。

## 2. 当前帧图

```text
Depth + normal/roughness + motion prepass
                     |
                     v
Screen-probe Surface Select
        |                         \
        |                          +--> SHARC random receiver Update
        |                               -> Resolve -> barrier
        |                               -> stable Surface Select
        v
Fresh / temporal / spatial ReSTIR trace
        |       ^
        |       +-- eligible secondary hit: SHARC Query early termination
        v
Geometry-only Raw Resolve
        |
        +--> NRD guide/signal conversion
        |       -> RELAX diffuse
        |
        +--> raw fallback when NRD is unavailable
        v
Ambient Apply -> existing TAA / FSR / composite
```

Reference mode 固定走 fresh raw 路径，并禁用 NRD、SHARC 和 ReSTIR history，用于 estimator/图像回归。非 reference 模式可保留 temporal/spatial ReSTIR，因为它们改变采样分布与 reservoir 复用，不再承担显示侧降噪或持久世界缓存职责。

## 3. 已删除的旧实现

- `hddagi_screen_probe.glsl` 与 `hddagi_screen_probe_inc.glsl` 单体图；
- World Reservoir Cache/IRCache 的 dense grid、payload pool、aux SH、free-list、reposition、query feedback 和 indirect-dispatch 资源；
- P1/P2A temporal filter、Phase 3 moments 与 edge-aware denoise；
- `screen_probe_surface_cache`、`screen_probe_phase3_denoise`、`screen_probe_world_reservoir_cache` 及旧 guided/cache 调参；
- WRC/cache/moments/自制 denoise 专用 debug、counter 和 QA 接受基线。

基础 `HDDAGI_SCREEN_PROBES` debug 保留，用于显示最终 NRD 输出或 raw fallback。旧 API/ProjectSettings 不留兼容壳，避免用户误以为仍在控制 production 路径。

## 4. NRD 接入合同

### 4.1 版本与实例

- 固定 NRD `4.17.4`，commit `e76771e8ce7491532040fbd60c69e84efba44822`；
- native NRD API，不使用 NRI；
- `RELAX_DIFFUSE`，每个 view 独立 instance、permanent/transient pool 和 history；
- 编译配置固定 `RGBA8_UNORM` normal、`LINEAR` roughness、embedded SPIR-V、quad intrinsics off；
- adapter 对 header/runtime 的 `4.17.4` 和编码做精确检查。

NRD 当前只在 Vulkan/D3D12 且单视图、非 reference 时运行。XR/multiview 先 raw fallback，因为 Godot 当前把 eye pose 折进 view-projection，而 NRD 会把 `viewToClip` 当纯投影分解。

### 4.2 Guide 与信号

专用 `hddagi_nrd_prepare.glsl` 生成：

| 资源 | 格式 | 合同 |
| --- | --- | --- |
| normal/roughness | `RGBA8_UNORM` | world-space normal；解开 Godot dynamic-bit；linear roughness；按 NRD helper 的 best-fit 方式打包 |
| view-Z | `R32F` | 正的 finite linear view distance；sky 写 `denoisingRange + 1` |
| motion | `RGBA16F` | `prev_uv = current_uv + mv.xy`；`.z = previousViewZ - currentViewZ` |
| noisy diffuse | `RGBA16F` | RGB 非负、finite、receiver-albedo demodulated；alpha 是 raw diffuse hit distance |
| output diffuse | `RGBA16F` | sampled + storage；与 input 不能是同一 RID |

HDDAGI screen-probe raw 存的是 receiver-albedo 之前的 diffuse irradiance-over-pi，因此可作为 demodulated diffuse 信号；Forward+ 只在最终材质阶段乘一次 receiver albedo。primary emissive 不混入这个 signal。

RELAX 用 FP16 二阶矩。输入 RGB 从现有 pre-exposed 域除以 `exposureNormalization * 512` 并限到 128，NRD 后乘回同一因子；hit-distance alpha 不缩放。非有限值在进入 SDK 前清零。

### 4.3 矩阵、jitter 与 history

- NRD `viewToClip` 使用 non-jittered、D3D depth-style correction，但不带 Vulkan raster Y flip；
- `worldToView` 使用当前/上一帧 camera inverse；
- NRD previous projection 与 Godot raster/temporal projection分开保存；
- Godot jitter 是 projection translation，NRD `cameraJitter` 是 sample offset，因此符号相反；
- previous view-Z 位于上一帧 jittered raster grid；2.5D motion 的采样坐标显式使用 `uv + mv.xy + (currentJitter - previousJitter) / resourceSize`，不能只使用 non-jittered velocity；
- presentation `frameIndex` 使用 render-buffer-local 连续 sequence，不使用可能跳变的全局 frame；
- camera cut、resize、配置变化或 guide 语义变化使用 `CLEAR_AND_RESTART`。

### 4.4 Pre-opaque motion

HDDAGI 在 opaque color pass 前运行，不能读取该 pass 尚未写入的 velocity。Forward+ 因此在 mono NRD 活动时强制 depth/normal/roughness/motion prepass，并增加对应 mono/multiview、VoxelGI shader variant。velocity 固定在 MRT location 2。

MSAA 下不能使用晚期平均 velocity；`resolve_gi` 从与 depth/normal 相同的 best-depth sample 读取 velocity，确保三个 guide 属于同一表面。

### 4.5 失败回退

已有 view 的 resize 复用尺寸无关的 NRD instance、pipeline 与 constant buffer；先释放旧 permanent/transient pool，再创建新尺寸纹理，因此不会由 adapter 同时持有两套完整工作集，也不会因分辨率变化重新编译 RELAX。后端可能延迟实际销毁旧纹理，所以新 pool 仍可能 OOM；此时清掉所有 partial pool、当帧使用 raw GI，并保留已有 instance/pipeline 供后帧重试，成功后以 `CLEAR_AND_RESTART` 恢复。首次创建 pool OOM 同样使用 raw fallback 并后帧重试，但尚无旧 instance/pipeline 可保留。

从 mono 非 reference 切到 reference、XR/multiview 或 sticky-disabled 状态时，会立即清 NRD context 与 NRD named textures；再次回到支持模式时重建 history，避免全分辨率 guide/output 和 RELAX pool 作为无用热缓存长期占用显存。

除上述可恢复的 resize pool OOM 外，任一 format、pipeline、descriptor、constant upload 或 dispatch 失败时：

1. 当帧使用 raw GI；
2. 清 NRD instance/history；
3. 对当前 `RenderBuffersGI` 设置 sticky disable；
4. 后续帧不再创建 guide 或重复编译/分配；
5. render-buffer 上下文重建后才允许再次探测。

Vulkan 下 NRD 4.17.4 的合法 SPIR-V 曾被 Godot eager re-SPIR-V 破坏嵌套 `OpPhi` 前向引用。adapter 只在 Vulkan、且原 blob 没有 specialization constant 时注入未使用的 `SpecId=0`，让驱动保留原模块；D3D12 不走此 workaround。

## 5. SHARC 接入合同

### 5.1 支持范围

- 固定 SHARC `1.8.3.0`，commit `4e21b585c33c83d723ca9a1e11bbb1090d145793`；
- 当前只支持 Vulkan；
- 必须具备 buffer device address、shader int64、buffer int64 atomics 和 16-bit float/storage；
- D3D12 继续使用 NRD，但不创建 SHARC cache。

SHARC 官方包含 HLSL 能力，D3D12 限制来自本适配器当前直接使用 GLSL buffer-reference/BDA ABI。开放 D3D12 前必须实现并验证原生 HLSL resource-binding ABI（`RWStructuredBuffer`，必要时 `ByteAddressBuffer`）、布局、64 位原子和 barrier 路径，不能只解除一个 backend 判断。

### 5.2 资源与原子

每个 `RenderBuffersGI` 拥有一个 cache：

| Buffer | 每 entry |
| --- | ---: |
| hash | 8 B |
| accumulation | 16 B |
| resolved | 16 B |

默认 `2^21` entries，共 `40 B/entry`，约 `80 MiB`。实现强制官方 64 位 atomic 路径；不使用有高争用未初始化风险的 lock fallback，也不分配旧的 8 MiB lock buffer。

### 5.3 Update / Resolve / Query

- 每帧最多选择 16384 个 probe update；选择按 frame 轮转。配合 64 帧 stale 窗口，最坏 live set 不超过默认表容量的 50%，给线性 probing 留出碰撞余量；
- update Surface 在每个 tile 内跨帧随机选 receiver，避免永远只 seed tile 中心；
- Update/Resolve 完成后，无条件再执行一次稳定中心 Surface，ReSTIR/trace 不消费随机 receiver；
- Query 在 HDDA 命中后、昂贵 lighting fetch 前执行；segment 短于 cache voxel 时不允许 early terminate；
- Query 只替换 hit RGB，保留现有 hit-distance alpha 语义；
- stats slots 9–15 记录 Query attempts/hits/ineligible/misses 与 Update rays/misses/rejects；`hits` 只在调用方实际提前结束时增加，并以 `attempts = hits + ineligible + misses` 作 QA 守恒；
- camera cut、资源/transport 配置变化会清 cache；普通同容量 configure 保留 history。

cache 使用 Forward+ 当前 pre-exposed diffuse 域，不做第二次 exposure transform。定点 `radianceScale=1000`，每选中 probe 一次 add、单通道样本严格小于 64：

```text
16384 * 64 * 1000 = 1,048,576,000 < UINT32_MAX / 2
```

量化步长为 0.001。任一通道 `>=64` 的极端 HDR sample 不进入 cache，Query 也拒绝饱和值；这避免 wrap 和永久截断。已知边界是动态光从非饱和跃迁到饱和时，已有旧 entry 在 stale 回收前可能短暂保留，因此这一阈值不是通用 HDR tone mapping。

SHARC setup/descriptor/upload 失败同样对当前 render buffer sticky-disable，释放三组 buffer 与参数 UBO，随后使用无 cache 路径。

## 6. RenderingDevice 同步与生命周期

- SHARC Update 所有 view 完成后 barrier，再 Resolve 一次，再 barrier 后 Query；
- NRD 每个 SDK dispatch 后有显式 compute barrier，包括 UAV→UAV；
- NRD dispatch constants 在 compute list 开始前全部上传，active list 中不调用 `buffer_update`；
- output texture 同时声明 sampling/storage，因为 RELAX 会先写 output，后续 pass 再把它作为 SRV；
- disable、resize 和 render-buffer 销毁会清 SDK instance/buffer/UBO；
- unsupported backend/device 不创建 SDK 资源。

## 7. 构建、许可与发行

SDK 不 vendor 到 MIT Godot 源码树。构建选项、固定 CMake 配置、后端矩阵和失败诊断见 `doc/nvidia_rtx_sdk_build.md`。

NRD/SHARC 使用 NVIDIA RTX SDK 专有许可证。object-code 分发存在有条件授权，但当前 SHARC 头会内联进生成 shader 源码；本项目政策是在 NVIDIA 与法务书面放行、下游保护条款、notice、credits/marks 全部落地前，只作私有开发接入。

## 8. 验收门禁

已经完成的基础验证：

- 无 SDK Windows x86_64 editor 全量编译/链接；
- NRD+SHARC Windows x86_64 editor 全量编译/链接；
- 28 个 SHARC Phase1/2/3 shader variant、NRD guide shader 的 `glslangValidator` + `spirv-val`；
- RTX 3080 Vulkan 与 D3D12 NRD 5-frame smoke；
- Vulkan NRD 600-frame/full QA（发生在最终 SHARC Query 条件修复前，只作为 NRD/资源图稳定性证据）；
- 最终 unified binary 的 RTX 3080 Vulkan baseline：300 warmup + 300 sample、10/10 SHARC Query/Update/ray 守恒 snapshot 通过，Query `15772/17406` 命中，图像非黑且 runtime error 为 0；
- 该 baseline 的 SHARC Update/Resolve 直接成本均值为 `0.13289/0.03078 ms`（640×360 internal）；尚未完成同后端 SHARC on/off 公平 A/B，不能据此宣称净收益；
- Vulkan depth-motion prepass 的 no-MSAA 与 4x-MSAA 路径；
- Python/JSON/XML/GDScript 静态与 headless parse 检查。

发布前仍必须补齐：

- NVIDIA/AMD/Intel 的固定图像 golden 与 NaN/Inf validation；
- 1080p、1440p、4K 的 GPU time/VRAM budget；
- 同后端、同场景的 SHARC on/off GPU A/B 与可配置运行时预算；
- camera translation/rotation/cut、动态物体、动态光、天空与手动曝光阶跃的图像回归；
- Vulkan 与 D3D12 的长期 soak；
- 若实现 XR，必须先传递纯 per-eye projection 与完整 eye pose，再建立独立 per-eye NRD history；
- 若实现 D3D12 SHARC，必须新增原生 HLSL 路径和专门的 GPU ABI 测试。
