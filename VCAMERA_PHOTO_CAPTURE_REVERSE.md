# 逆向分析报告：原相机拍照如何拍成 OBS 画面

> 分析对象：`ios/modified_debs/iosvcam_base_127_10_10_10.deb` 内的闭源 `vcamera.dylib`
> （2,561,296 字节，FAT 二进制，slice 1 = arm64e，cputype `0x100000c` sub `0x80000002`）
> 分析工具：Python + capstone 5.0.7（Mach-O / ObjC 元数据解析 + arm64e 反汇编）
> 结论一句话：**它不 hook 快门，而是在 `mediaserverd` 的底层视频管线里把每一帧都换成 OBS 帧，拍照编码器拿到的本来就已经是 OBS 帧。**

---

## 1. 注入目标

`var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera.plist`：

```
{ Filter = {
    Bundles = ( "com.apple.mediaserverd", "com.apple.lskdd", "com.apple.springboard" );
    Executables = ( "mediaserverd" );
}; }
```

- **`com.apple.mediaserverd`** —— 核心。所有相机数据（预览 / 录像 / 拍照）都在此进程的 BufferWorks 图里流动。
- **`com.apple.lskdd`** —— 锁屏相关（LockScreen daemon）。
- **`com.apple.springboard`** —— 悬浮菜单 UI（登录、瘦脸/大眼滑块、Live 开关等）。

---

## 2. 总体数据流

```
OBS ──RTMP──▶ 127.10.10.10:1935
                │  dylib 内置 librtmp + polarssl(SSL),RtmpPull 类在设备侧主动拉流
                ▼
        RtmpPull ──▶ H.264 解码 (ifQwsadqYeweSwedHse / VTDecompressionSession)
                │
                ▼
   ifdsflwoWdasdYfsdfJd  (帧仓库 / frame store)
        - getFrame: / getLiveFrame: / getLocalFrame:
        - 生成 CMSampleBuffer（YUV / BGRA）
        - 可选 GPUImage 滤镜链：瘦脸 / 大眼 / 大鼻 / 大嘴 / 磨皮
                │
                ▼
   ┌──────── mediaserverd 的 BWGraph(BufferWorks)被 hook ────────┐
   │  BWNodeOutput  -emitSampleBuffer:        ◀── 每帧在这里被替换   │
   │  BW*Node       -renderSampleBuffer:forInput:                  │
   └───────────────────────────────────────────────────────────┘
                │
     ┌──────────┼───────────────────────┐
     ▼          ▼                        ▼
   预览取景框   录像                    拍照(静态图分支)
                                    BWStillImageScalerNode
                                    BWPhotoEncoderNode
```

**关键点**：预览、录像、拍照三条下游都从同一个被污染的 `BWGraph` 取数据。因此拍照保存的一定和取景框看到的是同一帧 —— 所见即所存。

---

## 3. Hook 安装器（构造函数）

安装器函数位于 arm64e slice 的 `0x78f00`。它对每个 Apple 私有类做：

```
objc_getClass("<类名>")           ; bl 0xa4178 = _objc_getClass
ldr x1, [selref]                   ; 目标选择器
adrp/add x16, <替换函数地址>        ; 本 dylib 内的替换实现
paciza x16                         ; arm64e 指针认证
mov x2, x16
bl  0xa3658                        ; = _MSHookMessageEx(class, sel, replacement, &orig)
```

`&orig`（原始实现指针）统一存放在 `0x125000` 段（`x3` 指向的 `0x4d8 / 0x4e0 / ...` 等槽位），替换函数末尾通过这些槽位调用原实现（尾调用 `blraaz` / `braaz`）。

被 `objc_getClass` 解析出来的相关类：

