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
STATE_FILE="/root/rl-swarm/.watchdog_state"

# --- НАСТРОЙКИ ---
# Сколько минут без нового Joining round считаем застоем
STALE_MINUTES="${STALE_MINUTES:-30}"
STALE_SECONDS=$((STALE_MINUTES * 60))
# Сколько минут после старта сессии ждём первый Joining round
STARTUP_GRACE_MINUTES="${STARTUP_GRACE_MINUTES:-60}"
STARTUP_GRACE_SECONDS=$((STARTUP_GRACE_MINUTES * 60))

# --- STATE ---
init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    printf "START_TIME=%s\nLAST_ROUND_EPOCH=\nLAST_ROUND_ID=\n" "$(date +%s)" > "$STATE_FILE"
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  if [[ -z "$START_TIME" ]]; then
    START_TIME="$(date +%s)"
    save_state
  fi
}

save_state() {
  {
    echo "START_TIME=${START_TIME}"
    echo "LAST_ROUND_EPOCH=${LAST_ROUND_EPOCH}"
    echo "LAST_ROUND_ID=${LAST_ROUND_ID}"
  } > "$STATE_FILE"
}

reset_state_for_new_session() {
  START_TIME="$(date +%s)"
  LAST_ROUND_EPOCH=""
  LAST_ROUND_ID=""
  save_state
}

# --- Детект ошибок по логам ---
check_for_error() {
  # Не триггерим на "file truncated" — это обычная ротация/перезапуск вывода
  grep -qE "Resource temporarily unavailable|Connection refused|BlockingIOError: \[Errno 11\]|EOFError: Ran out of input|Traceback \(most recent call last\)" "$LOG_FILE"
}

# --- Процесс не запущен ---
check_process() {
  ! screen -list | grep -q "gensynnode"
}

# Достаём последнюю актуальную строку Joining round с таймштампом >= START_TIME
get_last_round_epoch_and_id() {
  local line ts epoch rid
  line="$(grep -F "Joining round:" "$LOG_FILE" | tail -n 1)"
  [[ -z "$line" ]] && return 1

  # Извлекаем [YYYY-MM-DD HH:MM:SS,ms] -> YYYY-MM-DD HH:MM:SS
  ts="$(echo "$line" | sed -n 's/^\[\([0-9-]\{10\} [0-9:]\{8\}\),[0-9]\{1,6\}\].*/\1/p')"
  rid="$(echo "$line" | sed -n 's/.*Joining round: \([0-9]\+\).*/\1/p')"

  [[ -z "$ts" ]] && return 1
  epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  [[ "$epoch" -le 0 ]] && return 1

  # Игнорируем строки, которые были ДО старта нашей текущей сессии
  if [[ "$epoch" -lt "$START_TIME" ]]; then
    return 1
  fi

  echo "$epoch:$rid"
  return 0
}

refresh_round_state_if_needed() {
  local info epoch rid
  if info="$(get_last_round_epoch_and_id)"; then
    epoch="${info%%:*}"
    rid="${info##*:}"
    if [[ -z "$LAST_ROUND_EPOCH" || "$epoch" -gt "${LAST_ROUND_EPOCH:-0}" ]]; then
      LAST_ROUND_EPOCH="$epoch"
      LAST_ROUND_ID="$rid"
      save_state
    fi
  fi
}

# --- Проверка застоя по раундам, учитывая grace ---
check_round_stall() {
  local now diff
  refresh_round_state_if_needed
  now="$(date +%s)"

  # Если ещё не было ни одного актуального Joining round в текущей сессии
  if [[ -z "$LAST_ROUND_EPOCH" ]]; then
    # Ждём в пределах grace-периода
    if (( now - START_TIME >= STARTUP_GRACE_SECONDS )); then
      # Grace вышел — считаем застой
      return 0
    else
      return 1
    fi
  fi

  # Иначе проверяем время с последнего актуального раунда
  diff=$(( now - LAST_ROUND_EPOCH ))
  if (( diff >= STALE_SECONDS )); then
    return 0
  fi
  return 1
}

