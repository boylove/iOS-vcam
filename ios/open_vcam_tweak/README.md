# OpenVCam — 开源可编辑虚拟摄像头 tweak

闭源 `com.x.vcamera`（0.0.1-1922, kox）的**开源、可编辑**复刻。逆向报告见 [`VCAMERA_REVERSE_REPORT.md`](../../VCAMERA_REVERSE_REPORT.md) 及指令级深度报告 [`VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md`](../../VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md)。原理：注入 `mediaserverd`，内置精简 RTMP 客户端拉流 → VideoToolbox 解 H264 → VTPixelTransfer/Rotation 转成相机格式 → **`VTPixelTransferSessionTransferImage` 就地覆盖相机自己的 `CVImageBuffer`（共享 IOSurface）**，再把**原始 sample buffer** 传给原方法，替换所有相机客户端看到的画面。

> 📌 早期版本一度改成「造新 `CMSampleBuffer` 传下游」，但深度逆向（DEEP_REVERSE §0/§2.2）证明原作者是**就地覆盖**——App 预览读的是上游共享 surface，造新 buffer 传下游根本到不了预览。现已改回就地覆盖，与原作者二进制行为一致。

> ⚠️ 设备为 Dopamine iOS 16.1.2，`mediaserverd` 是系统进程，改动相机管线历史上极易黑屏/卡死，尤其**系统原生相机的录制**。本 tweak 全程 **fail-open**（任何异常都透传真实相机）。原生相机录制是最高危路径。

## 架构（当前）

- **注入点**：`mediaserverd`（`OpenVCam.plist` filter `Bundles=(com.apple.mediaserverd) Executables=(mediaserverd)`）。`mediaserverd` 在所有相机客户端之下，因此能替换 **RootHide 化的 TikTok / 系统原生相机 / 所有 App**——app 级注入会被 RootHide 绕过，所以必须在这一层。
- **帧替换（视频/预览）**：hook 终端节点 `BWNodeOutput -emitSampleBuffer:`（只此一个，一帧一次）。**就地覆盖相机自己的 `CVImageBuffer`**：把解码帧经 `VTPixelTransferSession`（+ 前摄/旋转用 `VTPixelRotationSession`）直接 `VTPixelTransferSessionTransferImage` 转写进相机那块共享 IOSurface，然后把**原始 sample buffer**（现已被就地改写）传给原实现。这与闭源二进制行为逐条一致（见 `VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md` §2.2）——只有就地写相机原 buffer 才会被 App 预览/TikTok 读到（下游造新 buffer 到不了 App）。用 VT（非 CIContext）、只在终端 emit（不在 PixelTransfer 节点），是原作者既不崩原生相机录制也不卡顿的原因。中间 `renderSampleBuffer:forInput:` 视频节点（`BWNode/BWUBNode/BWPixelTransferNode`）**一律不 hook**——就地覆盖它们正是录制崩溃路径。
- **帧替换（拍照/静态捕获）**：hook `BWStillImageScalerNode` / `BWPhotoEncoderNode` 的 `renderSampleBuffer:forInput:`，就地覆盖静态照片 buffer（否则快门拿到真实镜头），用 `TransitionID` 附件去重保证一张照片流经多个照片节点时只覆盖一次（照原作者 §2.3）。编译宏 `VCAM_HOOK_PHOTO_NODES` **默认 0（关）**——原生相机拍照→录像切换是本机最高危崩溃路径，故默认只替换视频/预览、拍照回落真实镜头，保原生相机稳定。要拍照也出 OBS 用 `-DVCAM_HOOK_PHOTO_NODES=1` 重出。
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
Tweak.xm               mediaserverd hook（视频 emit 就地覆盖 + 拍照节点就地覆盖 + sourcePosition 镜像）+ 日志
VCamConfig.{h,m}       配置（mediaserverd 沙盒下回退默认值）
VCamRTMPSource.{h,mm}  RTMP 拉流线程 + FLV/AVC 解析 + 重连
VCamH264Decoder.{h,mm} VideoToolbox 解码（照原作者的 dstAttrs/RealTime/ThreadCount + ITU 色彩元数据）
VCamFrameStore.{h,m}   线程安全最新帧 + 看门狗
VCamAudioMS.x          全局 mediaserverd 音频（AudioUnitRender 替换）——【故意不编入】见下
vendor/rtmp/vcam_rtmp.{h,c} 自写精简 RTMP play 客户端
OpenVCam.plist         Logos filter（mediaserverd）
Makefile / control / layout/DEBIAN/*
```

## 复刻完成度（相对闭源 com.x.vcamera）

逆向报告 [`VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md`](../../VCAMERA_FRAME_REPLACEMENT_DEEP_REVERSE.md) §6 的复刻要点已全部实现：

| 原程序功能（报告） | 复刻状态 |
|---|---|
| 就地覆盖 `emitSampleBuffer:`（§2.2，VT + 加锁 + 传原始 sb） | ✅ `VCamOverwriteInPlace` |
| 只 hook emit、render 节点不改帧（§6 要点 1） | ✅ 避开 BWPixelTransferNode 录制崩溃 |
| 拍照路径 `modifyPixelBuffer:` + TransitionID 去重（§2.3） | ✅ `VCamOverwritePhotoInPlace`（`VCAM_HOOK_PHOTO_NODES`，默认**关**，`=1` 开） |
| 旋转/前摄镜像（§2.4） | ✅ `VTPixelRotationSession` + `sourcePosition` |
| 解码器配置（§4：不强制软解/OpenGLCompat/RealTime/ThreadCount=2/ITU 色彩） | ✅ `VCamH264Decoder` |
| GPUImage 美颜/瘦脸（§3：thinFaceFilter/beautyFaceFilter…） | ⏭️ **不可忠实复刻**：报告只给了滤镜名，无参数/着色器/地址。虚拟摄像头核心不依赖美颜；如需可另写一套近似实现，但那是新功能，非复刻。 |
| 音频（麦克风替换） | ⏸️ **故意不编入**：`VCamAudioMS.x` 已写好，但在**本机（Dopamine iOS 16.1.2）**上「mediaserverd 全局音频 + 原生相机拍照→录像切换」是最高危崩溃路径，且历史上音频桥影响过本机相机环境。视频在原生相机录制稳定验证前不并入。 |

**结论**：报告认定「决定成败」的整套视频替换机制（含拍照）已完整、忠实复刻。未做的两项——美颜、音频——一项无法从报告忠实复刻（新功能），另一项是本机高危路径的主动搁置，均非视频虚拟摄像头的核心。

## 路线图 / 待办

- **音频（搁置，非放弃）**：`VCamAudioMS.x` 全局 `AudioUnitRender` 替换（从 `ios/audio_bridge_media_active_tweak` 并入，代码已就绪）。曾影响原生相机环境，**待视频在原生相机拍照/录制稳定验证后**，再用 fail-open 思路编入 Makefile。
- **视频保真**：BGRA/YUV 多路径 + 保宽高比选项（当前 420v + VT transfer，拉伸填充）。
- **美颜（可选新功能）**：GPUImage 瘦脸/美颜近似实现（报告无法忠实复刻，见上表）。
- **原生相机录制**：最高危场景，装机验证重点。
- 沙盒可达的配置/开关（Darwin notify）。
