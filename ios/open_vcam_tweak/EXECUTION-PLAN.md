# OpenVCam 执行计划 + 防坑手册（mediaserverd 版 —— 核心已跑通）

> `ios/open_vcam_tweak/` 的执行计划与踩坑记录。**状态:核心功能已验证成功——OBS 画面在 RootHide 化的 TikTok 上稳定显示,每帧 100% 覆盖。** 本文件记录已完成部分、关键坑、以及"稍后继续开发"的待办。
> 与总体架构 [`VCAM-Unified-Redesign-Plan.md`](../../VCAM-Unified-Redesign-Plan.md) 互补。

---

## 0. 当前状态一句话

**已成功**:一个可编辑的 `com.iosvcam.opencam`,注入 `mediaserverd`,在其内部采集图(BufferWorks `BW*` 节点)**就地覆盖**相机像素缓冲为解码后的 OBS/RTMP 画面。日志实测:`decoder: produced 720x1280 frames` + `stats: videoBuffers=N overwrote=N`(100%),TikTok 拍摄界面稳定显示 OBS。

**为什么必须 mediaserverd**:用户的 TikTok 被 `com.roothide.patcher` 打成 RootHide 应用,绕过普通 App 级注入;mediaserverd 在所有 App 之下,是唯一能替换 RootHide 化 App 相机的层次(闭源 vcamera 也走这条路)。

---

## 1. Context

依赖闭源 `com.x.vcamera`(0.0.1-1922, kox),二进制不可改。逆向确认它注入 `mediaserverd`,内置 librtmp 拉流 → VideoToolbox 解 H264 → GPUImage 处理 → 在 `mediaserverd` 的 `BW*` 采集图里替换相机帧。目标:用可编辑源码复刻,预留音频合并位,最终一个 deb。

---

## 2. 逆向成果:vcamera 的 hook 点（照抄蓝本）

由 `vcamera.dylib` 反汇编(lief+capstone)得到。记忆:`vcamera-mediaserverd-hookpoints`。

**视频换帧(已实现):**
- `BWNodeOutput -emitSampleBuffer:` — 换帧主入口
- `BWNode / BWUBNode / BWPixelTransferNode -renderSampleBuffer:forInput:`
- (元数据节点 `BWVideoOrientationMetadataNode` / `BWMetadataDetectorGatingNode` 已从覆盖列表移除以减少干扰;人脸检测在下游照常运行)

**拍照(未做):** `BWPhotoEncoderNode -renderSampleBuffer:forInput:` 等。
**格式/前后摄(未用):** `FigVideoCaptureConnectionConfiguration setOutput*`、`FigCaptureSourceConfiguration sourcePosition`。
**UI(未做):** SpringBoard / SBLockScreenManager 等(vcamera 的悬浮设置)。

---

## 3. 当前架构（已实现并验证）

```
mediaserverd 进程内 (%ctor 仅当 processName==mediaserverd):
  hook BWNodeOutput emitSampleBuffer: + BW{Node,UBNode,PixelTransferNode} renderSampleBuffer:forInput:
  VCamRTMPSource ensureStarted → 后台拉流线程
  换帧: VCamReplaceSampleBuffer(sb)
    → CMSampleBufferGetImageBuffer(取相机 CVPixelBuffer, 无则跳过)
    → VCamFrameStore 取 0.5s 内新鲜解码帧(无则 fail-open 透传)
    → CIContext 把解码帧(缩放/镜像/旋转)就地覆盖进相机 buffer(保留格式/尺寸/attachments) → 调 orig
拉流/解码:
  vendor/rtmp/vcam_rtmp.c(自写 RTMP play) → FLV/AVC 解析 → VCamH264Decoder(VideoToolbox 软解) → VCamFrameStore
打包: filter Bundles=(com.apple.mediaserverd) Executables=(mediaserverd); postinst: killall -9 mediaserverd; Conflicts/Replaces com.x.vcamera
```

