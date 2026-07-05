# Advanced Features

## 🔐 USB Setup Validation

> **Safety Note:** The launcher defaults to read-only iPhone handling. It checks local tools, ports, and tunnel prerequisites, but it does not install packages or change iPhone files/settings during normal validation.

### USB Setup Validation (Option [9])
Option [9] runs prerequisite checks for USB streaming. It is not the old SSH `.deb` installer.

**What it checks:**
1.  **Local tools:** `iproxy.exe`, `idevice_id.exe`, `plink.exe`, and Python availability.
2.  **Project files:** SRS/Flask/config files required by Option [U].
3.  **Ports:** Whether local streaming/auth ports are free or already bound.
4.  **Device visibility:** Whether libimobiledevice can see the attached iPhone.

If you need to install or update an iOS `.deb`, generate the package with the tools in `ios/` and perform the install deliberately outside Option [9]. Do not use or install the quarantined `com.iosvcam.audiobridge` package.

### Customizing SSH
The launcher can prompt for SSH credentials when Option [U] needs to establish a tunnel.

*   **Default:** USB-forwarded SSH on local port `2222`, User: `root`, Password: `alpine`.
*   **Custom:** If you changed the root password, enter the custom password when prompted. The password is stored in `config.ini` for future local sessions.

### Manual SSH Tools
The distribution includes `plink.exe` and `pscp.exe`. Prefer read-only diagnostic commands unless you intentionally choose a manual recovery/install step:
```powershell
# Read-only connectivity check
.\plink.exe -ssh root@localhost -P 2222 -pw alpine "uname -a"
```

---

## 🎨 Debranding

You can modify the iOS package to inject your server's IP address, making the installation "Plug & Play" for the device.

**Tool:** `ios/ios_deb_ip_changer_final.py`

**Usage:**
```bash
python ios/ios_deb_ip_changer_final.py --base ios/iosvcam_base.deb 192.168.1.50
```
This creates a new `.deb` file with `192.168.1.50` hardcoded as the default control server.

---

## 🕵️ Frida & App Analysis

For advanced users analyzing target applications (e.g., for bypassing jailbreak detection or SSL pinning), we use **Frida**.

### Setup
1.  Install `frida-tools` on PC: `pip install frida-tools`.
2.  Install Frida Server on iPhone (via Sileo).

### USB Connection (No SSH needed)
Frida can communicate directly over USB mux.
```bash
frida-ps -U  # List processes on USB device
```

### Hooking
Use the scripts in the `ios/` or `frida/` folders (if available) to spawn apps with hooks:
```bash
frida -U -f com.example.targetapp -l my_hook.js
```

See [HOW-WE-CONNECTED-IPHONE-FRIDA.md](HOW-WE-CONNECTED-IPHONE-FRIDA.md) for a detailed walkthrough.

---

## 🚇 Reverse SSH Tunneling (USB)

If you cannot use `iproxy` for the stream (e.g., Windows firewall issues), you can use a **Reverse SSH Tunnel**.

**Command:**
```bash
ssh -R 1935:localhost:1935 root@localhost -p 2222
```

**Explanation:**
*   `-R 1935:localhost:1935`: Listen on iPhone port 1935. Forward traffic to PC (localhost relative to SSH client) port 1935.
*   `root@localhost -p 2222`: Connect to iPhone via local forwarded port 2222.

This makes the iPhone "think" it has a local service on 1935, which is actually your PC's SRS server.

---

## 🏗 System Architecture

### Components
1.  **SRS (C++)**: Handles RTMP ingest, HLS segmentation, and HTTP delivery.
2.  **Flask (Python)**: Provides a lightweight API and authentication endpoint (`/auth`).
3.  **Nginx (Optional)**: Can be used as a reverse proxy (bundled in some distributions).
4.  **Launcher (PowerShell)**: Orchestrator. Checks network, updates configs, manages processes.
5.  **AudioBridge System v0.1 (Experimental)**: PC bridge prepares OBS audio; manual iOS daemon/system-hook packages are Phase 1 passive test artifacts.

### Data Flow
1.  **PC (OBS)** --[RTMP]--> **SRS (Port 1935)**
2.  **SRS** --[HLS/RTMP]--> **Internal Buffer**
3.  **iPhone (Tweak)** --[Request]--> **SRS (Port 8080/1935)**
4.  **iPhone (App)** <--[Video Feed]-- **Camera Driver**

