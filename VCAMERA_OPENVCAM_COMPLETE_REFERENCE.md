# vcamera 逆向 + OpenVCam 复刻 · 完整技术与逆向参考

> **本文件是唯一权威技术文档**，合并并取代了历史上的：
> `VCAMERA_DEB_REVERSE_ANALYSIS.md`、`VCAMERA_PHOTO_CAPTURE_REVERSE.md`、
> `VCAMERA_DEB_REPLICATION_ROADMAP.md`、`ios/open_vcam_tweak/EXECUTION-PLAN.md`、
> `ios/open_vcam_tweak/README.md`（技术部分）。
>
> 逆向原始产物保留在 `_re_static/`（反汇编/字符串/类表）与 `_orig_vcamera.dylib`（原版二进制）。
>
> 最后更新：2026-07-09（含完整"暗场景照片偏红"攻关全过程）。

---

## 0. 一句话总览

`com.x.vcamera`（闭源, 作者 kox, 0.0.1-1922）与本仓库 `com.iosvcam.opencam`（OpenVCam, 开源复刻）都通过**注入 `mediaserverd`**、在 CoreMedia 采集图（BufferWorks / `BW*` 节点）里**就地覆盖相机自己的 `CVImageBuffer`（共享 IOSurface）**为解码后的 OBS/RTMP 帧，再原样下发 sampleBuffer——因此所有相机客户端（系统相机、TikTok、任意 App）的**预览/录像/拍照**看到的都是 OBS 画面。

**当前状态**：OpenVCam 的视频 + 拍照（明亮场景）替换已与原版**完全对等**。唯一未跨越的是**暗场景保存照片偏红**——经彻底逆向确认为 iOS16 计算摄影 + 沙盒的固有代价（原版同样偏红，见 §5）。稳定版 = **0.5.9**。

---

## 1. 设备与越狱环境（实测基线）

| 项 | 值 |
|----|----|
| 机型 | iPhone13,2（iPhone 12, D53g，非 mini） |
| 系统 | iOS 16.1.2（20B110）/ Darwin 22.1.0 `RELEASE_ARM64_T8101` |
| 越狱 | **Dopamine + RootHide**（`/var/jb` 是 `/` 的符号链接；`/.procursus_strapped`；ElleKit） |
| 注入引擎 | **ElleKit**，**只扫描 `/usr/lib/TweakInject`**（rootless `/var/jb` deb 需镜像到此处才注入） |
| 设备 shell | zsh；**无** `ps/lsof/vmmap/frida/cycript/sqlite3/nc`（`ps` 被 stub → 用 `launchctl list`）；**有** `netstat/plutil/launchctl` |
| SSH | `root@127.0.0.1:2222`（经 iproxy USB 隧道），口令 `@Zkhack06` |

### 🔒 铁律（务必遵守）
- **只读设备**：只 `cat/ls/netstat/idevicesyslog/launchctl` 观测，**绝不** respring / 装包 / 改任何设备文件（一次 respring 曾破坏 tweak 注入）。设备改动（装 deb、开相机）一律由**用户**操作。
- **绝不 `killall mediaserverd`**：会churn解码池 + 掉注入，给出假失败症状。
- **RootHide SSH 是 fs-jail**：`/var/mobile/Media`（相册、DCIM）**看不到**，无法经 plink 拉取存图 → 让用户导出 HEIC。
- **日志会撑爆磁盘**：曾把 E: 写满到 100%（多 GB `logs/plink-tunnel-*.log`）；抓 idevicesyslog 要限时、限量、用完即删。
- **保存照片的元数据必须与真实拍摄一致**：任何修法只改像素，**绝不**编辑/伪造 EXIF。

---

## 2. 闭源 vcamera 逆向（静态 + 动态，2026-07-07/08）

### 2.1 deb 结构与注入过滤器
标准 Debian 2.0 `ar` 三成员（`debian-binary` / `control.tar.gz` / `data.tar.lzma`，**LZMA-alone 非 XZ**，iOS dpkg 要求）。payload 仅 `vcamera.dylib`（FAT arm64+arm64e, 2.44 MB）+ `vcamera.plist`。`postinst: killall -9 mediaserverd`。