---

## 4. 已证实的关键事实与坑（实测）

### 4.1 RootHide 强制 mediaserverd
RootHide 化的 App 绕过普通注入 → 必须 mediaserverd。mediaserverd 是系统进程,**标准 DynamicLibraries 注入即可,不需要 `.roothidepatch` 符号链接**。

### 4.2 需要反向隧道,mediaserverd 才能拉流
```
plink -N -R 127.10.10.10:1935:127.0.0.1:1935 -P 2222 -pw <pw> root@127.0.0.1
```
没有它 → `rtmp: tcp connect failed`。(launcher USB 模式负责建隧道 + 127.10.10.10 回环别名。)

### 4.3 解码器 1100 = 系统解码会话池被耗尽（重要）
`VTDecompressionSessionCreate` 报 **1100**(硬解、软解都报)。**根因不是格式、不是硬件竞争,而是反复 `killall -9 mediaserverd`(SIGKILL 不清理)泄漏了 `videodecoderd` 的解码会话,池耗尽后一律 1100。**
- 开发期恢复:`killall -9 videodecoderd` 重置池,解码立刻恢复。
- 生产环境只 killall 一次,不会触发。
- 代码侧已:① 强制软件解码(raw key `@"EnableHardwareAcceleratedVideoDecoder":@NO`,因命名常量标注 iOS17+ 会触发 -Werror);② NULL 输出格式(强制 NV12+IOSurface 也会独立失败)。
- **待优化(见 6)**:解码会话复用(SPS/PPS 不变则不重建),避免重连时反复建/毁会话。

### 4.4 mediaserverd 沙盒:读不到任何配置文件（重要,当前限制）
probe 实测:`/var/mobile/vc.plist`、`/var/tmp/vc.plist`、`/var/mobile/Media/vc.plist`、`/usr/lib/TweakInject/vc.plist` **全部 exists=0**——mediaserverd 沙盒连 stat 都拒。所以:
- **`vc.plist` 的 mirror/rotation/enabled/自定义 URL 在 mediaserverd 里全部无效**,只用编译进去的默认值。
- **默认 URL 恰好 = 工作隧道地址** `rtmp://127.10.10.10:1935/live/srs`,所以无需配置也能出画。
- kill-switch 文件也读不到 → **禁用只能靠 `dpkg -r com.iosvcam.opencam` + `killall mediaserverd`**。
- 闭源 vcamera 从 `/var/mobile/Media/vcamera.txt` 读配置——但那可能是从它注入的 SpringBoard 侧读、再经 IPC 传给 mediaserverd,不是 mediaserverd 直接读。
- **结论**:mirror 等要生效,不能靠配置文件,得走**代码内自动**(如 sourcePosition 前摄自动镜像)或 **Darwin notify / mach IPC** 等沙盒可达的通道。

### 4.5 原生相机录像卡死 = 既有音频钩子（非 OpenVCam）
用户确认:切原生相机录像卡死是既有的 `iOSVCAMAudioBridgeSystemHook`(也在 mediaserverd)造成,与 OpenVCam 无关。

### 4.6 历史崩溃取证(背景)
闭源 vcamera 在系统相机录像时曾多次崩 mediaserverd(`EXC_BREAKPOINT`,栈在 `CMCapture`→`PixelTransferSession`)。对策:就地覆盖(保留原格式/尺寸)+ fail-open。系统原生相机录像仍是最危险场景。

### 4.7 设备红线
`vcam-latency-patch-discrete`、`ios-device-read-only-rule`、`vcam-roothide-vcplist-sandbox`。

---

## 5. 安全底线

1. 只 hook mediaserverd(`processName==mediaserverd` 才动作)。
2. fail-open:任何失败调 orig 传原始帧,永不黑屏/冻结。
3. 看门狗:解码帧超 0.5s 未更新 → 透传。
4. 禁用:当前只能卸载 + killall mediaserverd(沙盒读不到 kill-switch 文件,见 4.4;待做 notify 开关)。
5. 设备写操作先说明、可回退。

