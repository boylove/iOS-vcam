# OpenVCam 执行计划 + 防坑手册（mediaserverd 版，已跑通）

> `ios/open_vcam_tweak/` 的执行计划与踩坑记录。**已随实测大幅修订:方案从"App 级注入"转向"mediaserverd 注入",并已在 RootHide 化的 TikTok 上验证成功。**
> 与总体架构文档 [`VCAM-Unified-Redesign-Plan.md`](../../VCAM-Unified-Redesign-Plan.md) 互补。

---

## 0. 重大转向（先读)

原计划以 **App 级 hook `AVCaptureVideoDataOutput` delegate** 为主、mediaserverd 为高危可选。**实测推翻了这个前提:**

- 用户的 **TikTok 被 `com.roothide.patcher` 打成了 RootHide 应用**(RootHideConfig `com.zhiliaoapp.musically=true`),**绕过普通 App 级 tweak 注入** → App 级方案对它完全无效(dylib 进不去)。
- 闭源 vcamera 之所以能替换该 TikTok,是因为它注入的是 **`mediaserverd`(系统层,在 App 之下)**,不是 App 进程。这是**唯一可行**的方式。
- 于是重写为 **mediaserverd 版**,并**已验证:OBS 画面成功显示在 RootHide 化的 TikTok 拍摄界面**。

**当前状态:核心功能 = 成功。** 剩配置(mirror/旋转/kill-switch)路径微调 + 若干健壮性项。

---

## 1. Context

依赖闭源 `com.x.vcamera`(0.0.1-1922, kox),二进制不可改。逆向确认:注入 `mediaserverd`(+ springboard/lskdd),内置 librtmp 拉流 → VideoToolbox 解 H264 → GPUImage 处理 → 在 **mediaserverd 的 BufferWorks(`BW*`)采集图**里替换相机帧。配置读 `/var/mobile/vc.plist`。纯视频、不含音频。

目标:用**可编辑源码**复刻同等能力,预留音频合并位,最终**一个 deb**。

---

## 2. 逆向成果:vcamera 的确切 hook 点(照抄蓝本)

由 `vcamera.dylib` 反汇编(lief+capstone 追踪 `objc_getClass`+`MSHookMessageEx`)得到。记忆见 `vcamera-mediaserverd-hookpoints`。

**视频换帧(核心):**
- `BWNodeOutput -emitSampleBuffer:` — 节点向下游吐帧,换帧主入口
- `BWNode / BWUBNode / BWPixelTransferNode -renderSampleBuffer:forInput:` — 视频渲染路径
- (元数据节点 `BWVideoOrientationMetadataNode` / `BWMetadataDetectorGatingNode` 也在 vcamera 列表里,但**我们已移除对它们的覆盖**以减少干扰;人脸检测在下游照常运行)

**拍照:** `BWPhotoEncoderNode -renderSampleBuffer:forInput:` 等(vcamera 有,**本项目尚未做**)。
**格式/按 App 门控(上下文):** `FigVideoCaptureConnectionConfiguration setOutputWidth:/Height:/Format:`、`FigCaptureSourceConfiguration sourcePosition`(前后摄)、`FigCaptureClientSessionMonitor applicationID`、`BWStreamingSessionAnalyticsPayload setClientApplicationID:`。
**UI(vcamera 的悬浮设置,本项目未做):** SpringBoard / SBLockScreenManager / SBDashBoardLockScreenEnvironment。

---

## 3. 当前架构（已实现)

```
mediaserverd 进程内:
  %ctor: 仅在 processName==mediaserverd 时 hook
    ├─ objc_getClass("BWNodeOutput") + MSHookMessageEx(emitSampleBuffer:)
    ├─ BWNode/BWUBNode/BWPixelTransferNode renderSampleBuffer:forInput:
    └─ VCamRTMPSource ensureStarted  ← 后台拉流线程
  换帧: 替换实现里 → VCamReplaceSampleBuffer(sb)
    ├─ CMSampleBufferGetImageBuffer(sb) 取相机像素缓冲(无则跳过=音频/元数据)
    ├─ VCamFrameStore 取 0.5s 内的新鲜解码帧(无则 fail-open 透传)
    └─ CIContext 把解码帧(缩放/镜像/旋转)**就地覆盖**进相机 CVPixelBuffer(保留格式/尺寸/attachments) → 调 orig

拉流/解码链:
  vendor/rtmp/vcam_rtmp.c(自写 RTMP play 客户端) → FLV/AVC 解析(VCamRTMPSource)
  → VCamH264Decoder(VideoToolbox) → VCamFrameStore(最新帧+看门狗)
```

**打包:** filter `Bundles=(com.apple.mediaserverd) Executables=(mediaserverd)`;`postinst: killall -9 mediaserverd`(重载生效,mediaserverd 自动重启);`Conflicts/Replaces: com.x.vcamera`。