```
vcamera.plist Filter:
  Bundles     = ( com.apple.mediaserverd, com.apple.lskdd, com.apple.springboard )
  Executables = ( mediaserverd )
```
- **mediaserverd**：换帧引擎（相机数据流所在进程）。
- **SpringBoard**：设置 UI（RTMP 链接、Live 开关、美颜滑杆、人脸库）。
- **com.apple.lskdd**：非标准 Bundle，设备上未见活动，判为冗余/历史项。

> `_orig_vcamera.dylib` 与 deb payload 字节完全一致（SHA256 `08d76f48…`）。原版 deb 主控 = `ios/iosvcam_base.deb`（作者 kox；**注意有序列号+到期授权锁**：读 MobileGestalt、`/var/mobile/Media/vcamera.txt`，原版突然失效先怀疑到期）。

### 2.2 核心机制：就地覆盖（灵魂）
`-[BWNodeOutput emitSampleBuffer:]` → `-[引擎 modifyImageBuffer:]`（引擎类混淆名 `ifdsflwoWdasdYfsdfJd`）：

```objc
- (void)modifyImageBuffer:(CMSampleBufferRef)cam {
    if (!self.enabled || !self.liveSampleBuffer) return;
    [self.lock lock];                                          // 单锁：覆盖整个过程
    CVImageBufferRef dst = CMSampleBufferGetImageBuffer(cam);  // ★相机自己的 IOSurface
    CVImageBufferRef src = CMSampleBufferGetImageBuffer(self.liveSampleBuffer); // OBS 解码帧
    if (需要旋转) src = 旋转到 self.rotatedBuffer(复用同一块) via VTPixelRotationSessionRotateImage;
    VTPixelTransferSessionTransferImage(self.pixelTransferSession, src, dst); // ★★就地覆盖★★
    [self.lock unlock];
}
// emit hook 随后把【原样 cam】继续下发 —— 上游共享 IOSurface 已被改写
```
**要点**：不造新 buffer、不换下游指针 → 预览/录制/拍照/第三方 App 全读到改写结果。App 预览读的是**上游共享 surface**；造新 buffer 传下游根本到不了预览（这是 OpenVCam 早期的错误，已纠正）。

### 2.3 Hook 面（BufferWorks 图）
| 被 hook 类 | 选择子 | 作用 |
|-----------|--------|------|
| **BWNodeOutput** | **`emitSampleBuffer:`** | ★唯一真正改帧的 hook（→ `modifyImageBuffer:`） |
| BWPixelTransferNode / BWNode / BWUBNode | `renderSampleBuffer:forInput:` | **直通（不改）**——就地覆盖它们=录制崩溃路径 |
| BWStillImageScalerNode | `renderSampleBuffer:forInput:`、`_zoomAttachedMediasOnSampleBuffer:…` | 拍照缩放链 |
| BWPhotoEncoderNode | `_encodePhotoForEncodingScheme:pixelBuffer:…`（★真正编码保存的那帧）、`_generatePreviewForSampleBuffer:…`、`_addThumbnail…`、`_addAuxImages…` | 拍照编码链 |
| BWVideoOrientationMetadataNode | `initWithOrientation:sequenceNumber:duration:rotationDirection:`、`appendMetadataSampleBuffer:` | 方向元数据 |
| FigCaptureSourceConfiguration | `sourcePosition` | 判前/后置（前置自动镜像） |

> **决定性再逆向（2026-07-09）**：原版这 8 个拍照/静态 hook **全是 pass-through**，只有 `emitSampleBuffer:→modifyImageBuffer:` 真正改帧，`modifyPixelBuffer:` 是死代码。即拍照出 OBS 是**共享面继承**（拍照编码器读的是已被 emit 改写的同一上游 surface），不是靠拍照节点。→ OpenVCam 默认 `VCAM_HOOK_PHOTO_NODES=0`（不 hook 拍照节点，避免死锁）。

### 2.4 GPU 同步模型（IOFence 死锁的关键）
原版 init 一次性建 **3 个 `VTPixelTransferSession` + 1 个 `VTPixelRotationSession`**，每个 transfer session 五属性完全相同：

