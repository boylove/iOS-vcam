# OpenVCam — 开源可编辑虚拟摄像头 tweak

闭源 `com.x.vcamera`（0.0.1-1922, kox）的**开源、可编辑**复刻。逆向报告见 [`VCAMERA_REVERSE_REPORT.md`](../../VCAMERA_REVERSE_REPORT.md)。原理：注入 `mediaserverd`，内置精简 RTMP 客户端拉流 → VideoToolbox 解 H264 → VTPixelTransfer/Rotation 转成相机格式 → **造一个全新的 `CMSampleBuffer` 传给采集图**，替换所有相机客户端看到的画面。

> ⚠️ 设备为 Dopamine iOS 16.1.2，`mediaserverd` 是系统进程，改动相机管线历史上极易黑屏/卡死，尤其**系统原生相机的录制**。本 tweak 全程 **fail-open**（任何异常都透传真实相机）。原生相机录制是最高危路径。

## 架构（当前）

- **注入点**：`mediaserverd`（`OpenVCam.plist` filter `Bundles=(com.apple.mediaserverd) Executables=(mediaserverd)`）。`mediaserverd` 在所有相机客户端之下，因此能替换 **RootHide 化的 TikTok / 系统原生相机 / 所有 App**——app 级注入会被 RootHide 绕过，所以必须在这一层。
- **帧替换**：hook 终端节点 `BWNodeOutput -emitSampleBuffer:`（只此一个，一帧一次；中间 `renderSampleBuffer:forInput:` 节点默认不 hook，`VCAM_HOOK_RENDER_NODES` 编译期可开，风险高）。**不改相机原 buffer**：把解码帧经 `VTPixelTransferSession`（+ 前摄/旋转用 `VTPixelRotationSession`）转进自建的 `CVPixelBufferPool` 缓冲，再 `CMSampleBufferCreateForImageBuffer` 造新 sample buffer（带原 timing/attachments），传给原实现。这与闭源一致，避免了「就地改」导致的 `CMCapture PixelTransferSession` 断言崩溃 + 多节点重复渲染卡顿。
- **前后摄自动镜像**：hook `FigCaptureSourceConfiguration -sourcePosition`，前摄自动水平镜像（配置文件在 mediaserverd 沙盒读不到，见下）。编译宏 `VCAM_FRONT_AUTOMIRROR`（默认 1）可翻转方向。
- **视频源**：设备端直接拉 RTMP（内联 `vendor/rtmp/vcam_rtmp.c`，自写精简 play 客户端，无外部依赖）。需要 PC 端 SRS + USB 反向隧道把 `127.10.10.10:1935` 暴露给设备。
- **解码**：VideoToolbox 硬解，destination attrs 带 native size / 420v / IOSurface / OpenGLCompat，会话 `RealTime=true` + `ThreadCount=2`（照原作者）；SPS/PPS 不变则复用会话；create 失败（如 1100）有退避。

## 配置与沙盒（重要）

`mediaserverd` 的沙盒**读不到** `/var/mobile/vc.plist`、`/var/tmp`、`/var/mobile/Media` 等所有配置路径，`VCamConfig` 因此只用**编译进去的默认值**（`rtmp://127.10.10.10:1935/live/srs`、enabled=YES）。所以：

- 自定义 RTMP / mirror / rotation 通过 `vc.plist` 在本进程**不生效**；镜像走代码内 sourcePosition 自动判定。
- 文件硬开关 `vc.disabled` 也读不到——**禁用只能卸载**（见下）。默认 URL 恰好等于工作隧道地址，所以无需配置也能出画。
- 未来若要可控开关：Darwin notify / mach IPC 等沙盒可达通道。

## 安全 / 恢复（务必先看）

- **禁用 / 恢复**：`dpkg -r com.iosvcam.opencam && killall -9 videodecoderd && killall -9 mediaserverd`。（沙盒读不到 `vc.disabled` 文件开关。）
- **看门狗**：解码帧超 0.5s 没更新自动透传真实相机；任何环节失败一律透传，永不黑屏/冻结。
- **反复 killall 后「不是 OBS 画面」**：多半是 `videodecoderd` 解码会话池被 SIGKILL 耗尽 → `VTDecompressionSessionCreate` 报 1100。`killall -9 videodecoderd` 重置；`postinst` 已带这一步。
- deb `Conflicts/Replaces com.x.vcamera` 及旧音频包，避免双重注入。

## 构建

推到 `build/**` / `feature/**` / `main` 触发 `.github/workflows/build-open-vcam-tweak.yml`（macOS + Theos），产物 `open-vcam-tweak-rootless-deb`。本地校验：`python ios/validate_deb.py <deb>`。调试日志：`OpenVCam_CFLAGS += -DVCAM_DEBUG=1`。

## 文件结构

```
Tweak.xm               mediaserverd hook + VTPixelTransfer/Rotation 帧替换 + sourcePosition 镜像 + 日志
VCamConfig.{h,m}       配置（mediaserverd 沙盒下回退默认值）
VCamRTMPSource.{h,mm}  RTMP 拉流线程 + FLV/AVC 解析 + 重连
VCamH264Decoder.{h,mm} VideoToolbox 解码（照原作者的 dstAttrs/RealTime/ThreadCount + ITU 色彩元数据）
VCamFrameStore.{h,m}   线程安全最新帧 + 看门狗
VCamAudioMS.x          全局 mediaserverd 音频（AudioUnitRender 替换）——当前暂未编入（见 Makefile）
vendor/rtmp/vcam_rtmp.{h,c} 自写精简 RTMP play 客户端
OpenVCam.plist         Logos filter（mediaserverd）
Makefile / control / layout/DEBIAN/*
```

## 路线图 / 待办

- **视频保真**：BGRA/YUV 多路径 + 可选 GPUImage 美颜/瘦脸（当前只 420v + VT transfer，拉伸填充）。
- **音频**：`VCamAudioMS.x` 全局 `AudioUnitRender` 替换（从 `ios/audio_bridge_media_active_tweak` 并入）。曾破坏原生相机录制，待视频在原相机录制稳定后，用同样的「不破坏录制」思路重新并入。
- **原生相机录制**：最高危场景，是当前主攻目标。
- 沙盒可达的配置/开关（Darwin notify）。
