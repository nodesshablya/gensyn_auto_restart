#!/bin/bash
echo "🛠️ Installing watchdog for RL Swarm..."
INSTALL_DIR="$HOME/rl-swarm"
WATCHDOG_SCRIPT="$INSTALL_DIR/watchdog.sh"
SERVICE_FILE="/etc/systemd/system/gensynnode.service"

read -p "❓ Do you want to enable Telegram notifications? (y/N): " ENABLE_TELEGRAM
if [[ "$ENABLE_TELEGRAM" =~ ^[Yy]$ ]]; then
  read -p "🔑 Enter your Telegram BOT TOKEN: " BOT_TOKEN
  read -p "👤 Enter your Telegram CHAT ID: " CHAT_ID
else
  BOT_TOKEN=""
  CHAT_ID=""
fi

echo "📄 Creating watchdog.sh..."
cat > "$WATCHDOG_SCRIPT" <<'EOF'
#!/bin/bash
LOG_FILE="$HOME/rl-swarm/gensynnode.log"
PROJECT_DIR="$HOME/rl-swarm"

# Здесь добавляем новые паттерны для поиска ошибок
check_for_error() {
  grep -qE "Resource temporarily unavailable|Connection refused|BlockingIOError: \[Errno 11\]|EOFError: Ran out of input|Traceback \(most recent call last\)" "$LOG_FILE"
}

check_process() {
  ! screen -list | grep -q "gensynnode"
}

send_telegram_alert() {
  SERVER_IP=$(curl -s https://api.ipify.org)
EOF

if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
cat >> "$WATCHDOG_SCRIPT" <<EOF
  BOT_TOKEN="$BOT_TOKEN"
  CHAT_ID="$CHAT_ID"
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \\
    -d chat_id="\$CHAT_ID" \\
    -d text="⚠️ *RL Swarm был перезапущен*
🌐 IP: \$SERVER_IP
🕒 \$(date '+%Y-%m-%d %H:%M:%S')" \\
    -d parse_mode="Markdown"
EOF
else
cat >> "$WATCHDOG_SCRIPT" <<'EOF'
  echo "[INFO] Telegram notifications are disabled"
EOF
fi

cat >> "$WATCHDOG_SCRIPT" <<'EOF'
}

restart_process() {
  echo "[INFO] Restarting gensynnode..."
  screen -XS gensynnode quit
  cd "$PROJECT_DIR" || exit
  source .venv/bin/activate
  screen -S gensynnode -d -m bash -c "trap '' INT; echo -e 'A\n0.5\nN\n' | bash run_rl_swarm.sh 2>&1 | tee $LOG_FILE"
  sleep 5
  while ! screen -S gensynnode -X stuff "N$(echo -ne '\r')"; do
    sleep 1
  done
  echo "[INFO] Sent 'N' to process"
  send_telegram_alert
}

while true; do
  if check_for_error || check_process; then
    restart_process
  fi
  sleep 10
done
EOF

chmod +x "$WATCHDOG_SCRIPT"
echo "✅ watchdog.sh created at $WATCHDOG_SCRIPT"

echo "📄 Creating systemd service..."
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=RL Swarm Watchdog
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/bin/bash $WATCHDOG_SCRIPT
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

echo "🔁 Reloading and starting systemd service..."
sudo systemctl daemon-reload
sudo systemctl enable gensynnode.service
sudo systemctl restart gensynnode.service

echo "✅ Installation complete!"
echo "👉 To check status: sudo systemctl status gensynnode.service"

if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
  SERVER_IP=$(curl -s https://api.ipify.org)
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="✅ Скрипт RL Swarm установлен
🌐 IP: $SERVER_IP
🕒 $(date '+%Y-%m-%d %H:%M:%S')" \
    -d parse_mode="Markdown"
fi
