# Godot ReSTIR GI 实施进度跟踪

## 项目概述
在Godot 4引擎的SDFGI基础上实现ReSTIR混合追踪的高精度全局光照系统。

## 完成的工作

### 第一阶段: 架构设计与核心结构 ✅

#### 1.1 分析Godot SDFGI现有架构 ✅
- **位置**: `servers/rendering/renderer_rd/environment/gi.h`
- **关键发现**:
  - SDFGI作为`RenderBufferCustomDataRD`的子类
  - 使用级联体素结构 (最多8级, 每级128³)
  - 已有光探针系统 (八面体采样)
  - 集成在`RendererSceneRenderRD`渲染管线中
  - 支持动态光照和静态光照分离

#### 1.2 创建ReSTIR GI核心类 ✅
- **文件**: `servers/rendering/renderer_rd/environment/restir_gi.h`
- **文件**: `servers/rendering/renderer_rd/environment/restir_gi.cpp`

**关键设计决策**:
1. **继承自`RenderBufferCustomDataRD`**: 与SDFGI保持一致的架构模式
2. **质量模式**: 三档质量设置 (Performance/Quality/Cinematic)
3. **多次反弹支持**: 关闭/缓存/APV三种模式
4. **混合追踪**: 同时支持屏幕空间和世界空间追踪

**实现的数据结构**:
- `Settings`: 配置参数集合
- `GBufferTextures`: 法线/深度/漫反射/运动矢量
- `TracingTextures`: 光线方向/击中距离/辐射度/体素负载
- `RadianceCacheBuffers`: 哈希表缓存系统
- `ReSTIRBuffers`: 水库采样缓冲区

**实现的方法骨架**:
- 资源分配与释放
- 主渲染管线入口点 (GBuffer/追踪/ReSTIR/降噪/合成)
- 调试可视化接口

### 第二阶段: GBuffer系统与基础Shader ✅

#### 2.1 GBuffer降采样Shader ✅
- **文件**: `servers/rendering/renderer_rd/shaders/environment/restir_gbuffer.glsl`
- **功能模式**:
  - `MODE_DOWNSAMPLE_NORMAL_DEPTH`: 法线和深度降采样到探针分辨率
  - `MODE_DOWNSAMPLE_DIFFUSE`: 漫反射颜色降采样
  - `MODE_BUILD_DEPTH_PYRAMID`: 构建层级深度金字塔 (用于HiZ加速)
  - `MODE_EXTRACT_MOTION_VECTORS`: 提取/计算运动矢量

**技术细节**:
- **复用Godot内部Buffer**: 直接读取`normal_roughness` (Octahedral编码) 和 `depth` buffer，避免重复渲染。
- 2x2邻域采样保证质量
- 法线权重归一化
- 深度金字塔使用最大深度 (保守遮挡)
- 支持深度重投影计算运动矢量

#### 2.2 光线生成Shader ✅
- **文件**: `servers/rendering/renderer_rd/shaders/environment/restir_ray_gen.glsl`
- **采样策略**:
  - Blue Noise分布 (时间稳定性)
  - 余弦加权半球采样
  - 重要性采样 (基于BRDF)
  - PCG随机数生成器

**特性**:
- 支持三种质量模式的探针分辨率
- 每帧随机种子偏移实现时间抗锯齿
- 切线空间构建实现正确的半球采样
- 输出光线方向+长度 (packed in RGBA16F)

#### 2.3 屏幕空间追踪Shader ✅
- **文件**: `servers/rendering/renderer_rd/shaders/environment/restir_screen_trace.glsl`
- **算法实现**:
  - 层级深度金字塔追踪 (HiZ)
  - 自适应步长控制
  - 二分搜索精确化
  - 屏幕边界裁剪

**优化技术**:
- Jitter起点减少伪影
- 早期退出优化
- 可配置厚度阈值
- View-space射线转换

## 待实施任务

### 第三阶段: 世界空间体素追踪 ✅
- [x] 3.1 创建屏幕空间追踪shader基础 ✅
- [x] 3.2 实现世界空间DDA体素遍历 ✅
  - **文件**: `servers/rendering/renderer_rd/shaders/environment/restir_world_trace.glsl`
  - **算法**: Sphere Tracing (针对SDF优化)
  - **特性**:
    - 级联SDF纹理采样
    - 自动LOD选择
    - 正确的SDF解码 (`(val * 255 - 1) / scale`)
    - 光照评估集成

- [x] 3.3 SDFGI数据复用研究 ✅
  - **发现**: SDFGI使用`R8_UNORM`存储SDF
  - **解码公式**: `dist_cells = texture.r * 255.0 - 1.0`
  - **世界距离**: `dist_world = dist_cells / to_cell_scale`
  - **光照数据**: 可通过`light_cascades`纹理访问

### 第四阶段: 辐射度缓存系统 ✅
- [x] 4.1 实现哈希表结构 ✅
  - **文件**: `servers/rendering/renderer_rd/shaders/environment/restir_radiance_cache.glsl`
  - **结构**:
    - 线性探测哈希表 (Linear Probing)
    - 键值: `hash(position) ^ hash(normal)`
    - 负载: 辐射度 + 计数器
  - **特性**:
    - 自动衰减与回收机制
    - 原子操作保证线程安全
    - 分帧更新策略 (每帧更新1/10)

- [x] 4.2 集成到C++管线 ✅
  - **文件**: `servers/rendering/renderer_rd/environment/restir_gi.cpp`
  - **实现**:
    - `update_radiance_cache` 方法
    - Shader编译与Pipeline创建
    - 资源管理与释放

