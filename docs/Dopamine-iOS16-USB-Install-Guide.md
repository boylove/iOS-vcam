# iOS-VCAM Dopamine iOS 16 USB 安装配置教程

本文档记录一次已验证成功的安装流程：Windows 电脑通过 USB 连接 Dopamine 越狱 iPhone，OBS 推流到本机 SRS，iPhone 通过 SSH 反向隧道从 `127.10.10.10:1935` 拉取视频，最终手机端可看到 OBS 画面。

验证环境：

- Windows 10/11
- iPhone iOS 16.1.2
- Dopamine/rootless 越狱
- OpenSSH 已安装
- USB 连接，手机已信任电脑
- iOS-VCAM deb 已安装

不要把 SSH 密码、UDID、主机指纹写进公开仓库。本文命令使用占位符：`<UDID>`、`<SSH_PASSWORD>`、`<HOSTKEY_SHA256>`。

## 当前推荐启动方式

当前项目保留一个实际启动脚本 `iOS-VCAM-Launcher.ps1`，并提供一个可双击的批处理包装器 `iOS-VCAM-Launcher.bat`。推荐直接双击：

```text
iOS-VCAM-Launcher.bat
```

也可以从 PowerShell 启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\iOS-VCAM-Launcher.ps1
```

进入菜单后选择 `[U] USB STREAMING`。新版 USB 流程默认使用：

```text
config\active\srs_usb_smooth_playback.conf
```

也就是 `Flask + SRS + iproxy + plink 反向 SSH 隧道`。当前主目录已经整理完成，默认使用 `tools\iproxy.exe` 和根目录的 `plink.exe`。

## 一、整体原理

数据流：

```text
OBS 或其他推流软件
  -> rtmp://localhost:1935/live/srs
  -> Windows SRS
  -> plink SSH 反向隧道
  -> iPhone 127.10.10.10:1935
  -> iOS-VCAM tweak/app
  -> 手机虚拟摄像头画面