---

## 6. 已完成 / 待办

### ✅ 已完成并验证
- 自写 RTMP 客户端、VideoToolbox 软解、FrameStore、mediaserverd BW hook、就地覆盖。
- **端到端成功**:OBS 稳定显示在 RootHide 化 TikTok,100% 帧覆盖。
- 解码器 1100 根因定位(videodecoderd 会话耗尽)+ 软解规避。
- 反向隧道、CI(build+retag+validate)、VCamLog C 链接。

### 🔶 稍后继续开发(按建议优先级)
- [x] **6-a 前后摄自动镜像**(v0.2.0 已实现,待设备肉眼确认方向):`Tweak.xm` hook `FigCaptureSourceConfiguration -sourcePosition` → 全局 `gSourcePosition`;`VCamOverwriteImageBuffer` 里前摄(pos==2)自动水平镜像,OR 上 `cfg.mirror`。方向可一键翻转:编译期 `VCAM_FRONT_AUTOMIRROR`(默认 1)。**这是 mirror 的正确实现**(配置文件在 mediaserverd 读不到,见 4.4)。若装后前摄镜像方向反了,把该宏改 0 重出即可。
- [x] **6-b 解码会话复用**(v0.2.0):`configureWithAVCDecoderConfigurationRecord` 里若新 SPS/PPS + naluLen 与当前相同且 `_session/_formatDesc` 存在 → 直接返回 YES,跳过重建;减少 GOP 重发 seq header 时的建/毁,避免会话泄漏(呼应 4.3)。
- [x] **6-c 出正式版清理**(v0.2.0):`VCamLog.h` 加 `VCAM_DEBUG`(默认 0)+ `VCamDebugLog` 宏;probe、seq header 字节 dump、stats、produced 计数全部收进 `#if VCAM_DEBUG`;错误 + 一次性生命周期日志(hooks installed / decoder configured / rtmp 错误)仍走 `VCamLog` 常显。调试时 `make ... OpenVCam_CFLAGS+=-DVCAM_DEBUG=1`。
- [ ] **6-d 人脸检测确认**:检测在覆盖下游运行,应能识别 OBS 画面里的脸——用户用 TikTok 人脸贴纸实测确认(代码层不覆盖元数据/人脸节点,理论已可用)。
- [ ] **6-e 沙盒可达的开关/配置(可选)**:用 Darwin notify(`notify_set_state`/`notify_get_state`,64 位可编码 enabled/mirror/rotation 等 flag)或 mach IPC,让配置/kill-switch 在 mediaserverd 里可控;或注入 SpringBoard 读 vc.plist 再经 IPC 传入(vcamera 疑似此法)。
- [ ] **6-f 拍照替换**:hook `BWPhotoEncoderNode renderSampleBuffer:forInput:` 等。
- [ ] **6-g 健壮性**:保宽高比选项(当前拉伸);CIContext 预热移出采集线程;拉流线程相机空闲时可停。
- [x] **P3 音频并入 —— 全局 mediaserverd 版**(v0.3.0,当前方向):用户要求音频也像视频一样全局、原相机也生效,不只 TikTok。故 v0.2.0 的 app 级 `VCamAudio.x`(只注入 TikTok,靠 RootHide `.roothidepatch`+pkgmirror 才注入,已弃)**被替换**为 `VCamAudioMS.x`(移植自 `ios/audio_bridge_media_active_tweak`):在 **mediaserverd** 里全局 hook `AudioUnitRender`,无锁环形缓冲+抖动缓冲的实时安全实现,从 PC 音频桥 `127.10.10.10:1936` 拉 PCM(IAF1 协议,与视频的 1935/RTMP 独立),替换所有采集客户端(原相机/TikTok/全部 App)的麦克风。fail-open。plist 回到 **mediaserverd-only**(不再需要 TikTok app 注入 / RootHide 那套)。Makefile 用 `AudioToolbox`(AudioUnitRender/GetProperty 由它提供,**不要单独连 AudioUnit framework——iOS 无此独立 framework,会 ld 失败**)。postinst 额外 `killall videodecoderd`(重置解码池,避免装后首帧 1100,见 4.3)。control 升 0.3.0,`Conflicts/Replaces` 全套独立音频包。**风险**:原相机拍照→拍视频是黑屏/卡死最高危路径(4.5/4.6),上次卡死疑似多个音频包并存所致,现只留这一个 fail-open 钩子;万一卡死靠 `dpkg -r + killall mediaserverd` 恢复(沙盒可能读不到禁用开关)。**待装机验证原相机稳定性。**