---

## 4. 已证实的关键事实与坑(实测,最重要)

### 4.1 RootHide 强制 mediaserverd
RootHide 化的 App 绕过普通注入 → 必须走 mediaserverd(见第 0 节)。mediaserverd 是系统进程,**标准 `/var/jb/Library/MobileSubstrate/DynamicLibraries` 注入即可到达,不需要 `.roothidepatch` 符号链接**。

### 4.2 需要"反向隧道",mediaserverd 才能拉到流
mediaserverd 拉 `rtmp://127.10.10.10:1935` 需要设备上有人把 `127.10.10.10:1935` 转到 PC 的 SRS:
```
plink -N -R 127.10.10.10:1935:127.0.0.1:1935 -P 2222 -pw <pw> root@127.0.0.1
```
没有它 → 日志刷 `rtmp: tcp connect failed`。(launcher 的 USB 模式负责建这条隧道 + `127.10.10.10` 回环别名。)

### 4.3 解码器在 mediaserverd 里的坑:VTDecompressionSessionCreate 报 1100
强制输出格式(NV12+IOSurface)会让 `VTDecompressionSessionCreate` 在 mediaserverd 里返回 **1100**。**必须传 NULL destination attributes**(用原生输出格式),CoreImage 覆盖时再转。已修。

### 4.4 mediaserverd 沙盒:读不到 /var/mobile 和 /var/tmp
- 实测:vc.plist 写别的端口,mediaserverd 仍连默认端口 → **读不到 `/var/mobile/vc.plist`**;`vc.disabled` 也被忽略;OpenVCam.log 也写不进 tmp。
- vcamera 从 **`/var/mobile/Media/vcamera.txt`** 读配置 → **`/var/mobile/Media/` 是 mediaserverd 沙盒允许的**。配置改为优先读 `/var/mobile/Media/vc.plist`(进行中,靠 probe 日志确认)。
- **默认 rtmp URL 恰好等于工作用的隧道地址**,所以即便配置读不到,OBS 也能出画;但 mirror/旋转/kill-switch 依赖能读到配置。

### 4.5 原生相机"录像"卡死 = 音频钩子的老问题(非 OpenVCam)
用户明确:切原生相机录像卡死是**既有的音频系统钩子**(`iOSVCAMAudioBridgeSystemHook`,也在 mediaserverd)造成的,与 OpenVCam 无关。历史崩溃取证(下)仍是 mediaserverd 层的普遍风险提示。

### 4.6 历史崩溃取证(背景,仍需警惕)
闭源 vcamera 在系统相机录像时曾多次崩 mediaserverd(`EXC_BREAKPOINT`,栈在 `CMCapture`→`PixelTransferSession/PixelRotationSession`;另有 WATCHDOG 挂起)。根因:切录像时采集切到更严格的格式/旋转,注入帧不匹配 → CMCapture 断言。**我们的对策:就地覆盖(保留原格式/尺寸/attachments)+ fail-open,尽量不引入格式不匹配。** 第三方 App(TikTok)预览路径已验证 OK;系统原生相机录像仍是最危险场景,谨慎。

### 4.7 设备记忆红线
`vcam-latency-patch-discrete`(任何缓冲补丁黑屏)、`ios-device-read-only-rule`(只读铁律,写操作先说明可回退)、`vcam-roothide-vcplist-sandbox`(SpringBoard 挡写 vc.plist)。

---

## 5. 硬约束与安全底线

1. **只 hook mediaserverd**:`%ctor` 里 `processName==mediaserverd` 才动作,其它进程直接 return。
2. **一切失败即透传(fail-open)**:未连流 / 解码失败 / 无新帧 / 覆盖异常(@try) → 一律调 orig 传原始帧,**永不黑屏/冻结**。
3. **硬开关**:配置 `enabled=false` 或 disable 文件存在 → 纯透传。**注意:必须放在 mediaserverd 能读的路径(`/var/mobile/Media/`),`/var/mobile/vc.disabled` 在 mediaserverd 里无效(4.4)。**
4. **看门狗**:解码帧超 0.5s 未更新 → 透传真实相机。
5. **设备写操作先说明、可回退**:装 deb、建配置文件、`killall mediaserverd` 都属可回退操作;出问题 `dpkg -r com.iosvcam.opencam` + `killall mediaserverd` 即恢复。

---

## 6. 已完成 / 待办

### ✅ 已完成(已验证)
- 工程脚手架、自写 RTMP 客户端、VideoToolbox 解码、FrameStore、配置热重载。
- **mediaserverd 注入 + BW 节点 hook + 就地覆盖 → OBS 画面显示在 RootHide 化 TikTok**(核心成功)。
- 解码器 1100 修复(NULL destAttrs)。
- 反向隧道打通验证。
- `VCamLog` C 链接(修 .m/.mm 链接冲突)。
- CI:build + `retag_deb_architecture.py`(arm64e)+ `validate_deb.py` 三步齐全。