```

需要两个 iPhone 端监听地址：

```text
127.10.10.10:80    -> Windows 127.0.0.1:80    Flask auth
127.10.10.10:1935  -> Windows 127.0.0.1:1935  SRS RTMP
```

`127.10.10.10` 是这个项目给 USB 模式使用的固定地址。手机重启后 loopback alias 会丢失，需要重新执行配置。

## 二、电脑需要的软件

### 1. iOS-VCAM 项目

下载地址：

```text
https://github.com/LiuSky/iOS-vcam
```

本教程假设项目目录为：

```powershell
E:\python code\iOS-vcam
```

目录中需要有：

```text
iOS-VCAM-Launcher.ps1
server.py
plink.exe
pscp.exe
objs\srs.exe
ios\open_vcam_tweak\
config\active\srs_usb_smooth_playback.conf
```

### 2. Python

下载地址：

```text
https://www.python.org/downloads/windows/
```

安装时勾选 `Add Python to PATH`。

验证：

```powershell
python --version
```

安装 Flask：

```powershell
python -m pip install flask
```

### 3. Apple USB 驱动

任选一种：

- 安装 Microsoft Store 的 Apple Devices
- 安装 iTunes

目的：让 Windows 能通过 USB 识别 iPhone。

### 4. libimobiledevice / iProxy

当前仓库已经把 Windows 便携工具放在 `tools` 目录，至少需要：

```text
tools\iproxy.exe
tools\idevice_id.exe
```

PuTTY 工具放在项目根目录：

```text
plink.exe
pscp.exe
```

换电脑时可以直接运行：

```powershell
.\tools\idevice_id.exe -l
```

如果能输出 UDID，说明便携工具可用。注意：Apple USB 驱动仍然必须在新电脑安装一次，不能只靠复制 exe/dll 完成。

推荐下载/安装方式：

方式 A：Chocolatey 安装，最省事。

Chocolatey 官网：

```text
https://chocolatey.org/install
```

libimobiledevice 包页面：

```text
https://community.chocolatey.org/packages/libimobiledevice
```

管理员 PowerShell 执行：

```powershell
choco install libimobiledevice
```

安装后查找工具位置：

```powershell
where.exe iproxy
where.exe idevice_id
```

如果某些旧脚本要求固定在 `C:\iProxy\`，可以复制过去：

```powershell
New-Item -ItemType Directory -Path C:\iProxy -Force
Copy-Item (where.exe iproxy | Select-Object -First 1) C:\iProxy\iproxy.exe -Force
Copy-Item (where.exe idevice_id | Select-Object -First 1) C:\iProxy\idevice_id.exe -Force
```

方式 B：下载 Windows 预编译工具包。

可从 libimobiledevice Windows 构建项目下载包含 `iproxy.exe`、`idevice_id.exe` 的压缩包：

```text
https://github.com/libimobiledevice-win32/imobiledevice-net/releases
```

下载 release 里的 Windows zip 包后，解压，找到：

```text
iproxy.exe
idevice_id.exe
```

然后放到本项目：

```text
tools\
```

方式 C：只用 3uTools 的 SSH Tunnel。

3uTools 下载地址：

```text
https://www.3u.com/
```

3uTools 的 `Toolbox -> Open SSH Tunnel` 也能把 iPhone SSH 转发到本机端口，但本教程后续命令默认使用 `.\tools\iproxy.exe`。如果使用 3uTools，需要确认它实际监听的是 `127.0.0.1:2222` 还是其他端口，并把后续命令里的 `-P 2222` 改成对应端口。

验证手机 UDID：

```powershell
.\tools\idevice_id.exe -l
```

能输出一行 UDID 即可。

### 5. PuTTY 工具

项目根目录已经包含：

```text
plink.exe
pscp.exe
```

如果缺失，从 PuTTY 官方下载：

```text
https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html
```

### 6. OBS

下载地址：

```text
https://obsproject.com/download
```

OBS 推流设置：

```text
Server: rtmp://localhost:1935/live
Stream Key: srs
```

如果软件只支持单个 RTMP 地址，填写：

```text
rtmp://localhost:1935/live/srs
```

## 三、手机需要的软件

### 1. Dopamine 越狱

Dopamine 项目地址：

```text
https://github.com/opa334/Dopamine
```

本教程面向 Dopamine/rootless 环境。iOS-VCAM tweak 应安装到：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

### 2. Sileo 或其他包管理器

Dopamine 通常自带 Sileo。后续软件建议通过 Sileo 安装。

### 3. OpenSSH

在 Sileo 中搜索并安装：

```text
OpenSSH
```

安装后建议修改 root 密码：

```sh
passwd
```

默认密码通常是 `alpine`，但强烈建议改掉。

### 4. network-cmds

在 Sileo 中搜索并安装：

```text
network-cmds
```

这个包提供：

```text
ifconfig
netstat
route
```

USB 模式必须用 `ifconfig` 创建 `127.10.10.10` alias，用 `netstat` 验证隧道监听。如果没有安装，`plink -R 127.10.10.10:...` 会被拒绝。

验证：

```sh
command -v ifconfig
command -v netstat
```

期望输出类似：

```text
/usr/sbin/ifconfig
/usr/sbin/netstat
```

### 5. Filza，可选

如果不想用 SSH 安装 deb，可以用 Filza 在手机上打开并安装 deb。

Filza 可在常见越狱源中安装。

## 四、获取 OpenVCam deb

不再需要为每个 IP 单独生成 deb。OpenVCam tweak 的 RTMP 地址由手机端悬浮面板在运行时设置，一个包通用。从 CI 拉取最新构建：

```powershell
cd "E:\python code\iOS-vcam"
python scripts\ci_fetch.py download _ci_out
```

得到：

```text
_ci_out\com.iosvcam.opencam_<版本>_iphoneos-arm64e.deb
```

可选：校验包结构（应输出 `PASS`）：

```powershell
python ios\validate_deb.py _ci_out\com.iosvcam.opencam_<版本>_iphoneos-arm64e.deb
```

USB 模式下，安装后在悬浮面板把 RTMP 拉流地址填成 `rtmp://127.10.10.10:1935/live/srs`。