| 属性 | 值 |
|---|---|
| `EnableGPUAcceleratedTransfer` | `kCFBooleanTrue`（GPU 开——**排除"关 GPU"是解法**） |
| `ScalingMode` | `kVTScalingMode_Trim`（裁剪保宽高比） |
| `DestinationColorPrimaries` / `TransferFunction` | `ITU_R_709_2` |
| `DestinationYCbCrMatrix` | `ITU_R_601_4` |

旋转 session：`Rotation = kVTRotation_CCW90`（270°）。
- 单锁原子"旋转+transfer"、旋转复用**同一块** buffer、每帧**一个** transfer pass。
- **freeze 根因**：OpenVCam 早期每帧两个 GPU pass + 缺 dedup → 每帧向共享 IOSurface transfer ~10 次 → GPU fence 过载 → 变量帧数（24/210/249）后 wedge。**已修**：按 `kCMSampleBufferAttachmentKey_TransitionID`（后改私有 key）去重，一帧一次。

### 2.5 RTMP / 解码 / 其它能力（静态确证）
- **自带 RTMP/TLS 栈**：静态链接 **librtmp + mbedTLS**，走裸 socket（`CFSocket` + `CCCrypt/CC_SHA256` 握手）；拉流地址来自 `/var/mobile/vc.plist` 的 `rtmp` 键。
- **解码**：`VTDecompressionSession`（`RealTime=true` + `ThreadCount=2`，SPS/PPS 不变复用会话）。
- **美颜**：Vision 人脸关键点 → GPUImage 滤镜链（磨皮/瘦脸/大眼），预设存 SQLite `/var/mobile/Media/bkb.db`。**只给了滤镜类名，无参数/着色器 → 不可忠实复刻**。
- **本地视频源/录制**：AVAssetReader / AVAssetWriter（`b.mov`）。
- **设置 UI**：注入 SpringBoard，UIKit 自绘（`MenuViewController` 等）。
- **去品牌**：授权基址 `https://www.bkatm.com` 被等长空格填充改成 `https://localhost`。

### 2.6 端到端链路（动态实测）
```
PC: OBS ─▶ SRS(:1935/live/srs)
        │ USB (iproxy 2222→22 / plink -R 127.10.10.10:1935)
iPhone: 设备端 sshd 反向隧道监听 127.10.10.10:1935
        │
mediaserverd(vcamera): RtmpPull(librtmp) ─▶ H.264 ─▶ VTDecompress ─▶ 帧仓
        └─▶ [BWNodeOutput emitSampleBuffer:] hook ─▶ 就地覆盖相机 IOSurface ─▶ 原样下发
                └─▶ 预览 2304×1728 / 录像 1280×720 / 拍照 4224×3168 / TikTok 1280×720  全部=OBS
```
实测：256s 窗口 23020 条换帧日志、9288 个不同 IOSurface 地址被循环覆盖；mediaserverd 全程不崩不重启。

---

## 3. OpenVCam 架构（开源复刻，`ios/open_vcam_tweak/`）

### 3.1 文件结构
```
Tweak.xm               mediaserverd hook（emit 就地覆盖 + sourcePosition 镜像）+ 日志 + 看门狗
VCamConfig.{h,m}       配置（mediaserverd 沙盒下回退编译默认值）
VCamRTMPSource.{h,mm}  RTMP 拉流线程 + FLV/AVC 解析 + 重连
VCamH264Decoder.{h,mm} VideoToolbox 解码（dstAttrs/RealTime/ThreadCount + ITU 色彩）
VCamFrameStore.{h,m}   线程安全最新帧 + 看门狗（maxAge 0.5s）
VCamAudioMS.x          全局 mediaserverd 音频（AudioUnitRender 替换）——【故意不编入】见 §6
vendor/rtmp/vcam_rtmp.{h,c}  自写精简 RTMP play 客户端（无外部依赖）
OpenVCam.plist         注入 filter（mediaserverd）
Makefile / control / layout/DEBIAN/*
```

