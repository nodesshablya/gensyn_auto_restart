# Gensyn Watchdog 🧠⚙️

This script automatically monitors the `gensynnode` log for the error `Resource temporarily unavailable`.  
If detected, it restarts the node, enters the screen session, inputs `N` when prompted, and optionally sends a Telegram alert with the server’s public IPv4 address.

---

## 📦 Installation

1. Clone or copy the contents of this repository to your server.
2. Navigate to the `rl-swarm` directory:
   ```bash
   cd ~/rl-swarm
   ```
3. Make the installer script executable:
   ```bash
   chmod +x install_watchdog.sh
   ```
4. Run the setup script:
   ```bash
   ./install_watchdog.sh
   ```
   - You'll be asked whether you want to enable Telegram notifications.
   - If yes, provide your **Bot Token** and **Chat ID**.

---

## 🔧 How It Works

- Monitors `gensynnode.log` for the specific error message.
- If the error is found:
  - Terminates the current screen session.
  - Restarts the node using:
    ```bash
    screen -S gensynnode -d -m bash -c "trap '' INT; bash run_rl_swarm.sh | tee gensynnode.log"
    ```
  - Waits for the `y/N` prompt and sends `N`.
  - Sends a Telegram alert (if enabled).

---

## 🧪 Manual Run

You can manually run the watchdog at any time:
```bash
bash ~/rl-swarm/watchdog.sh
```

---

## 🖥️ Service Management (systemd)

To check the service status:
```bash
sudo systemctl status gensynnode.service
```

To restart the service:
```bash
sudo systemctl restart gensynnode.service
```

To disable the service:
```bash
sudo systemctl disable gensynnode.service
```

---

## 💬 Telegram Notification Example

If enabled, you’ll receive a message like this on restart:

```
⚠️ RL Swarm was restarted due to an error (`Resource temporarily unavailable`)
🌐 Server IPv4: `88.198.xx.xx`
🕒 2025-04-27 22:30:00
```