### 第五阶段: ReSTIR采样实现
- [ ] 5.1 初始采样
  - [ ] 文件: `restir_initial_sampling.glsl`
  - [ ] 候选样本生成
  - [ ] RIS初始权重计算

- [ ] 5.2 时间重采样
  - [ ] 文件: `restir_temporal_resampling.glsl`
  - [ ] 运动矢量重投影
  - [ ] 水库合并算法
  - [ ] M值更新

- [ ] 5.3 空间重采样
  - [ ] 文件: `restir_spatial_resampling.glsl`
  - [ ] 邻域采样策略
  - [ ] 空间水库合并
  - [ ] 偏差校正

### 第六阶段: 时空降噪
- [ ] 6.1 时间累积
  - [ ] 文件: `temporal_denoiser.glsl`
  - [ ] 自适应时间权重
  - [ ] 历史缓冲管理
  - [ ] 鬼影抑制

- [ ] 6.2 空间滤波
  - [ ] 边缘感知滤波
  - [ ] 法线/深度权重
  - [ ] 多尺度滤波

### 第七阶段: 管线集成与合成
- [ ] 7.1 集成到主渲染循环
  - [ ] 修改`renderer_scene_render_rd.cpp`
  - [ ] 在正确的渲染阶段调用ReSTIR GI
  - [ ] 与SDFGI协同工作 (可选)

- [ ] 7.2 GI合成
  - [ ] 最终颜色混合
  - [ ] 间接光照应用
  - [ ] 与直接光照结合

### 第八阶段: 调试与可视化
- [ ] 8.1 实现调试模式
  - [ ] GBuffer可视化
  - [ ] 体素颜色/光照显示
  - [ ] 光线方向可视化
  - [ ] 辐射度缓存热力图

- [ ] 8.2 性能分析工具
  - [ ] GPU时间测量
  - [ ] 内存使用统计
  - [ ] 光线统计信息

### 第九阶段: 优化与测试
- [ ] 9.1 性能优化
  - [ ] GPU调度优化
  - [ ] 内存访问优化
  - [ ] 波前占用率分析
  - [ ] 异步计算利用

- [ ] 9.2 场景测试
  - [ ] 室内场景测试
  - [ ] 室外大场景测试
  - [ ] 动态物体测试
  - [ ] 极端情况测试

- [ ] 9.3 质量调优
  - [ ] 参数平衡
  - [ ] 降噪强度调节
  - [ ] 偏差vs方差权衡

## 技术挑战

### 已识别的风险
1. **SDFGI数据格式兼容性**: SDFGI的SDF表示可能需要转换为适合光线追踪的格式
2. **性能瓶颈**: 哈希表更新和ReSTIR采样可能成为性能热点
3. **时间稳定性**: 需要仔细调优以避免闪烁和鬼影
4. **内存占用**: 完整实现可能消耗1GB+显存

### 应对策略
1. **分阶段测试**: 每完成一个模块立即测试
2. **性能剖析**: 使用RenderDoc/NSight分析每个Pass
3. **回退方案**: 保留简化版本以应对性能问题
4. **质量档位**: 提供多档质量设置以适应不同硬件

## 构建说明

### 编译配置
构建系统需要更新以包含新文件:
```python
# servers/rendering/renderer_rd/SCsub
env_rd.add_source_files(env.servers_sources, "environment/restir_gi.cpp")
```

### Shader编译
所有GLSL shader需要通过Godot的shader编译流程:
- 放置在: `servers/rendering/renderer_rd/shaders/environment/`
- 命名规范: `restir_*.glsl`
- 通过SCons自动生成`.gen.h`头文件

## 参考资料

### Unity HTrace原始实现
- 位置: `/Volumes/External/Projects/code/unity_srp/UnitySRP/`
- 关键文件:
  - `HTraceWSGI.cs` - 主控制器
  - `HPipeline.cs` - 管线逻辑
  - Compute Shaders: Voxelization, Tracing, ReSTIR, Denoiser

### Godot引擎源码
- SDFGI实现: `servers/rendering/renderer_rd/environment/gi.cpp`
- Forward渲染器: `servers/rendering/renderer_rd/forward_clustered/`
- RenderingDevice API: `servers/rendering/rendering_device.h`

### 学术论文
- "Spatiotemporal reservoir resampling for real-time ray tracing with dynamic direct lighting" (SIGGRAPH 2020)
- "ReSTIR GI: Path Resampling for Real-Time Path Tracing" (HPG 2021)

## 下一步行动

**立即任务**: 实现ReSTIR采样Shader
1. 实现 `restir_temporal_resampling.glsl`
2. 实现 `restir_spatial_resampling.glsl`
3. 实现 `restir_resolve.glsl` (如果需要)

**已完成任务**:
- [x] 实现`render_gbuffer_prepass` (C++调度已完成)
- [x] 实现`generate_rays` (C++调度已完成)
- [x] 实现`trace_screen_space` (C++调度已完成)
- [x] 实现`trace_world_space` (C++调度已完成，Shader已修正)

**注意**: 辐射度缓存更新 (`update_radiance_cache`) 目前在C++中已禁用，等待Shader实现。

**预计时间**: 3天
**优先级**: 高
**依赖**: 基础追踪管线 (已完成)

---
**最后更新**: 2025-11-30
**当前状态**: 基础追踪管线(RayGen -> ScreenTrace -> WorldTrace)的C++调度已全部实现。下一步是实现ReSTIR采样Shader。