## 五、安装 deb 到手机

### 方法 A：Filza 安装

1. 把 `com.iosvcam.opencam_<版本>_iphoneos-arm64e.deb` 传到手机。
2. 用 Filza 打开 deb。
3. 选择安装。
4. 安装后重启相关服务，或直接重启用户空间。

常用命令：

```sh
killall -9 mediaserverd 2>/dev/null || true
```

如果虚拟摄像头没有生效，可执行：

```sh
ldrestart
```

### 方法 B：SSH 安装

先打开 USB 到 SSH 的转发：

```powershell
.\tools\iproxy.exe -u <UDID> 2222 22
```

另开一个 PowerShell，在项目根目录执行：

```powershell
cd "E:\python code\iOS-vcam"
.\pscp.exe -P 2222 -pw "<SSH_PASSWORD>" -batch _ci_out\com.iosvcam.opencam_<版本>_iphoneos-arm64e.deb root@127.0.0.1:/var/root/
.\plink.exe -4 -ssh -batch -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 "dpkg -i /var/root/com.iosvcam.opencam_<版本>_iphoneos-arm64e.deb"
```

如果 PuTTY 提示 host key 未缓存，先获取指纹：

```powershell
.\plink.exe -4 -ssh -batch -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 exit 2>&1 | Select-String "SHA256:"
```

之后命令加上：

```powershell
-hostkey "<HOSTKEY_SHA256>"
```

安装后检查：

```powershell
.\plink.exe -hostkey "<HOSTKEY_SHA256>" -4 -ssh -batch -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 "ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/vcamera*"
```

期望看到：

```text
vcamera.dylib
vcamera.plist
```

## 六、配置 iPhone SSH 转发能力

iPhone 的 sshd 必须允许指定地址的远程端口转发。

打开 USB SSH：

```powershell
.\tools\iproxy.exe -u <UDID> 2222 22
```

执行：

```powershell
cd "E:\python code\iOS-vcam"

.\plink.exe -hostkey "<HOSTKEY_SHA256>" -4 -ssh -batch -T -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 `
  "grep -q '^GatewayPorts clientspecified' /etc/ssh/sshd_config || echo 'GatewayPorts clientspecified' >> /etc/ssh/sshd_config; grep -q '^AllowTcpForwarding yes' /etc/ssh/sshd_config || echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config"
```

重载 sshd：

```powershell
.\plink.exe -hostkey "<HOSTKEY_SHA256>" -4 -ssh -batch -T -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 `
  "launchctl unload /Library/LaunchDaemons/com.openssh.sshd.plist 2>/dev/null; launchctl load /Library/LaunchDaemons/com.openssh.sshd.plist 2>/dev/null; launchctl unload /var/jb/Library/LaunchDaemons/com.openssh.sshd.plist 2>/dev/null; launchctl load /var/jb/Library/LaunchDaemons/com.openssh.sshd.plist 2>/dev/null"
```

验证：

```powershell
.\plink.exe -hostkey "<HOSTKEY_SHA256>" -4 -ssh -batch -T -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 `
  "sshd -T 2>/dev/null | grep -E '^(gatewayports|allowtcpforwarding)'"
```

期望：

```text
gatewayports clientspecified
allowtcpforwarding yes
```

## 七、创建 iPhone loopback alias

每次手机重启后都要重新执行：

```powershell
.\plink.exe -hostkey "<HOSTKEY_SHA256>" -4 -ssh -batch -T -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 `
  "ifconfig lo0 alias 127.10.10.10 netmask 255.255.255.255 2>/dev/null || true; ifconfig lo0 | grep 127.10.10.10"
```

期望：

```text
inet 127.10.10.10 netmask 0xffffffff
```