### 3.2 关键实现点
- **注入点** `mediaserverd`（在所有相机客户端之下 → 覆盖 RootHide 化的 TikTok / 系统相机 / 所有 App；app 级注入会被 RootHide 绕过，**必须**在这一层）。
- **视频替换**：只 hook 终端 `BWNodeOutput -emitSampleBuffer:`（一帧一次），`VCamOverwriteInPlace` 经 `VTPixelTransferSession`(+前摄/旋转 `VTPixelRotationSession`)就地写相机共享 IOSurface，再传**原始 sample buffer** 给原实现。中间 render 节点**一律不 hook**。
- **拍照**：不需要专门 hook（共享面继承）；`VCAM_HOOK_PHOTO_NODES` 默认 **0**。
- **前后摄自动镜像**：hook `FigCaptureSourceConfiguration -sourcePosition`。
- **横屏门 + 无 dedup**（0.5.9）：只覆盖 `w≥h` 的横屏 buffer（原版如此），竖屏预览继承共享面；视频路径 `VCAM_VIDEO_DEDUP=0`（修 sharp/blur 循环）。

### 3.3 配置与沙盒（重要限制）
`mediaserverd` 沙盒**读不到** `/var/mobile/vc.plist`、`/var/tmp`、`/var/mobile/Media`，故 `VCamConfig` 只用**编译默认值**（`rtmp://127.10.10.10:1935/live/srs`, enabled=YES，恰好等于工作隧道地址 → 无需配置即出画）。自定义 RTMP/mirror/rotation 在本进程**不生效**；开关只能靠卸载或未来的 Darwin notify 通道。

### 3.4 依赖与前置
- **network-cmds**（越狱包）：提供 `/usr/sbin/ifconfig` → 创建 dylib 连接用的 `127.10.10.10` lo0 别名。**无它设备连不上 PC**。OpenVCam control 已 `Depends`。
- **USB 反向隧道**：PC SRS + `plink -R 127.10.10.10:1935` 经 iproxy；由启动器 U 模式自动建。
- **RootHide 注入**：dylib 必须镜像到 `/usr/lib/TweakInject`（0.5.3 起 postinst/postrm 感知 `/var/jb→/` 符号链接，避免幻影安装/self-delete）。

### 3.5 安全 / 恢复
- **fail-open**：任何环节失败一律透传真实相机，永不黑屏/冻结；解码帧超 0.5s 没更新自动透传。
- **禁用/恢复**：`dpkg -r com.iosvcam.opencam && killall -9 videodecoderd`（沙盒读不到 `vc.disabled` 文件开关）。
- **解码器 1100** = 系统解码会话池被 SIGKILL 耗尽 → `killall -9 videodecoderd` 重置（postinst 已带）。
- `Conflicts/Replaces com.x.vcamera` 及旧音频包，避免双重注入。

---

## 4. 视频卡顿（已解决）与色彩

- **"OBS 画面很卡" = 服务端 SRS 缓冲问题，不是 tweak 解码**。用 `config/active/srs_iphone_lowlatency_sync.conf`（`mw_latency 100`（原 500）、`queue_length 3`、`mw_msgs 1`、`tcp_nodelay+min_latency`，保留 `gop_cache on` 首帧不花屏 + `time_jitter full` 平滑）。不要去 tweak 里加解码计数器找这个。
- **色彩**：写入 + tag 的目标 YCbCr 矩阵统一由 `VCamDestMatrix` 出（默认 601）。`VCAM_STAMP_DEST=0`（默认）——原版只 tag 自己的**源**帧、从不 tag 目标；给 P3 静态 buffer 打 709 tag 会让延迟管线重新色彩管理成红（历史 bug，已关）。

---

## 5. 暗场景保存照片偏红 —— 完整攻关（2026-07-09）

### 5.1 症状与对等结论
- 症状：拍照后**预览正常**、点开也正常，**前后滑动看旧照片再划回来 → 偏红，且"结构也不是那一帧了"**。
- **决定性 A/B**：装回原版、同一暗环境拍摄——**明亮场景两版皆正常；暗场景原版同样偏红、同样"划回来变红/结构变"**。→ **偏红不是 OpenVCam 的 bug，是注入 + iOS 计算摄影的固有代价，OpenVCam 已与原版对等。**