send_telegram_alert() {
  local reason="$1"
  local SERVER_IP
  SERVER_IP=$(curl -s https://api.ipify.org)
EOF

# Вставляем Telegram-отправку с подстановкой токена/чата при установке
if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
    cat >> "$WATCHDOG_SCRIPT" <<EOF
  BOT_TOKEN="$BOT_TOKEN"
  CHAT_ID="$CHAT_ID"
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \\
    -d chat_id="\$CHAT_ID" \\
    -d text="⚠️ RL Swarm был перезапущен (причина: \$reason) 🌐 IP: \$SERVER_IP 🕒 \$(date '+%Y-%m-%d %H:%M:%S')" \\
    -d parse_mode="Markdown" >/dev/null 2>&1
EOF
else
    cat >> "$WATCHDOG_SCRIPT" <<'EOF'
  echo "[INFO] Telegram notifications are disabled (reason: '"$reason"')"
EOF
fi

cat >> "$WATCHDOG_SCRIPT" <<'EOF'
}

restart_process() {
  local reason="${1:-unknown}"
  echo "[INFO] Restarting gensynnode... reason: $reason"

  # Останавливаем процесс
  screen -XS gensynnode quit

  # Сбрасываем state под новую сессию
  reset_state_for_new_session

  # Создаём лог, если его нет
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"

  # Копирование temp перед запуском
  local TEMP_SOURCE="/root/temp"
  local TEMP_DEST="/root/rl-swarm/modal-login/temp-data"

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

  # Перезапуск процесса
  cd "$PROJECT_DIR" || exit 1
  source .venv/bin/activate

  echo "[INFO] Starting process in screen session..."
  screen -S gensynnode -d -m bash -c "trap '' INT; bash run_rl_swarm.sh 2>&1 | tee /root/rl-swarm/gensynnode.log"

  echo "[INFO] Process started, log file: $LOG_FILE"
  sleep 5

  echo "[INFO] Waiting for installation to complete..."
  for i in {1..300}; do
    if tail -n 20 "$LOG_FILE" 2>/dev/null | grep -q "Done!"; then
      echo "[INFO] Installation completed, found 'Done!' message"
      break
    fi
    sleep 1
  done

  echo "[INFO] Waiting for Hugging Face Hub question..."
  for i in {1..60}; do
    LOG_TAIL=$(tail -n 10 "$LOG_FILE" 2>/dev/null || echo "")
    if echo "$LOG_TAIL" | grep -q "\[y/N\]"; then
      echo "[INFO] Found [y/N] prompt, sending 'N'"
      screen -S gensynnode -X stuff "N$(echo -ne '\r')"
      sleep 3
      break
    fi
    sleep 1
  done

  echo "[INFO] Waiting for model name question..."
  FOUND_MODEL_QUESTION=false
  for i in {1..120}; do
    LOG_TAIL=$(tail -n 20 "$LOG_FILE" 2>/dev/null || echo "")
    echo "[DEBUG] Attempt $i/120, checking log..."
    tail -n 3 "$LOG_FILE" 2>/dev/null || echo "No log available"

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

  echo "[INFO] Waiting for AI Prediction Market question..."
  FOUND_AI_MARKET_QUESTION=false
  for i in {1..60}; do
    LOG_TAIL=$(tail -n 10 "$LOG_FILE" 2>/dev/null || echo "")
    echo "[DEBUG] AI Market attempt $i/60, checking log..."
    tail -n 3 "$LOG_FILE" 2>/dev/null || echo "No log available"

    if echo "$LOG_TAIL" | grep -qi "AI Prediction Market" && echo "$LOG_TAIL" | grep -qi "\[Y/n\]"; then
      echo "[INFO] Found 'AI Prediction Market [Y/n]' - sending 'Y'"
      screen -S gensynnode -X stuff "Y$(echo -ne '\r')"
      FOUND_AI_MARKET_QUESTION=true
      break
    elif echo "$LOG_TAIL" | grep -qi "participate.*AI.*Market"; then
      echo "[INFO] Found AI Market participation question - sending 'Y'"
      screen -S gensynnode -X stuff "Y$(echo -ne '\r')"
      FOUND_AI_MARKET_QUESTION=true
      break
    elif echo "$LOG_TAIL" | grep -qi "prediction.*market"; then
      echo "[INFO] Found prediction market question - sending 'Y'"
      screen -S gensynnode -X stuff "Y$(echo -ne '\r')"
      FOUND_AI_MARKET_QUESTION=true
      break
    fi

    sleep 1
  done

  if [ "$FOUND_AI_MARKET_QUESTION" = false ]; then
    echo "[WARN] AI Prediction Market question not found, sending 'Y' as fallback"
    screen -S gensynnode -X stuff "Y$(echo -ne '\r')"
  fi

  send_telegram_alert "$reason"
}

# --- MAIN ---
init_state

while true; do
  if check_for_error; then
    restart_process "error in logs"
  elif check_process; then
    restart_process "process not running"
  elif check_round_stall; then
    restart_process "no rounds within ${STALE_MINUTES}m (grace ${STARTUP_GRACE_MINUTES}m)"
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
Environment=STALE_MINUTES=30
Environment=STARTUP_GRACE_MINUTES=60
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
    -d parse_mode="Markdown" >/dev/null 2>&1
fi
