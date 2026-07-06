# OpenVCam — 开源可编辑虚拟摄像头 tweak

闭源 `com.x.vcamera`（0.0.1-1922, kox）的**开源、可编辑**复刻。逆向确认其原理：内置 librtmp 拉 RTMP 流 → VideoToolbox 解 H264 → GPUImage 处理 → 替换相机 `CMSampleBuffer`。本项目用可读可改的源码复刻同等**视频注入**能力，并预留音频合并位，最终一个 deb。

> ⚠️ 你的设备是 Dopamine iOS 16.1.2，相机管线改动历史上极易黑屏。本 tweak 全程 **fail-open**（任何异常都透传真实相机，永不黑屏）并带**硬开关**。请务必先读下面的"安全 / 恢复"。

## 当前阶段：Phase 1（视频，App 级注入）

- **注入范围**：Logos filter 按 `Classes = (AVCaptureVideoDataOutput)`，只加载进*用相机的 App*（TikTok、各类直播/相机 App）。不碰 `mediaserverd`，不影响系统原生相机 App。
- **机制**：hook `AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:`，对 delegate 的 `captureOutput:didOutputSampleBuffer:fromConnection:` 做 `MSHookMessageEx`（与已验证可用的 Safe 音频桥同一套），把解码出的画面塞进 buffer。
- **视频源**：设备端直接拉 RTMP（内联的 `vendor/rtmp/vcam_rtmp.c`，自写精简 RTMP play 客户端，无外部依赖、可自由修改）。

## 配置：`/var/mobile/vc.plist`

与 vcamera / launcher STEP 9d-2 共用同一文件：

| 键 | 类型 | 默认 | 说明 |
|----|------|------|------|
| `rtmp` | String | 空→`rtmp://127.10.10.10:1935/live/srs` | 拉流地址 |
| `enabled` | Bool | YES（键缺省即视为开） | 总开关 |
| `mirror` | Bool | NO | 水平镜像 |
| `rotation` | Number | 0 | 顺时针 0/90/180/270 |

配置每 1.5s 自动热重载，无需重启 App。

## 安全 / 恢复（务必先看）

- **硬开关**：`touch /var/mobile/vc.disabled` → tweak 立即变纯透传空操作（≤1.5s 生效）。删掉文件恢复。任何时候出问题，SSH 建这个文件即可回到真实相机，**无需重越狱**。
- **看门狗**：解码帧超过 0.5s 没更新（断流/卡顿）自动透传真实相机。
- **不主动改设备**：deb 由你手动 `dpkg -i`；本仓库/launcher 不自动推送。`postinst` 不 `killall mediaserverd`，装完重启目标 App 即可。
- deb 声明 `Conflicts/Replaces: com.x.vcamera`，安装时会移除闭源包，避免双重注入黑屏。

## 构建

推到 `build/**` / `feature/**` / `main` 触发 `.github/workflows/build-open-vcam-tweak.yml`（macOS + Theos），产物为 `open-vcam-tweak-rootless-deb`。本地校验：

```bash
python ios/validate_deb.py <下载的 deb>
```

## 端到端验证

1. PC 用 launcher 起 SRS，`ffmpeg -re -i test.mp4 -c copy -f flv rtmp://localhost:1935/live/srs` 推测试流。
2. `vc.plist` 的 `rtmp` 指向该地址（WiFi 直连 PC IP，或 USB 隧道 127.10.10.10）。
3. 手动装 deb，重启目标 App，打开其相机 → 应显示推流画面。
4. 日志：`NSTemporaryDirectory()/OpenVCam.log` 或 syslog 里的 `[OpenVCam]`，应有 `hooked video delegate` / `rtmp: play sent` / `AVC sequence header applied`。
5. **安全回归**：`touch /var/mobile/vc.disabled` 重启 App → 真实相机、无黑屏；停止推流 → 0.5s 后透传、无黑屏。

## 文件结构

```
Tweak.xm              主逻辑：帧替换 hook + CoreImage 缩放/镜像/旋转 + 日志（含音频 Phase 3 占位）
VCamConfig.{h,m}      读 vc.plist + 硬开关，热重载
VCamRTMPSource.{h,mm} RTMP 拉流线程 + FLV/AVC 解析 + 重连
VCamH264Decoder.{h,mm} VideoToolbox 解码 → NV12 CVPixelBuffer
VCamFrameStore.{h,m}  线程安全最新帧 + 看门狗
vendor/rtmp/vcam_rtmp.{h,c} 自写精简 RTMP play 客户端（握手/chunk/AMF0/connect-createStream-play）
OpenVCam.plist        Logos filter（Classes=AVCaptureVideoDataOutput）
Makefile / control / layout/DEBIAN/*
```

## 路线图

- **Phase 2（可选，高风险，默认关）**：额外注入 `mediaserverd`/CMIO 覆盖系统原生相机 App 与全系统。改 `OpenVCam.plist` 加 `Bundles=(com.apple.mediaserverd) Executables=(mediaserverd)`。**仅在 Phase 1 稳定后单独试**，全程用硬开关兜底——这是最容易黑屏的部分。
- **Phase 3（音频）**：把 `ios/audio_bridge_safe_tweak` 已验证的 `AudioUnitRender` + `AVCaptureAudioDataOutput` 替换逻辑并入本 dylib（见 Tweak.xm 的 Audio 占位区块），视频+音频同一个 deb、同一份配置与硬开关。
- 画质增强：GPUImage 美颜、保持宽高比（当前 v1 为拉伸填充）。