如果提示 `ifconfig: command not found`，说明手机没有安装 `network-cmds`。

## 八、启动 Windows 端服务和 USB 隧道

建议以管理员身份打开 PowerShell，进入项目根目录。

```powershell
cd "E:\python code\iOS-vcam"
```

推荐直接双击批处理包装器：

```text
iOS-VCAM-Launcher.bat
```

或者运行实际的 PowerShell 启动脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\iOS-VCAM-Launcher.ps1
```

当前主目录保留这些启动相关文件：

```text
iOS-VCAM-Launcher.bat
iOS-VCAM-Launcher.ps1
```

旧版 EXE 已移除，避免菜单和功能版本混乱。旧版 EXE 在 USB 模式下容易出现两类问题：

```text
Cannot confirm a host key in batch mode
Monibuca failed to start
```

新版 USB 模式已经改为 SRS 后端，正常启动时不应该再出现 `Monibuca failed to start`。如果复制到新电脑后仍然遇到工具路径问题，先检查 `tools\iproxy.exe`、根目录 `plink.exe` 和 Apple USB 驱动是否正常。

如果原启动器菜单不稳定，或者只想手动排查 USB/SRS 链路，可以使用下面的手动命令。当前手动命令会使用：

```text
tools\iproxy.exe
plink.exe
```

手动流程需要依次启动 Flask、SRS、iproxy 和 plink 反向隧道。

设置变量：

```powershell
$Project = "E:\python code\iOS-vcam"
$Udid = "<UDID>"
$HostKey = "<HOSTKEY_SHA256>"
$SshPassword = Read-Host "iPhone root SSH password"
```

启动 Flask auth，监听 80：

```powershell
if (-not (netstat -ano | Select-String ':80\s+.*LISTENING')) {
    Start-Process -WindowStyle Hidden `
        -FilePath "python" `
        -ArgumentList @("server.py", "--host", "0.0.0.0", "--port", "80") `
        -WorkingDirectory $Project `
        -RedirectStandardOutput "$Project\logs\flask-auth.out" `
        -RedirectStandardError "$Project\logs\flask-auth.err"
}
```

启动 SRS，监听 1935、1985、8080：

```powershell
if (-not (netstat -ano | Select-String ':1935\s+.*LISTENING')) {
    Start-Process -WindowStyle Hidden `
        -FilePath "$Project\objs\srs.exe" `
        -ArgumentList @("-c", ".\config\active\srs_usb_smooth_playback.conf") `
        -WorkingDirectory $Project `
        -RedirectStandardOutput "$Project\logs\srs-usb-live.out" `
        -RedirectStandardError "$Project\logs\srs-usb-live.err"

    Start-Sleep -Seconds 3
}
```

启动 USB SSH 转发：

```powershell
Start-Process -WindowStyle Hidden `
    -FilePath "$Project\tools\iproxy.exe" `
    -ArgumentList @("-u", $Udid, "2222", "22")

Start-Sleep -Seconds 2
```

确保 iPhone alias 存在：

```powershell
& "$Project\plink.exe" -hostkey $HostKey -4 -ssh -batch -T -P 2222 -pw $SshPassword root@127.0.0.1 `
  "ifconfig lo0 alias 127.10.10.10 netmask 255.255.255.255 2>/dev/null || true; ifconfig lo0 | grep 127.10.10.10"
```

启动长期 SSH 反向隧道：

```powershell
Start-Process -WindowStyle Hidden `
    -FilePath "$Project\plink.exe" `
    -ArgumentList @(
        "-v",
        "-hostkey", $HostKey,
        "-4",
        "-ssh",
        "-batch",
        "-T",
        "-N",
        "-R", "127.10.10.10:80:127.0.0.1:80",
        "-R", "127.10.10.10:1935:127.0.0.1:1935",
        "-P", "2222",
        "-pw", $SshPassword,
        "root@127.0.0.1"
    ) `
    -WorkingDirectory $Project `
    -RedirectStandardOutput "$Project\logs\plink-vcam-live.out" `
    -RedirectStandardError "$Project\logs\plink-vcam-live.err"
