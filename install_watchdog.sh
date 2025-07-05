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
SOURCE_DIR="/root/temp"
DEST_DIR="/root/rl-swarm/modal-login/temp-data"

# Функция для копирования файлов перед рестартом
copy_user_files() {
  echo "[INFO] Copying user files before restart..."
  
  # Проверяем существование исходной папки
  if [ ! -d "$SOURCE_DIR" ]; then
    echo "[WARNING] Source directory $SOURCE_DIR does not exist"
    return 1
  fi
  
  # Создаем папку назначения если её нет
  mkdir -p "$DEST_DIR"
  
  # Удаляем существующие файлы в папке назначения
  if [ -d "$DEST_DIR" ]; then
    echo "[INFO] Cleaning destination directory..."
    rm -f "$DEST_DIR"/*
  fi
  
  # Копируем необходимые файлы
  if [ -f "$SOURCE_DIR/userData.json" ]; then
    cp "$SOURCE_DIR/userData.json" "$DEST_DIR/"
    echo "[INFO] Copied userData.json"
  else
    echo "[WARNING] userData.json not found in $SOURCE_DIR"
  fi
  
  if [ -f "$SOURCE_DIR/userApiKey.json" ]; then
    cp "$SOURCE_DIR/userApiKey.json" "$DEST_DIR/"
    echo "[INFO] Copied userApiKey.json"
  else
    echo "[WARNING] userApiKey.json not found in $SOURCE_DIR"
  fi
  
  echo "[INFO] File copying completed"
}

# Здесь добавляем новые паттерны для поиска ошибок
check_for_error() {
  grep -qE "Resource temporarily unavailable|Connection refused|BlockingIOError: \[Errno 11\]|EOFError: Ran out of input|Traceback \(most recent call last\)" "$LOG_FILE"
}

check_process() {
  ! screen -list 2>/dev/null | grep -q "gensynnode"
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
  
  # Копируем файлы перед рестартом
  copy_user_files
  
  # Останавливаем процесс (если он существует)
  if screen -list | grep -q "gensynnode"; then
    echo "[INFO] Stopping existing gensynnode session..."
    screen -XS gensynnode quit
    sleep 2
  fi
  
  # Переходим в рабочую директорию
  cd "$PROJECT_DIR" || exit
  source .venv/bin/activate
  
  # Запускаем новый процесс
  echo "[INFO] Starting new gensynnode session..."
  screen -S gensynnode -d -m bash -c "trap '' INT; echo -e 'A\n0.5\nN\n' | bash run_rl_swarm.sh 2>&1 | tee $LOG_FILE"
  
  # Ждем немного, чтобы процесс успел запуститься
  sleep 10
  
  # Проверяем, что процесс действительно запустился
  if screen -list | grep -q "gensynnode"; then
    echo "[INFO] Process started successfully"
    
    # Пытаемся отправить команду 'N' в процесс (с лимитом попыток)
    local attempts=0
    local max_attempts=5
    
    while [ $attempts -lt $max_attempts ]; do
      if screen -S gensynnode -X stuff "N$(echo -ne '\r')"; then
        echo "[INFO] Sent 'N' to process (attempt $((attempts + 1)))"
        break
      else
        echo "[WARNING] Failed to send 'N' to process (attempt $((attempts + 1)))"
        attempts=$((attempts + 1))
        sleep 2
      fi
    done
    
    if [ $attempts -eq $max_attempts ]; then
      echo "[ERROR] Failed to send 'N' to process after $max_attempts attempts"
    fi
  else
    echo "[ERROR] Failed to start gensynnode session"
  fi
  
  # Отправляем уведомление в Telegram
  send_telegram_alert
}

# Основной цикл мониторинга
while true; do
  if check_for_error || check_process; then
    echo "[INFO] Error detected or process not running, initiating restart..."
    restart_process
    # Даем время процессу полностью запуститься перед следующей проверкой
    sleep 60
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

# Отправляем уведомление об установке в Telegram
if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
  SERVER_IP=$(curl -s https://api.ipify.org)
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="✅ Скрипт RL Swarm установлен
🌐 IP: $SERVER_IP
🕒 $(date '+%Y-%m-%d %H:%M:%S')" \
    -d parse_mode="Markdown"
fi
