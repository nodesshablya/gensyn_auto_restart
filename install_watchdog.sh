#!/bin/bash

echo "🛠 Installing watchdog for RL Swarm..."

INSTALL_DIR="/root/rl-swarm"
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

LOG_FILE="/root/rl-swarm/gensynnode.log"
PROJECT_DIR="/root/rl-swarm"

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
        -d text="⚠️ RL Swarm был перезапущен 🌐 IP: \$SERVER_IP 🕒 \$(date '+%Y-%m-%d %H:%M:%S')" \\
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
    
    # Создаем лог-файл если его нет
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    
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
    
    # Перезапуск процесса с интерактивными ответами
    cd "$PROJECT_DIR" || exit
    source .venv/bin/activate
    
    echo "[INFO] Starting process in screen session..."
    # Запускаем процесс в screen
    screen -S gensynnode -d -m bash -c "trap '' INT; bash run_rl_swarm.sh 2>&1 | tee /root/rl-swarm/gensynnode.log"
    
    echo "[INFO] Process started, log file: $LOG_FILE"
    sleep 5
    
    echo "[INFO] Waiting for installation to complete..."
    
    # Ждем завершения установки библиотек (ищем "Done!")
    for i in {1..300}; do  # Увеличиваем до 5 минут
        if tail -n 20 "$LOG_FILE" 2>/dev/null | grep -q "Done!"; then
            echo "[INFO] Installation completed, found 'Done!' message"
            break
        fi
        sleep 1
    done
    
    # Дополнительно ждем появления вопроса о Hugging Face Hub
    echo "[INFO] Waiting for Hugging Face Hub question..."
    for i in {1..60}; do  # Ждем до 1 минуты
        LOG_TAIL=$(tail -n 10 "$LOG_FILE" 2>/dev/null || echo "")
        if echo "$LOG_TAIL" | grep -q "\[y/N\]"; then
            echo "[INFO] Found [y/N] prompt, sending 'N'"
            screen -S gensynnode -X stuff "N$(echo -ne '\r')"
            sleep 3
            break
        fi
        sleep 1
    done
    
    # Ждем появления вопроса о модели и нажимаем Enter
    echo "[INFO] Waiting for model name question..."
    FOUND_MODEL_QUESTION=false
    
    for i in {1..120}; do  # Увеличиваем до 2 минут
        LOG_TAIL=$(tail -n 20 "$LOG_FILE" 2>/dev/null || echo "")
        echo "[DEBUG] Attempt $i/120, checking log..."
        echo "[DEBUG] Last 3 lines of log:"
        tail -n 3 "$LOG_FILE" 2>/dev/null || echo "No log available"
        
        # Проверяем различные варианты текста
        if echo "$LOG_TAIL" | grep -qi "enter the name of the model"; then
            echo "[INFO] Found 'enter the name of the model' - pressing Enter"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
            FOUND_MODEL_QUESTION=true
            break
        elif echo "$LOG_TAIL" | grep -qi "huggingface repo/name format"; then
            echo "[INFO] Found 'huggingface repo/name format' - pressing Enter"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
            FOUND_MODEL_QUESTION=true
            break
        elif echo "$LOG_TAIL" | grep -qi "press \[enter\]"; then
            echo "[INFO] Found 'press [Enter]' - pressing Enter"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
            FOUND_MODEL_QUESTION=true
            break
        elif echo "$LOG_TAIL" | grep -qi "default model"; then
            echo "[INFO] Found 'default model' - pressing Enter"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
            FOUND_MODEL_QUESTION=true
            break
        elif echo "$LOG_TAIL" | grep -qi "model.*:" && echo "$LOG_TAIL" | grep -v "installing\|downloading"; then
            echo "[INFO] Found model prompt - pressing Enter"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
            FOUND_MODEL_QUESTION=true
            break
        fi
        
        # Каждые 30 секунд принудительно отправляем Enter
        if [ $((i % 30)) -eq 0 ]; then
            echo "[INFO] Timeout approach - sending Enter anyway (attempt $((i/30)))"
            screen -S gensynnode -X stuff "$(echo -ne '\r')"
        fi
        
        sleep 1
    done
    
    if [ "$FOUND_MODEL_QUESTION" = false ]; then
        echo "[WARN] Model question not found, sending Enter as fallback"
        screen -S gensynnode -X stuff "$(echo -ne '\r')"
    fi
    
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
User=root
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
echo "👉 To check watchdog logs: sudo journalctl -u gensynnode.service -f"
echo "👉 To check RL Swarm logs: tail -f /root/rl-swarm/gensynnode.log"

if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
    SERVER_IP=$(curl -s https://api.ipify.org)
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="✅ Скрипт RL Swarm установлен 🌐 IP: $SERVER_IP 🕒 $(date '+%Y-%m-%d %H:%M:%S')" \
        -d parse_mode="Markdown"
fi