```
FigCaptureSessionConfiguration        BWGraph
FigCaptureClientSessionMonitor        BWNodeOutput
FigCaptureSourceConfiguration         BWPixelTransferNode
FigVideoCaptureConnectionConfiguration BWNode / BWUBNode
BWStreamingSessionAnalyticsPayload    BWStillImageScalerNode   ◀ 拍照
                                      BWPhotoEncoderNode       ◀ 拍照
                                      BWMetadataSourceNode
                                      BWMetadataDetectorGatingNode
                                      BWVideoOrientationMetadataNode ◀ 方向
```

---

## 4. 视频帧替换核心（预览/录像/拍照共用）

### `BWNodeOutput -emitSampleBuffer:` 替换函数 @ `0x79980`

反汇编要点：

```asm
0x79980  pacibsp
...
0x799b4  mov  x0, x2            ; x2 = 原始 CMSampleBuffer
0x799b8  bl   #0xa3468          ; 取 imageBuffer
0x799bc  cbz  x0, #0x79abc      ; 无 imageBuffer → 直接走原实现
...
0x799f0  ldr  x0, [x26, #0xbd0] ; 全局帧仓库单例
0x799f4  bl   #0xa9b40
0x799f8  bl   #0xa4128
0x799fc  mov  x24, x0
0x79a00  bl   #0xa6500          ; 检查是否有可用 OBS 帧 (hasFace / live 状态)
...
; 时间节流：距上次 > 3.0s 之类的判定
0x79a1c  ldr  d0, [x25, #0x5b8]
0x79a24  ldr  d1, [x8, #0x5d8]
0x79a28  fcmp d0, d1
0x79a54  fmov d0, #3.00000000
0x79a58  fcmp d8, d0
...
; 用 OBS 帧覆盖
0x79a80  ldr  x0, [x8, #0xb88]  ; live BGRA sample buffer
0x79a90  mov  x2, x22           ; width
0x79a94  mov  x3, x23           ; height
0x79a98  bl   #0xa93e0          ; setBGRASampleBuffer: / 换帧
...
0x79abc  ldr  x8, [x8, #0x4d8]  ; 原始 emitSampleBuffer: 实现
0x79ad0  blraaz x8              ; 调用原实现（把换好的帧继续往下游送）
0x79af4  retab
```

逻辑：拦截原始帧 → 从 OBS 帧仓库取一帧 → 若有新帧则替换 pixel buffer → **再调用原始实现**把替换后的帧继续送进 `BWGraph` 下游。因为这是所有相机消费路径的公共上游节点，预览、录像、拍照全部被覆盖。

同类还 hook 了 `renderSampleBuffer:forInput:`（`BWNode` 系列渲染入口），做同样的换帧。

---

## 5. 拍照专属分支（静态图路径）

除了公共换帧，dylib 还专门 hook 了**只在按下快门时才走**的 `BWStillImageScalerNode` / `BWPhotoEncoderNode` 私有方法，确保静态图这条独立分支的裁剪、方向、缩略图、深度图全部对齐 OBS 帧：

| 被 hook 的选择器 | 所在节点 | 作用 |
|---|---|---|
| `_generatePreviewForSampleBuffer:requestedStillImageCaptureSettings:cropRect:previewPixelBuffer:` | Photo | 快门后闪现的预览缩略图用 OBS 帧生成 |
| `_encodePhotoForEncodingScheme:pixelBuffer:imageDimensions:metadata:thumbnailOptions:requestedStillImageCaptureSettings:resolvedStillImageCaptureSettings:cropRect:usePixelsOutsideCrop:` | Photo | **真正编码要保存的 JPEG/HEIC 的那一帧** |
| `_addThumbnailForEncodingScheme:thumbnailPixelBuffer:metadata:...codecType:maxPixelSize:` | Photo | 相册缩略图 |
| `_addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:stillImageSettings:processingFlags:embedThumbToCompressedImage:` | Photo | 辅助图（深度/景深）无重载 |
| `_addAuxImagesIfNeededForEncodingScheme:sampleBuffer:metadata:stillImageSettings:scaleFactor:processingFlags:embedThumbToCompressedImage:` | Photo | 辅助图（带 scaleFactor 重载） |
| `initWithOrientation:sequenceNumber:duration:rotationDirection:` | BWVideoOrientationMetadataNode | 修正 OBS 帧方向（旋转方向元数据） |
| `appendMetadataSampleBuffer:` | Metadata | 同步方向/元数据 |
| `_zoomAttachedMediasOnSampleBuffer:normalizedInputCropRect:requestedSettings:scaleFactor:` | Scaler | 缩放/裁剪时保持 OBS 帧对齐 |

