#!/bin/bash
echo "🛠 Installing watchdog for RL Swarm..."
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
    -d text="⚠️ RL Swarm был перезапущен
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
  # Останавливаем процесс
  screen -XS gensynnode quit
  # Копирование файлов temp перед запуском
  TEMP_SOURCE="/root/temp"
  TEMP_DEST="/root/rl-swarm/modal-login/temp-data"
  echo "[INFO] Preparing temp data files..."
  if [ -d "$TEMP_DEST" ]; then
    rm -f "$TEMP_DEST"/*
  else
    mkdir -p "$TEMP_DEST"
  fi
  if [ -f "$TEMP_SOURCE/userData.json" ]; then
    cp "$TEMP_SOURCE/userData.json" "$TEMP_DEST/"
  else
    echo "[WARN] $TEMP_SOURCE/userData.json not found!"
  fi
  if [ -f "$TEMP_SOURCE/userApiKey.json" ]; then
    cp "$TEMP_SOURCE/userApiKey.json" "$TEMP_DEST/"
  else
    echo "[WARN] $TEMP_SOURCE/userApiKey.json not found!"
  fi
  # Перезапуск процесса с правильной последовательностью ответов
  cd "$PROJECT_DIR" || exit
  source .venv/bin/activate
  # Создаем временный файл с ответами только для нужных вопросов
  echo "N" > /tmp/rl_answers.txt
  echo "" >> /tmp/rl_answers.txt
  # Запускаем с перенаправлением ответов
  screen -S gensynnode -d -m bash -c "trap '' INT; bash run_rl_swarm.sh < /tmp/rl_answers.txt 2>&1 | tee $LOG_FILE"
  # Удаляем временный файл
  rm -f /tmp/rl_answers.txt
  echo "[INFO] Process restarted with automated responses"
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