### 🔶 进行中 / 待办(按优先级)
- [ ] **6-a 配置路径落地(进行中)**:确认 mediaserverd 能读 `/var/mobile/Media/vc.plist`(probe 日志)。确认后 mirror/rotation/enabled 全部可用。
- [ ] **6-b 硬开关走 Media 路径**:kill-switch 文件/enabled 放 `/var/mobile/Media/`,实测从 mediaserverd 能切回真实相机。**这条不过不算完成。**
- [ ] **6-c 前后摄自动镜像(可选增强)**:hook `FigCaptureSourceConfiguration sourcePosition` 得知前/后摄,前摄自动镜像,免手动配置。
- [ ] **6-d 直通优化**:解码帧尺寸/格式与相机一致且无镜像/旋转时,跳过 CIContext,减负载。
- [ ] **6-e 拉流线程可停**:相机空闲时停 `VCamRTMPSource`(hook `BWGraph stop:` 或会话计数),省电/放连接。
- [ ] **6-f 拍照替换**:hook `BWPhotoEncoderNode renderSampleBuffer:forInput:` 等。
- [ ] **6-g 健壮性**:保宽高比选项(当前拉伸);CIContext 移出采集线程预热避免首帧卡顿;`CVBufferPropagateAttachments`(就地覆盖已天然保留 attachments,基本已满足)。
- [ ] **6-h 人脸检测确认**:检测在覆盖下游运行,应能识别 OBS 画面里的脸 —— 请用户用人脸贴纸实测确认。
- [ ] **P3 音频并入**:把 `ios/audio_bridge_safe_tweak` 的音频替换逻辑并进同一 dylib,共用配置与开关。注意既有音频系统钩子的卡死问题(4.5),并入时一并排查。

---

## 7. 🕳️ 防坑清单

1. **mediaserverd 换帧要保原格式** → 就地覆盖(不新建 buffer、不改尺寸/格式)最稳,避 CMCapture 断言(4.6)。
2. **配置别放 /var/mobile 或 /var/tmp** → mediaserverd 读不到(4.4)。放 `/var/mobile/Media/`。
3. **解码器别强制输出格式** → 1100(4.3)。NULL destAttrs。
4. **没反向隧道别指望拉到流** → `tcp connect failed`(4.2)。
5. **别输出黑屏/冻结** → 任何失败 fail-open 调 orig。最高铁律。
6. **别与闭源 vcamera 同装** → 双重 hook。`Conflicts/Replaces` 已做。
7. **原生相机录像是最危险场景** → 谨慎;音频钩子卡死是既有问题(4.5),排查音频并入时留意。
8. **RTMP 网络输入保持有界** → msg 8MB cap / csid 界 / AMF bounds 已有,保持。
9. **VCamLog 跨 .m/.mm 用 C 链接**(VCamLog.h extern "C"),否则链接报 undefined symbol。
10. **设备写操作先说明、可回退**;崩溃核查用 `idevicecrashreport -k`(只读)。

---

## 8. 设备交互规程

- USB SSH:`C:/iProxy/iproxy.exe 2222 22` → `plink -ssh -batch -hostkey SHA256:kBdKmvWdBoghcXNaoWFmq6/llHh4k5tkLfSYQJDWYUI -P 2222 -pw <config.ini SSHPassword> root@127.0.0.1 '<命令>'`。
- 传 deb:`plink ... "cat > /tmp/x.deb" < 本地deb`;装:`dpkg -i /tmp/x.deb`;重载:`killall -9 mediaserverd`。
- 反向隧道(拉流必需):`plink -N -R 127.10.10.10:1935:127.0.0.1:1935 -P 2222 -pw <pw> root@127.0.0.1`(后台常驻)。
- 日志:`C:/iProxy/idevicesyslog.exe | grep OpenVCam`(mediaserverd 写不了文件日志,只能 syslog)。
- 回退:`dpkg -r com.iosvcam.opencam && killall -9 mediaserverd`,或建 disable 文件(须在 Media 路径)。

---

## 9. 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M1** | mediaserverd 注入 + BW hook + 拉流解码 + 就地覆盖 | ✅ 已完成 |
| **M2** | OBS 画面显示在 RootHide 化 TikTok | ✅ 已验证 |
| **M3** | 配置(mirror/旋转/kill-switch)从 `/var/mobile/Media/` 生效 | 🔶 进行中(6-a/6-b) |
| **M4** | 稳定性(连续录制不崩)+ 人脸检测确认 + 拍照(可选) | ⬜ 待做 |
| **M5** | 音频并入(视频+音频一个 deb) | ⬜ 待做 |

**推进节奏**:每步验证、汇报;动设备的写操作先说明、可回退。