安装器中这些 hook 的反汇编片段（`0x79288`–`0x79368`）明确显示 `_generatePreviewForSampleBuffer:...`、`_encodePhotoForEncodingScheme:...`、`_addThumbnail...`、`_addAuxImages...` 依次被 `MSHookMessageEx` 挂上替换实现。

> 这也是版本记录里 0.3.8「录像 180°」、0.3.9「拍照方向」问题的根源所在 —— 就是 `initWithOrientation:...rotationDirection:` 与 `_encodePhoto` 分支上的方向处理。

---

## 6. 字符串佐证

从 `__cstring` 提取到的关键字符串：

```
[vc] getFrame 3 newSampleBuffer %@         ← 帧生成日志
[vc] newSampleBuffer %@
[vc] CVPixelBufferCreate %d
CMSampleBufferCreateReady %d
_liveBGRASampleBuffer                       ← OBS 帧转 BGRA 供拍照编码
setBGRASampleBuffer:
_kCMSampleBufferAttachmentKey_TransitionID  ← 拍照帧去重(TransitionID dedup)
_kVTPixelRotationPropertyKey_FlipVerticalOrientation
/var/mobile/Media/vcamera.txt               ← 配置/帧文件
/var/mobile/vc.plist                        ← RTMP 链接存储
http://127.10.10.10/I
rtmp://
```

---

## 7. 相关 ObjC 类（本 dylib 自带）

| 类 | 职责 |
|---|---|
| `RtmpPull` | 设备侧主动拉 RTMP 流 |
| `ifQwsadqYeweSwedHse` | H.264 解码（配置 SPS/PPS、VTDecompressionSession） |
| `ifdsflwoWdasdYfsdfJd` | **帧仓库**：getFrame/getLiveFrame/getLocalFrame、生成/缓存 CMSampleBuffer、滤镜入口 |
| `Helper` | 总控：登录、连接、outputVideo/outputAudio、分辨率、HUD |
| `ClientSocket` / `ServerSocket` | 网络 |
| `GPUImage*`(一整套) | 瘦脸/大眼/磨皮等实时美颜滤镜 |
| `FaceDetector` | Vision 人脸关键点（配合美颜） |
| `MenuViewController` / `FaceTableViewController` / `CustomPresentation` / `iHsfaTkdhwkzopQfsnwBd`(悬浮球) | SpringBoard 端 UI |

---

## 8. 为什么必须在 mediaserverd 层做

在 `mediaserverd`（而非相机 App）里换帧，是唯一能同时骗过系统相机、TikTok 等**所有**相机消费者的层级：

1. 静态图编码器 `BWPhotoEncoderNode` 拿到的 pixelBuffer 来自同一个被污染的 `BWGraph`；
2. 拍照与预览看到的是同一帧数据，天然一致；
3. App 层 hook 在 RootHide 沙箱化的 TikTok 上会失败，mediaserverd 是必经之路。

这正是本仓库开源版 `ios/open_vcam_tweak`（com.iosvcam.opencam）采用同样 mediaserverd BW-graph 策略的原因。

---

## 附：与 OpenVCam 的对照建议

若要给 OpenVCam 补齐拍照分支，重点复刻：
1. `BWNodeOutput -emitSampleBuffer:` + `renderSampleBuffer:forInput:` 的公共换帧（已实现）；
2. **拍照独立分支**：`_encodePhotoForEncodingScheme:...`（保存帧）、`_generatePreviewForSampleBuffer:...`（快门预览）、`_addThumbnail.../_addAuxImages...`（缩略图/深度图）；
3. 方向：`BWVideoOrientationMetadataNode -initWithOrientation:sequenceNumber:duration:rotationDirection:` + `appendMetadataSampleBuffer:`；
4. 去重：`_kCMSampleBufferAttachmentKey_TransitionID`（真实 TransitionID 去重，避免同一张连拍多帧）。

