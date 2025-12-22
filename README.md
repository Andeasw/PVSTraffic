# 🚀 VPS Traffic Spirit (Network Speed Test & Simulator)

**Version:** 0.0.1  
**Language:** Bash Shell (Linux)

**VPS Traffic Spirit** is a lightweight, all-in-one network utility designed for Linux VPS environments. It allows you to perform instant **network bandwidth speed tests**, simulate realistic traffic usage to keep connections active, and schedule automated network tasks with precision.

> **Key Feature:** One-click **Max Bandwidth Speed Test** to verify your VPS network quality instantly.

---

```bash
curl -fsSL https://raw.githubusercontent.com/Andeasw/PVSTraffic/master/pvstraffic.sh | bash

```

## 🌟 Key Features

*   **⚡ Instant Speed Test:** Automatically detects your network's maximum available download bandwidth using high-speed global nodes (Hetzner).
*   **📊 Traffic Simulation:** Generate specific amounts of network traffic (e.g., "Run 1GB") to test stability or meet monthly quota requirements.
*   **🕒 Smart Scheduling (Cron):**
    *   Automated daily execution based on **Beijing Time (UTC+8)**.
    *   Automatically handles time zone conversion for your server's local time.
    *   **Randomized Start:** Adds random delays to prevent pattern detection.
*   **🛡️ Resource Protection:**
    *   **OOM Prevention:** Automatically disables upload tasks if memory is low.
    *   **CPU Friendly:** Runs with low priority (`nice`) to prevent slowing down your website or SSH.
*   **☁️ Background Mode:** Start a long-running speed/traffic task and safely disconnect your SSH session. The task continues in the background.

---

## 📥 Installation

1.  **Download/Create the script:**
    ```bash
    # Create the file
    vim traffic.sh
    # Paste the code provided into the file, then save and exit.
    ```

2.  **Make it executable:**
    ```bash
    chmod +x traffic.sh
    ```

3.  **Run:**
    ```bash
    ./traffic.sh
    ```

---

## ⚙️ Default "Prince" Configuration

The script comes pre-configured with the following **Default Strategy** (optimized for stability):

| Setting | Default Value | Description |
| :--- | :--- | :--- |
| **Cycle Period** | **28 Days** | Reset cycle duration |
| **Cycle Target** | **36 GB** | Total traffic target per cycle |
| **Daily Target** | **1200 MB** | Target traffic to generate daily |
| **Daily Duration** | **120 Min** | Time to spread the traffic over |
| **Max Speed** | **12 MB/s** | Speed limit for automated tasks |
| **Start Time** | **03:20** | **Beijing Time (UTC+8)** |

*All settings can be customized in the `2. Settings` menu.*

---

## 📖 Menu Guide

When you run the script, you will see the following options:

### 1. 🚀 Manual Mode (Speed Test)
Use this menu for immediate tasks:
*   **⚡ Limit Speed Test:** Runs a 10-second test to find your **Maximum Network Throughput**.
*   **⏳ Time-Limited Run:** Run traffic for a specific duration (e.g., 60 seconds).
*   **📦 Fixed Data Run (Foreground):** Download X MB of data while watching the progress bar.
*   **☁️ Fixed Data Run (Background):** Download X MB of data in the background (allows you to close SSH).

### 2. ⚙️ Settings (Full Config)
Customize the automated behavior:
*   Modify daily/monthly traffic targets.
*   Set the **Start Time** (based on Beijing Time).
*   Enable/Disable **Upload** (Default is OFF for safety).
*   **Auto-Test:** Includes a helper to test max speed before setting limits.

### 3. 📄 View Logs
Check the history of automated runs and manual tests located in `/root/vps_traffic/logs/`.

### 4. 🗑️ Uninstall
Completely removes the script, configuration files, and Cron jobs.

---