### 5.2 逐层排查（全部设备验证）
| 尝试 | 结果 |
|---|---|
| dest-stamp 709 是元凶？ | ❌ 0.5.7 去掉 dest stamp，仍红（红在像素，不在 tag） |
| 601/709 矩阵冲突？ | ❌ 配置与原版字节一致；矩阵无关 |
| 强关延迟（`FigCaptureStillImageSettings setAutoDeferredProcessingEnabled:NO`，0.6.0） | ❌ **搞崩拍照**：相机 App 已按 deferred 配好 proxy/final 尺寸+bracket，中途谎报 NO → 管线自相矛盾 → 拍照出错不保存 + mediaserverd 打嗝。放弃强改设置。 |
| emit 尺寸探针（0.5.11） | 4224×3168 静态帧**确实**流经 emit、我们**已覆盖**（proxy 正常来源于此）；覆盖率与原版同量级 |
| hook Deep Fusion 输出 / deferred 完成（mediaserverd, 0.6.1/0.6.2） | ❌ **在 mediaserverd 里从不触发** → 红图不在此进程生成 |
| **全量日志**（不过滤） | 🎯 红图由 **`deferredmediad`** 守护进程渲染 |

### 5.3 根因（决定性）
暗场景保存图的**最终 HEIC 由 `deferredmediad` 守护进程**（非 mediaserverd）渲染。日志铁证（全在 `deferredmediad`）：
```
<<<< BWDeepFusionProcessorController >>>> _process: Finished Deep Fusion processing (err:0)
dfp_addBuffer: Adding buffer of type (0..4) for captureID:14        ← 喂入 5 帧融合 bracket
<<<< FigCaptureDeferredPhotoProcessor >>>> job:completedWithSampleBuffer:: completed (took 1010 ms)
<<<< BWPhotoEncoderNode >>>> renderSampleBuffer:forInput:: Encoding image ... outputDims:4032x3024
+ NRF/AMBNR(降噪) + ToneMapping(SRLv1) 阶段  ← 暗光多帧融合 + 真实场景白平衡/色调 = 红
```
proxy（立即代理图）= 我们覆盖的参考帧 = OBS = 正常；**final** 由 deferredmediad 用**存储的真实暗帧 bracket**重新融合 → 红 + 结构变。

### 5.4 为何修不了（沙盒硬墙）
- ✅ 把 OpenVCam **注入 deferredmediad 可行**（改 `OpenVCam.plist` Executables 加 `deferredmediad`）、我们的 hook（`job:completedWithSampleBuffer:`、`BWPhotoEncoderNode renderSampleBuffer:forInput:`）在那里**确实触发**、最终图 4224×3168。
- ❌ 但 **`deferredmediad` 的沙盒禁止外联网络**：其内的 RTMP 拉流 `tcp connect failed`（mediaserverd 连同一地址成功、deferredmediad 失败 = 进程级沙盒），拿不到 OBS 像素 → 覆盖时 `no OBS frame` → 照旧红。
- ❌ 我们在 mediaserverd 给覆盖后的静态帧打的 `VCamOBS` 传播标记**不跨进程**（deferredmediad 里 `obsMark=0`）→ "复用 EV0 参考帧"方案也死。
- 剩余理论路（都高风险/大工程且未做）：跨进程共享 OBS 像素（IOSurface+mach端口 / 共享内存 / 共享文件，均受两套沙盒阻挡）、或在 mediaserverd 端逆向找到存 bracket 的节点并覆盖（实时线程 GPU 死锁风险）。

### 5.5 结论
**原版也跨不过这道墙**（暗场景同样红）→ **0.5.9 对等即为上限**，暗红作为 iOS 计算摄影 + `deferredmediad` 沙盒的固有代价接受归档。完整注入/逆向链路存于 `boylove` 远端分支：`build/openvcam-{deferred-probe, emitsize-probe, nodedump-probe, 0.6.1-deferredfinal, deferredmediad-probe, 0.6.4-deferredfix}`。

---

## 6. 音频（下一阶段：OBS 音频替换/覆盖）

- `VCamAudioMS.x` 已写好（全局 `mediaserverd` `AudioUnitRender` 替换，从 `ios/audio_bridge_media_active_tweak` 并入），但**故意不编入 Makefile**：本机（Dopamine iOS16.1.2）上"mediaserverd 全局音频 + 原生相机拍照↔录像切换"曾是高危崩溃路径，历史上音频桥影响过本机相机环境。
- **计划**：待视频稳定后，用 fail-open 思路把 OBS 音频替换编入。安全参考：`com.iosvcam.audiobridge` 0.3.5 曾在 TikTok 内加载、连 `127.10.10.10:1936`、产出 OBS 音频。**保留全部音频相关代码**。

