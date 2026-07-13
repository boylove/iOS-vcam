# Installation Guide

## ✅ Prerequisites

### Windows PC
*   **OS:** Windows 10 or Windows 11 (64-bit)
*   **PowerShell:** Version 5.1 or newer (PowerShell 7+ recommended)
*   **Python:** Version 3.8+ (Required for iOS tools and Flask server)
    *   *Ensure "Add Python to PATH" is checked during installation.*
*   **Network:** WiFi or Ethernet adapter active.

### iOS Device
*   **Status:** **Jailbroken** (Dopamine, Palera1n, unc0ver, etc.)
*   **iOS Version:** iOS 14 - 16.x (Verified on iOS 16.3.1)
*   **Required Tweaks:**
    *   **OpenSSH** (Server)
    *   **Filza** (File Manager)
    *   **VCAM Tweak** (The target tweak receiving the stream)
    *   **Frida** (Optional, for advanced hooking)

---

## 💻 Server Installation

1.  **Download the Distribution**
    *   Clone this repository or download the latest release zip.
    *   Extract to a folder (e.g., `C:\iOS-VCAM-Server`).

2.  **Install Python Dependencies**
    *   Open a terminal in the project folder.
    *   Run: `pip install flask colorama`

3.  **Install USB Drivers (Optional but Recommended)**
    *   If you plan to use USB streaming, install **iTunes** or **Apple Devices** app to get the necessary drivers.
    *   Install **libimobiledevice** tools (e.g., via Chocolatey: `choco install libimobiledevice`).

---

## 📱 iOS Setup

### 1. Jailbreak & Basic Tools
Ensure your device is jailbroken. Open your package manager (Sileo/Zebra/Cydia) and install:
*   `OpenSSH`
*   `PreferenceLoader`
*   `Cephei Tweak Support` (common dependency)

### 2. Install the OpenVCam Tweak
Fetch the built tweak package and install it on the device:
1.  Download the latest build: `python scripts/ci_fetch.py download _ci_out`.
2.  Copy `_ci_out/com.iosvcam.opencam_*.deb` to the iPhone (Filza, `pscp`, or your package manager).
3.  Install it and userspace-reboot (respring) so mediaserverd reloads.
4.  Open the OpenVCam floating panel and set the RTMP pull URL.

### 3. Trust the Computer
*   Connect iPhone to PC via USB.
*   Tap "Trust" on the iPhone popup.
*   Enter your passcode.

---

## 🚀 Verifying Installation

1.  **Launch the Server:**
    Double-click `iOS-VCAM-Launcher.exe`. It should open without errors and display your IP address.

2.  **Check Services:**
    *   **SRS:** Should start on port 1935 (RTMP) and 8080 (HTTP).
    *   **Flask:** Should start on port 80.

3.  **Test Connection:**
    *   On your PC, open a browser to `http://localhost:8080`.
    *   You should see the SRS Welcome page or Nginx default page.

Next Step: [Configuration Guide](Configuration.md)