---

## 7. 🕳️ 防坑清单

1. mediaserverd 换帧要保原格式(就地覆盖最稳,避 CMCapture 断言)。
2. **配置别指望文件**:mediaserverd 沙盒挡所有路径(4.4)。mirror 走 sourcePosition;开关走卸载或 notify。
3. **解码 1100 先想到 videodecoderd 会话耗尽**(反复 killall -9 的后果),`killall videodecoderd` 重置;生产只 killall 一次(4.3)。
4. 解码器规范用 raw key 字符串(命名常量 iOS17+ 触发 -Werror)。
5. 没反向隧道拉不到流(4.2)。
6. 别输出黑屏/冻结 → fail-open。
7. 别与闭源 vcamera 同装(Conflicts/Replaces 已做)。
8. VCamLog 跨 .m/.mm 用 C 链接(VCamLog.h extern "C")。
9. 原生相机录像最危险;音频钩子卡死是既有问题(4.5)。
10. 设备写操作先说明、可回退;崩溃核查 `idevicecrashreport -k`。

---

## 8. 设备交互规程（本次已用,记录以便复用）

- USB SSH:`C:/iProxy/iproxy.exe 2222 22` → `plink -ssh -batch -hostkey SHA256:kBdKmvWdBoghcXNaoWFmq6/llHh4k5tkLfSYQJDWYUI -P 2222 -pw <config.ini SSHPassword> root@127.0.0.1 '<命令>'`。
- 传 deb:`plink ... "cat > /tmp/x.deb" < 本地deb`;装:`dpkg -i /tmp/x.deb`;重载:`killall -9 mediaserverd`。
- 反向隧道(拉流必需):`plink -N -R 127.10.10.10:1935:127.0.0.1:1935 -P 2222 -pw <pw> root@127.0.0.1`(后台常驻)。
- 日志:`C:/iProxy/idevicesyslog.exe | grep OpenVCam`(mediaserverd 写不了文件日志,只能 syslog)。
- 解码器池卡死恢复:`killall -9 videodecoderd`。
- 回退:`dpkg -r com.iosvcam.opencam && killall -9 mediaserverd`。
- CI 产物下载(GitHub Actions,boylove 仓库):workflow `build-open-vcam-tweak.yml` → artifact `open-vcam-tweak-rootless-deb`。

---

## 9. 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | mediaserverd 注入 + BW hook + 拉流软解 + 就地覆盖 | ✅ 完成 |
| **M2** | OBS 画面稳定显示在 RootHide 化 TikTok(100% 覆盖) | ✅ 完成 |
| **M3** | 前后摄自动镜像(6-a)+ 会话复用(6-b)+ 出正式版清理(6-c) | ✅ 完成(v0.2.0,待装机确认镜像方向) |
| **M4** | 人脸检测确认 + 拍照替换 + 稳定性 | ⬜ 待做(6-d 待肉眼确认) |
| **M5** | 音频并入(视频+音频一个 deb) | 🔶 v0.3.0 改全局 mediaserverd 音频(原相机也生效),待装机验证原相机稳定性 |

**推进节奏**:每步验证、汇报;动设备的写操作先说明、可回退。