---

## 7. 构建 / 测试 / 开发环路

### 7.1 CI 构建（GitHub Actions on `boylove` 远端）
```bash
# 改代码 → 提交 → 推到 boylove 的 build/** 分支触发 .github/workflows/build-open-vcam-tweak.yml
git push boylove <branch>
# 监控 + 下载产物 deb
CI_BRANCH=<branch> python scripts/ci_fetch.py status | wait | download <dir>
```
- 版本号在 `ios/open_vcam_tweak/control`（升版本让重装成为真正升级 → 触发 mediaserverd 重载）。
- `-Werror` 生效：`CVBufferGetAttachment` 已弃用 → 用 `CVBufferCopyAttachment`（+release）。
- 编译开关经 Makefile `ifdef` 透传（`VCAM_HOOK_PHOTO_NODES`、`VCAM_VIDEO_DEDUP`、`VCAM_DEBUG` 等）。

### 7.2 设备联调规程（只读）
- 隧道：启动器 **U 模式**建 `plink -R 127.10.10.10:1935` + 127.10.10.10 别名 + 修 sshd（`GatewayPorts clientspecified` / `AllowTcpForwarding yes`）。
- 抓日志：`C:\iProxy\idevicesyslog.exe -m OpenVCam`（**限时**写文件，用完即删；`[OpenVCam]` 前缀同时匹配 mediaserverd 与 deferredmediad 两进程）。
- **mediaserverd 不会因关/开相机 App 重启**（我们的 RTMP+心跳让它常驻）；一次性 `%ctor` 日志会滚走 → 需要重触发时把 dump 改成延迟 `dispatch_after` 派发，或用户重装（升版本）触发重载。
- 设备工具缺失：`ps` 被 stub → 用 `launchctl list`；`/var/mobile/Media` fs-jail 不可见 → 让用户导出 HEIC 做取证。

### 7.3 关键防坑清单
1. `mediaserverd` 沙盒读不到任何配置 → 只用编译默认值。
2. 反复 killall 后"不是 OBS" = 解码池耗尽（1100）→ `killall -9 videodecoderd`。
3. 中间 render 节点（`BWNode/BWUBNode/BWPixelTransferNode`）**绝不覆盖** = 原生相机录制崩溃路径。
4. 每帧只一个 transfer pass + dedup，否则 GPU IOFence wedge。
5. PowerShell here-string 双引号才展开变量；plink 反向隧道需跟 `cat`/sleep-loop 保活否则秒断。

---

## 8. 附录

### 8.1 逆向原始产物（保留）
| 路径 | 内容 |
|------|------|
| `_orig_vcamera.dylib` / `_orig_vcamera.plist` | 原版二进制 + 注入 plist（= deb payload） |
| `_re_static/analyze.py` `macho.py` `disas_*.py` | deb/Mach-O/符号解析 + arm64e 反汇编器 |
| `_re_static/{cstrings,classnames,defined_classes,all_classes,engine_disasm}.txt` | 字符串/类/反汇编转储 |
| `ios/iosvcam_base.deb` | 原版 deb 主控（有到期授权锁） |
| `scripts/re_vcamera*.py` `re_xref.py` | 逆向脚本 |

### 8.2 版本脉络（OpenVCam）
- 0.5.3 修 RootHide 幻影安装/ellekit 破坏（符号链接感知）。
- 0.5.4 freeze fix（TransitionID dedup，一帧一次）。
- 0.5.5 恢复方向(CCW90) + 目标色彩(709/709/601)。
- 0.5.6 私有 dedup key 修 sharp/blur 循环 + VCamDestMatrix 统一色彩。
- 0.5.7 `VCAM_STAMP_DEST=0`（修存图红的第一层——停止 stamp 目标 buffer）。
- 0.5.8 per-path 矩阵（后证明明亮场景运气）。
- **0.5.9 = 稳定版**：去视频 dedup + 横屏门（修真实镜头渗漏/卡顿）。
- 0.6.x = 暗红攻关实验（§5，均归档于 boylove 分支，未合入）。

---

*本文档为合并稿；所有"实测/✅"项均在 iPhone13,2 / iOS16.1.2 / RootHide 上现场观测（2026-07-07 ~ 2026-07-09）。*