---

## 9. GPU 同步模型（针对 IOFence 死锁的静态逆向，2026-07-07）

**背景问题**：OpenVCam 在原相机**拍照模式**下"动一下就卡死"，崩溃包 `bug_type 284 iofence`：单块相机 IOSurface 上 3 个 GPU accelerator(0/1/2) 在 fence 队列互等。用户判断：我们用 `VTPixelTransferSessionTransferImage` 往相机活 surface 提交 GPU 写命令，与采集图自己的 GPU 队列在同一 surface 上交叉成环，CPU 锁管不到 OS 的 GPU 队列。

**静态逆向原版会话配置块（arm64 slice，`0x82470–0x8267c`，逐指令读出）**：

原版 init 时**一次性**建 3 个 `VTPixelTransferSession` + 1 个 `VTPixelRotationSession`，每个 transfer session 设完全相同的 5 个属性：

| 属性 | 值 | OpenVCam 现状 |
|---|---|---|
| `EnableGPUAcceleratedTransfer` | **`kCFBooleanTrue`**（GPU 开） | 未设（默认开）→ 一致，**排除"关 GPU"是原版的解法** |
| `ScalingMode` | **`kVTScalingMode_Trim`**（裁剪保宽高比） | `kVTScalingMode_Normal`（拉伸）→ **不同** |
| `DestinationColorPrimaries` | `ITU_R_709_2` | 一致（解码回调打附件） |
| `DestinationTransferFunction` | `ITU_R_709_2` | 一致 |
| `DestinationYCbCrMatrix` | **`ITU_R_601_4`** | 一致 |

旋转 session：`kVTPixelRotationPropertyKey_Rotation = kVTRotation_CCW90`（=270°，印证 OpenVCam 自适应方向取 270 是对的）+ `EnableGPUAcceleratedTransfer=true`。

**关键差异与死锁假设**：
1. **原版 GPU 加速也是开的**——所以死锁不是靠"CPU 软件转换"绕开的。
2. 原版导入并**大量调用 `glFinish`（14 处）+ `CVOpenGLESTextureCacheFlush`**，走完整 GPUImage/OpenGL 渲染链，每次渲染后 `glFinish` 强制 GPU 全部完成再返回——**没有悬空的异步 GPU 写命令**留在 surface 上与采集图 fence 交叉。OpenVCam 的 `VTPixelTransferSessionTransferImage` 提交后立即返回（异步），留下待决 GPU 写 → 与采集图读命令 fence 成环。
3. 原版 session **一次建好复用**、旋转 session 独立；疑似**每解码帧只旋转一次存预转 buffer**，每次 emit 只做**一个** transfer pass。OpenVCam 每帧 `VCamCopyRotated`(旋转 GPU pass) + `VTPixelTransferSessionTransferImage`(转换 GPU pass) = **每帧两个 GPU pass**，拍照模式高负载下 fence 冲突翻倍。

**可测的修复方向（按优先级）**：
- (a) transfer 后强制 GPU 同步：对目标相机 buffer 做 `CVPixelBufferLockBaseAddress`/`Unlock`（迫使 GPU 完成），或改走 OpenGL + `glFinish`，消除悬空 GPU 写。← 最贴合原版证据
- (b) 每帧只留一个 GPU pass：解码时预转一次（存旋转好的源帧），emit 时直接 transfer，不再每帧 `VTPixelRotationSession`。
- (c) `ScalingMode` 改 `Trim`（次要，画面比例问题，非死锁）。

**待动态逆向确认**：装原版 deb，抓 `[vc]` syslog + 观察拍照模式是否真的不卡（同机同设置），确认 (a)/(b) 哪个是主因。
