# HDDAGI / NVIDIA RTX SDK 当前状态

## 权威边界

- 当前架构文档：`doc/hddagi_screen_probe_restir_implementation_plan.md`。
- 外部 SDK 构建与许可：`doc/nvidia_rtx_sdk_build.md`。
- 旧 World Reservoir Cache、单体 screen-probe shader、P2A/P3 自制降噪与 moments 已破坏性删除；不要从旧提交恢复其资源、参数、debug 或 QA schema。
- Temporal/spatial ReSTIR 仍是采样与 reservoir 复用，不承担显示降噪或持久世界 cache。

## 固定依赖

- NRD：`4.17.4`，commit `e76771e8ce7491532040fbd60c69e84efba44822`。
- SHARC：`1.8.3.0`，commit `4e21b585c33c83d723ca9a1e11bbb1090d145793`。
- NRD 需同时链接同次构建的 NRD 与 ShaderMakeBlob 静态库；Windows 当前只支持 MSVC/clang-cl x86_64，默认 Godot CRT 是 `/MT`。
- SDK 均为 NVIDIA RTX SDK 专有许可。SHARC 头会进入生成 shader 源码；公开发行前必须取得 NVIDIA/法务书面放行并补齐条款、notice、credits/marks。

## NRD

- Native API + Godot RenderingDevice，NRI off，RELAX diffuse，每 view 独立 instance/pool/history；已有 view 的 resize 复用尺寸无关的 instance/pipeline/UBO，只先释放再重建纹理池，避免双份工作集和重复编译。
- 运行时只放行 Vulkan/D3D12；当前仅 mono、非 reference。XR/multiview 使用 raw fallback。
- guide：world normal + linear roughness `RGBA8`、finite linear view-Z `R32F`、2.5D motion `RGBA16F`、demodulated diffuse radiance/hit distance `RGBA16F`。
- Forward+ 在 NRD 活动时强制 depth/normal/roughness/motion prepass；MSAA velocity 与 depth/normal 使用同一 best sample resolve。
- NRD projection 不带 Vulkan Y flip；previous NRD projection 单独保存；camera jitter 是 Godot projection jitter 的反号。
- 2.5D motion 的 previous view-Z 位于上一帧 jittered raster grid：`previousUv = uv + motion.xy + (currentJitter - previousJitter) / resourceSize`；current/previous jitter 由 guide UBO 显式传入。
- RELAX 前 RGB 除以 `exposureNormalization * 512` 并限 128，输出乘回；alpha hit distance 不缩放。
- resize 纹理池 OOM 时清掉 partial pool、使用 raw fallback 并保留 instance/pipeline 供后帧重试；其他 setup/dispatch 失败会清 context，并对当前 `RenderBuffersGI` sticky-disable。
- 从 mono 非 reference 切到 reference、multiview 或 sticky-disabled 状态时，立即清 NRD context 与 NRD named textures；回到支持模式后重建 history，不能把旧 pool 当热缓存常驻。
- Vulkan 原 NRD SPIR-V 通过未使用 `SpecId=0` 绕开 Godot eager re-SPIR-V 的 `OpPhi` 破坏；只在 Vulkan 且 blob 原本无 spec constant 时注入。

## SHARC

- 当前 Vulkan-only；D3D12 仍运行 NRD，但关闭 cache。开放 DX12 需原生 HLSL resource-binding ABI（`RWStructuredBuffer`，必要时 `ByteAddressBuffer`）与 GPU 验证。
- 要求 BDA、shader int64、buffer int64 atomics、float16 运算/storage；强制 64 位 atomic，不使用 lock fallback。Vulkan 1.2 的 BDA/float16 与 Vulkan 1.1 的 16-bit storage 均以 core feature 为准，不依赖 promoted extension 名称；float16 gate 不要求无关的 shaderInt16。
- 默认 `2^21` entries；hash 8 B + accumulation 16 B + resolved 16 B = `40 B/entry`，约 `80 MiB`。
- 每帧最多 16384 个随机 receiver update；64 帧最坏 live set 为默认容量的 50%。Resolve 后必须重跑稳定中心 Surface，再给 ReSTIR/trace 使用。
- Query 在昂贵 lighting fetch 前；短于 cache voxel 的 segment 不 early terminate；只替换 RGB，不改 hit-distance alpha。
- `hddagi_sharc_query_hit()` 返回 `true` 才表示缓存命中并可提前结束；返回 `false` 必须继续旧 voxel-light fetch，禁止对该条件取反。
- stats 9–15 已固定为 `sharc_query_attempts/hits/ineligible/misses` 与 `sharc_update_rays/misses/rejects`；Query hit 只在调用方实际 early termination 时计数，QA 要求 Query outcome 守恒，且 update misses+rejects 不超过 update rays。
- cache 保持 pre-exposed diffuse 域；scale 1000、sample 每通道 `<64`，最坏累加 `1,048,576,000`。饱和 sample 不写，query 拒绝饱和值。
- setup/upload/descriptor 失败会释放资源并对当前 render buffer sticky-disable。
- 进入 reference mode、运行时不支持或 sticky-disabled 时立即释放 SHARC cache 与参数 UBO；reference 退出后按空 history 重建，sticky-disabled 不重试。

## 已验证命令与结果

- 默认全量：`python -m SCons platform=windows target=editor dev_build=yes tests=no accesskit=no angle=no msvc_version=14.3 --jobs=8`，通过。
- SDK-enabled 命令见构建文档；Windows editor 全量编译/链接通过。
- SHARC 28 个变体与 NRD guide 已通过 Vulkan 1.1 / SPIR-V 1.4 `glslangValidator` + `spirv-val`。
- RTX 3080：Vulkan/D3D12 NRD 各 5 帧 smoke 通过；depth-motion prepass no-MSAA/4x-MSAA 通过。早期 Vulkan 600 帧/full QA 发生在最终 SHARC Query 条件修复前，只能作为 NRD/资源图稳定性证据，不能作为 SHARC 语义验收。
- 最终 unified binary 的 Vulkan baseline 完成 300 warmup + 300 sample：10/10 stats snapshot 满足 Query outcome、Update bound、expected rays 与 HDDA hit/miss 守恒；Query `15772/17406` 命中（90.61%，每个 snapshot 都非零），图像非黑、mean luma `0.464277`，runtime error 为 0。
- 同一最终 baseline 上 SHARC Update/Resolve timestamp 均值为 `0.13289/0.03078 ms`（640×360 internal，合计 `0.16367 ms`）；这是两个 pass 的直接成本，不是 SHARC on/off 公平 A/B 或净收益结论。
- 已知无关 validation：旧 sky 路径存在 cube view 与 cube-array 声明不匹配的 `VUID-07752`，NRD shader 仅使用 2D image，不属于本接入。

## 仍需补齐

- NVIDIA/AMD/Intel 图像 golden、NaN/Inf、1080p/1440p/4K 性能显存门禁与长期 soak。
- 同后端、同场景的 SHARC on/off GPU A/B；当前没有 runtime 开关，不能用跨构建/跨后端结果宣称净收益。
- 动态物体、动态光、天空、曝光阶跃、camera cut/resize/DRS 的定量图像回归。
- XR 需纯 per-eye projection + eye pose + 独立 history；D3D12 SHARC 需原生 HLSL 路径。