```

## 九、验证状态

### 1. 电脑端进程

```powershell
Get-Process -Name python,srs,iproxy,plink -ErrorAction SilentlyContinue |
    Select-Object Id,ProcessName,StartTime
```

期望看到：

```text
python
srs
iproxy
plink
```

### 2. 电脑端端口

```powershell
netstat -ano | Select-String ':80\s+.*LISTENING|:1935\s+.*LISTENING|:1985\s+.*LISTENING|:8080\s+.*LISTENING|127\.0\.0\.1:2222\s+.*LISTENING'
```

期望：

```text
0.0.0.0:80       LISTENING
0.0.0.0:1935     LISTENING
0.0.0.0:1985     LISTENING
0.0.0.0:8080     LISTENING
127.0.0.1:2222   LISTENING
```

### 3. SRS API

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:1985/api/v1/versions
```

期望返回类似：

```json
{"code":0,"data":{"version":"5.0.213"}}
```

### 4. Flask auth

```powershell
Invoke-WebRequest -UseBasicParsing -Method POST http://127.0.0.1/I
```

期望 HTTP 状态码：

```text
200
```

### 5. iPhone 端隧道监听

```powershell
& "$Project\plink.exe" -hostkey $HostKey -4 -ssh -batch -T -P 2222 -pw $SshPassword root@127.0.0.1 `
  "netstat -an | grep 127.10.10.10 || echo NO_LISTENERS"
```

期望：

```text
tcp4  127.10.10.10.1935  *.*  LISTEN
tcp4  127.10.10.10.80    *.*  LISTEN
```

### 6. plink 日志

查看：

```powershell
Get-Content -Tail 80 logs\plink-vcam-live.err
```

期望看到：

```text
Remote port forwarding from 127.10.10.10:80 enabled
Remote port forwarding from 127.10.10.10:1935 enabled
```

当前稳定链路只要求看到：

```text
Remote port forwarding from 127.10.10.10:80 enabled
Remote port forwarding from 127.10.10.10:1935 enabled
```

## 十、OBS 推流和手机使用

OBS 设置：

```text
服务类型：自定义
Server: rtmp://localhost:1935/live
Stream Key: srs
音频编码：AAC（建议 48 kHz，Track 1 勾选需要输出的桌面/麦克风/媒体源）
```

音频（OBS 麦克风替换）由 OpenVCam tweak（`com.iosvcam.opencam`）自身提供：OBS 声音从同一条 RTMP 流解复用，在 `mediaserverd` 中替换麦克风，由悬浮面板的「替换音频」开关控制。无需额外的 PC 端 bridge 包或第二条隧道。

开始推流后，手机端 iOS-VCAM 会从以下地址拉流：

```text
rtmp://127.10.10.10:1935/live/srs
```

`/var/mobile/vc.plist` 是 iOS 端保存 RTMP 链接的位置：

- 如果里面已经有有效的 `rtmp` 链接，应保留，不要覆盖用户手动保存过的地址。
- OpenVCam 的 RTMP 地址由手机端悬浮面板设置：填入 `rtmp://127.10.10.10:1935/live/srs` 后点保存即可，无需为每个 IP 重打包。
- 换手机时，每台手机各自在悬浮面板里设置一次地址即可。
- 注意：启动器不应静默修改手机文件；安装 `.deb`、respring 等动作都需要用户明确确认。
- 如果文件已经写入但输入框还是空，完全关闭 iOS-VCAM 面板后重新打开；仍不刷新时再由用户决定是否 respring。

如果 iOS-VCAM 有独立 App，打开后连接。然后在需要摄像头的 App 中打开相机，应该能看到 OBS 的视频画面。

### 关于虚拟麦克风

