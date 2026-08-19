# 外部 NVIDIA NRD 与 SHARC SDK 构建接入

本仓库不包含、下载或默认依赖 NVIDIA NRD/SHARC 源码。两项集成都采用显式 opt-in：未传入下列 SCons 选项时，不增加 NVIDIA 头文件、库、宏或 shader include 路径；全局 shader builder 虽支持新的可选外部 include 指令，但不会加载 NVIDIA 内容。

使用 SDK 前请自行取得并审阅 [NRD 许可证](https://raw.githubusercontent.com/NVIDIA-RTX/NRD/e76771e8ce7491532040fbd60c69e84efba44822/LICENSE.txt) 与 [SHARC 许可证](https://raw.githubusercontent.com/NVIDIA-RTX/SHARC/4e21b585c33c83d723ca9a1e11bbb1090d145793/License.md)。不要把 SDK 源码或 shader 头文件复制到本仓库。两份 RTX SDK 许可证授予在满足条件时把 SDK 材料以 object code 并入有实质额外功能的应用后再分发的权利，同时要求保护性下游条款、NVIDIA notice/credits/marks 等；本项目没有自动生成这些发行材料。当前 Godot shader 流程还会把 SHARC 头文件内联进运行时 shader 源码，其是否属于许可允许的 object-code 分发需要书面澄清。因此本项目采取更保守的发行政策：在 NVIDIA 与法务书面放行前仅作私有开发接入，不公开分发包含这些 SDK 的源码或二进制。许可问题联系 `nvidia-rtx-license-questions@nvidia.com`。

## 固定版本

- NRD 必须固定为 `4.17.4`、commit `e76771e8ce7491532040fbd60c69e84efba44822`。
- SHARC 必须固定为 `1.8.3.0`、commit `4e21b585c33c83d723ca9a1e11bbb1090d145793`。

不要跟随浮动的 `master`。NRD headers、`NRD` 静态库和 `ShaderMakeBlob` 静态库必须来自同一个固定提交和同一次 CMake 构建；适配层会同时做编译期与运行期的精确 `4.17.4` 检查，避免无类型 settings 指针在 patch 版本混用时产生 ABI 错读。SCons 无法从静态库反推出 Git SHA，也不能证明两个 archive 来自同一次构建；这部分是调用方/CI 的 provenance 约束，应通过锁定的 SDK checkout、构建清单和产物校验和保证。SHARC 会在配置阶段核对 `1.8.3.0` 四段版本宏，但 commit SHA 同样由调用方锁定。

## 构建选项

| 选项 | 默认值 | 作用 |
| --- | --- | --- |
| `nrd_sdk_path` | 空 | NRD SDK 根目录；必须包含 `Include/NRD.h`。 |
| `nrd_static_library` | 空 | 已构建的 NRD 静态库完整路径；Windows MSVC/clang-cl 必须是 `.lib`，Linux 必须是 `.a`。 |
| `nrd_shadermake_static_library` | 空 | 同一次 NRD 构建产出的 ShaderMakeBlob 静态库完整路径。 |
| `sharc_sdk_path` | 空 | SHARC SDK 根目录；必须包含当前官方仓库的 `include/SharcCommon.h` 等 shader 头文件。 |

三个 NRD 选项必须一起提供。少提供任意一项都会让 SCons 立即以清楚的错误退出。嵌入 SPIR-V 的 NRD 静态库仍引用 ShaderMakeBlob 中的符号，仅链接 `NRD.lib`/`libNRD.a` 会在最终链接时报未解析符号。`sharc_sdk_path` 可独立使用，因为 SHARC 是 shader-only SDK。

相对路径以运行 SCons 的仓库根目录为基准；为避免 CI、Ninja 和 IDE 工作目录差异，推荐使用绝对路径。当前外部 SDK 接入只允许 `platform=windows` 和 `platform=linuxbsd`。NRD 进一步只放行已验证的 `x86_64`；Windows 静态库 ABI 只支持 MSVC/clang-cl，`use_mingw=yes` 会在配置阶段明确失败。`linuxbsd` 是 Godot 的平台族名称，不代表本接入已验证所有 BSD/CPU 组合：当前实测矩阵只有 Windows x86_64 与 Linux x86_64。SHARC 本身是 shader-only SDK，不受 NRD 静态库限制，但当前适配器要求 `vulkan=yes`，其他 CPU/OS 组合仍属于未验证。

## 准备 SDK

NRD 静态库必须由与目标平台、架构、编译器 ABI 和构建配置兼容的工具链生成，并在 NRD CMake 配置中使用：

```text
NRD_STATIC_LIBRARY=ON
NRD_NRI=OFF
NRD_EMBEDS_SPIRV_SHADERS=ON
NRD_EMBEDS_DXIL_SHADERS=OFF
NRD_EMBEDS_DXBC_SHADERS=OFF
NRD_SUPPORTS_QUAD_INTRINSICS=OFF
NRD_NORMAL_ENCODING=0
NRD_ROUGHNESS_ENCODING=1
```

Godot 的 `nrd_sdk_path` 应指向包含 `Include/NRD.h` 的 SDK 根目录；两个静态库可以位于该根目录之外。SCons 不能区分 Windows `.lib` 是静态库还是 import library，调用方必须确保两者均来自同一次静态 NRD 构建。

Windows 的 Godot 默认使用 `/MT`，包括普通 `target=debug` 构建；NRD 和 ShaderMakeBlob 必须用相同 CRT，例如给 CMake 传入 `-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`。只有显式设置 Godot 的 `debug_crt=yes` 时才会切到 `/MDd`，此时两个 SDK 静态库也必须用 `MultiThreadedDebugDLL` 重建。不要混用 `/MT`、`/MD` 或 `/MDd`，否则最终链接会报运行库不匹配。

SHARC 使用官方仓库根目录，预期布局为：

```text
SHARC/
  include/
    HashGridCommon.h
    HashGridTypes.h
    SharcCommon.h
    SharcGlslHelpers.h
    SharcTypes.h
```

## Windows 示例

PowerShell：

```powershell
scons platform=windows d3d12=yes `
  nrd_sdk_path="D:/NVIDIA/NRD/_NRD_SDK" `
  nrd_static_library="D:/NVIDIA/NRD/lib/NRD.lib" `
  nrd_shadermake_static_library="D:/NVIDIA/NRD/lib/ShaderMakeBlob.lib"
```

上述 D3D12 构建只会启用 NRD。若要同时启用 SHARC，必须构建并运行 Vulkan 后端：

```powershell
scons platform=windows vulkan=yes `
  nrd_sdk_path="D:/NVIDIA/NRD/_NRD_SDK" `
  nrd_static_library="D:/NVIDIA/NRD/lib/NRD.lib" `
  nrd_shadermake_static_library="D:/NVIDIA/NRD/lib/ShaderMakeBlob.lib" `
  sharc_sdk_path="D:/NVIDIA/SHARC"
```

## Linux 示例

```bash
scons platform=linuxbsd vulkan=yes \
  nrd_sdk_path=/opt/nvidia/nrd/_NRD_SDK \
  nrd_static_library=/opt/nvidia/nrd/lib/libNRD.a \
  nrd_shadermake_static_library=/opt/nvidia/nrd/lib/libShaderMakeBlob.a \
  sharc_sdk_path=/opt/nvidia/sharc
```

也可只开启其中一项，例如只使用 SHARC：

```bash
scons platform=linuxbsd sharc_sdk_path=/opt/nvidia/sharc
```

## 构建环境变化

NRD 开启后，SCons 会：

- 校验 SDK 根、`Include/NRD.h`、`Include/NRDDescs.h`、`Include/NRDSettings.h` 和指定静态库；
- 把 `<NRD SDK>/Include` 加入 C++ include path；
- 按顺序链接 NRD 与 ShaderMakeBlob 两个静态库文件；
- 定义 `NRD_STATIC_LIBRARY` 与 `NVIDIA_NRD_ENABLED`。

SHARC 开启后，SCons 会：

- 校验所有必需 shader 头文件；
- 定义 `NVIDIA_SHARC_ENABLED`；
- 把 `<SHARC SDK>/include` 加入 `RD_GLSL`/`GLSL_HEADER` 的外部 include 搜索路径。

外部 SDK 头文件必须使用专用的 `#include_external` 指令，例如：

```glsl
#include_external "SharcGlslHelpers.h"
#include_external "SharcCommon.h"
```

启用 SHARC 后，GLSL builder 对顶层 `#include_external` 只搜索显式外部 include 根，不搜索 shader 所在目录或仓库根，避免仓库内同名文件遮蔽已校验的 SDK。进入外部头文件后，其中的普通 `#include` 仍会先按头文件所在目录递归解析。外部头文件及其递归 include 会登记为 SCons 依赖，SDK 头文件变化后，相应的 `.glsl.gen.h` 会重新生成。缺失 include 时，错误会列出发起 include 的文件及所有已搜索路径。

没有配置任何外部 shader include 路径时，`#include_external` 所在整行会从生成结果中剔除，也不会尝试打开该文件。普通 `#include` 始终保持严格行为：无论功能宏或预处理分支是否启用，找不到文件都会让构建失败。这样可以安全地把可选 SDK include 放在 shader feature guard 附近，而不会掩盖本仓库普通 include 的拼写或依赖错误。

`NVIDIA_NRD_ENABLED` 和 `NVIDIA_SHARC_ENABLED` 仅在对应 SDK 校验成功后定义。平台运行时能力检查和不支持平台上的功能回退仍需由渲染器实现。

## 运行时支持与回退

| 功能 | Vulkan | D3D12 | 其他 RD / Compatibility |
| --- | --- | --- | --- |
| NRD RELAX diffuse | 支持；mono、非 reference | 支持；mono、非 reference | 禁用并使用 raw GI |
| SHARC hash-grid cache | 支持；非 reference，但必须满足下述能力 | 当前禁用 | 禁用 |

SHARC 官方算法并非不能运行在 D3D12；这里的限制来自当前 Godot 适配实现。现实现直接使用 GLSL buffer-reference/BDA、shader int64、buffer int64 atomics 与 16-bit storage，尚未为 Godot 的 SPIR-V→DXIL 路径建立等价且经过 GPU 验证的原生 HLSL resource-binding ABI（`RWStructuredBuffer`，必要时 `ByteAddressBuffer`）。因此 D3D12 会继续使用 NRD，但不创建或查询 SHARC 缓存。后续若开放 D3D12，必须先增加原生 HLSL 资源访问路径，并分别验证地址、64 位原子、barrier 和布局。

Vulkan SHARC 运行时要求：

- buffer device address；
- shader int64 与 buffer int64 atomics；
- 16-bit float/storage 支持。

缺任一能力都会关闭 SHARC，并保留无缓存的 HDDAGI 路径。默认 SHARC 容量为 `2^21` entries，使用 hash、accumulation、resolved 三个 buffer，共 `40 B/entry`，即约 `80 MiB`；64 位原子路径不分配旧 lock buffer。

NRD 当前只对单视图启用。XR/multiview 的 Godot view-projection 会把眼位姿折进投影矩阵，不能作为 NRD 所要求的纯 `viewToClip` 分解；多视图因此使用 raw GI 回退。NRD 还要求本帧 motion vector、world-space normal/linear roughness、finite linear view-Z 和正确的 radiance/hit-distance 域。Forward+ 为此在 HDDAGI+NRD 时强制 depth/normal/roughness/motion prepass，MSAA velocity 使用与 depth/normal 相同的最佳样本 resolve。

每个 render buffer 已有 view 的 resize 会复用尺寸无关的 NRD instance/pipeline/constant buffer，并在创建新尺寸纹理前释放两组旧 pool，避免 adapter 同时持有双份工作集或重新编译 RELAX。若 pool 分配 OOM，则清 partial pool、当帧回退 raw GI，并在已有 view 时保留 instance/pipeline 供后帧重试；首次创建 OOM 也会后帧重试。这兼容后端延迟实际回收旧纹理的情况。其他 NRD setup/dispatch 失败会熔断该上下文的后续重试，重建 render-buffer 上下文后才会重新尝试。TAA/FSR 仍保留，它们不是 NRD 的替代对象。