音频（OBS 麦克风替换）由 OpenVCam tweak（`com.iosvcam.opencam`）自身提供，从同一条 RTMP 流解复用 OBS 声音，在 `mediaserverd` 中替换麦克风（系统相机与 TikTok 均覆盖），由悬浮面板的「替换音频」开关控制。无需额外的 PC 端 bridge 包或第二条隧道。

## 十一、使用启动器菜单

准备工作完成后，也可以尝试项目启动器：

```powershell
cd "E:\python code\iOS-vcam"
powershell -ExecutionPolicy Bypass -File .\iOS-VCAM-Launcher.ps1
```

主菜单选择：

```text
[U] USB STREAMING (SSH Tunnel)
```

启动器会尝试自动完成：

- 启动 `iproxy`
- 启动 Flask auth
- 启动 SRS USB 配置
- 检查/修复 sshd 转发配置
- 创建 `127.10.10.10`
- 建立 SSH 反向隧道

如果启动器不稳定，按本文第八节的手动命令启动即可。

## 十二、常见问题

### 1. `Configured password was not accepted`

SSH 密码错误。确认手机 root 密码。

可在手机终端或 SSH 中修改：

```sh
passwd
```

### 2. `Cannot confirm a host key in batch mode`

PuTTY 没有缓存主机指纹。先获取：

```powershell
.\plink.exe -4 -ssh -batch -P 2222 -pw "<SSH_PASSWORD>" root@127.0.0.1 exit 2>&1 | Select-String "SHA256:"
```

之后所有命令加：

```powershell
-hostkey "<HOSTKEY_SHA256>"
```

### 3. `Remote port forwarding ... refused`

常见原因：

- 没有安装 `network-cmds`
- 没有执行 `ifconfig lo0 alias 127.10.10.10 ...`
- sshd 没有启用 `GatewayPorts clientspecified`
- sshd 没有启用 `AllowTcpForwarding yes`

依次检查：

```sh
command -v ifconfig
ifconfig lo0 | grep 127.10.10.10
sshd -T | grep -E "gatewayports|allowtcpforwarding"
```

### 4. Windows 80 端口被占用

检查：

```powershell
netstat -ano | findstr :80
```

如果是 IIS 或 System PID 4 占用，可尝试：

```powershell
Stop-Service W3SVC -Force
```

如果权限不足，使用管理员 PowerShell。

### 5. OBS 已推流但手机没有画面

检查：

- OBS 是否显示正在推流
- OBS 地址是否为 `rtmp://localhost:1935/live`，推流码是否为 `srs`
- iPhone 端 deb 是否为 `127.10.10.10` 版本
- `netstat -an | grep 127.10.10.10` 是否有 80 和 1935 LISTEN
- 手机是否需要重启 `mediaserverd`

可在手机执行：

```sh
killall -9 mediaserverd 2>/dev/null || true
```

仍不生效时：

```sh
ldrestart
```

### 6. 重启后失效

正常现象。以下内容重启后需要重新启动或重新设置：

- Windows 端 `srs`
- Windows 端 `iproxy`
- Windows 端 `plink`
- iPhone `127.10.10.10` alias

以下内容会保留：

- deb 安装
- `network-cmds`
- `/etc/ssh/sshd_config` 中的配置

## 十三、停止服务

只停止本项目相关进程：

```powershell
Stop-Process -Name plink,iproxy,srs -Force -ErrorAction SilentlyContinue
```

如果 Flask auth 也是本项目启动的，可以停止监听 80 的 Python：

```powershell
$p80 = Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue
if ($p80) {
    Stop-Process -Id $p80.OwningProcess -Force
}
```

## 十四、本次成功验收标准

最终成功时应满足：

```text
电脑端:
  python 监听 80
  srs 监听 1935/1985/8080
  iproxy 监听 127.0.0.1:2222
  plink 常驻运行

iPhone 端:
  127.10.10.10.80 LISTEN
  127.10.10.10.1935 LISTEN

OBS:
  推流到 rtmp://localhost:1935/live，Stream Key 为 srs

手机:
  打开 iOS-VCAM 后能看到 OBS 视频画面
```
