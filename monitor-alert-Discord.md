Hệ thống monitor + alert Discord của dự án Login-Form (nginx + docker compose)
-----

# 1. Mục tiêu
Thiết lập một monitor chạy định kỳ bằng **systemd timer** để:

- Kiểm tra trạng thái:
    - `nginx` (service)
    - `docker` (service)
    - Các container: `login_frontend`, `login_backend`, `login_db`
    - Origin HTTP/HTTPS (để bắt lỗi 502/connection refused…)
- Gửi **Discord embed** theo mẫu:
    - **DOWN**: hiển thị rõ “Down components: …”
    - **UP/RECOVERED**: hiển thị “Ping … ms”
- Không spam: có **cooldown** (mặc định 300s).

# 2. Các thành phần / File liên quan
## 2.1. File cấu hình
- `/etc/default/login-form-monitor`

Chứa biến cấu hình cho monitor (service name, url, domain, timezone, webhook…).

## 2.2. Script monitor
- `/usr/local/bin/monitor_login_form.sh`

Thực hiện healthcheck, tổng hợp “Down components”, gửi Discord embed, ghi log.

## 2.3. systemd unit & timer
- `/etc/systemd/system/login-form-monitor.service` (oneshot)
- `/etc/systemd/system/login-form-monitor.timer` (chạy mỗi phút)

## 2.4. Log & state
- Log: `/var/log/login-form-monitor.log`
- Cooldown state: `/var/run/login-form-monitor.state`
- Trạng thái lần trước: `/var/run/login-form-monitor.last_status`

# 3. Cài đặt từ đầu (chuẩn)

> Khuyến nghị: luôn dùng `tee <<'EOF'` để tránh lỗi dính lệnh do paste dài. </br>
Lưu ý: **Webhook nên đặt trong dấu ngoặc kép**.


**Bước 1 — Dừng timer cũ và dọn state**
```bash
sudo systemctl stop login-form-monitor.timer 2>/dev/null || true
sudo systemctl disable login-form-monitor.timer 2>/dev/null || true

sudo rm -f /var/run/login-form-monitor.state /var/run/login-form-monitor.last_status

# (tuỳ chọn) reset log sạch
sudo rm -f /var/log/login-form-monitor.log
sudo touch /var/log/login-form-monitor.log
sudo chmod 640 /var/log/login-form-monitor.log
```

**Bước 2 — Tạo cấu hình `/etc/default/login-form-monitor`**
```bash
sudo tee /etc/default/login-form-monitor >/dev/null <<'EOF'
SERVICE_NAME="Login-Form"
SERVICE_URL="https://app.onnetdev.site/"
DOMAIN="app.onnetdev.site"
TIMEZONE="Asia/Ho_Chi_Minh"

APP_DIR="/home/ubuntu/login-form"
LOG_FILE="/var/log/login-form-monitor.log"
STATE_FILE="/var/run/login-form-monitor.state"
LAST_STATUS_FILE="/var/run/login-form-monitor.last_status"

COOLDOWN_SECONDS="300"
CURL_TIMEOUT_SECONDS="8"

DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/1463015259303448761/LfWpMmH5LD4Dapi0seRlLZwvYCcdAX9D0fe81NlYnHe5hLYxz-hTJ2zTD9yJ4FQEXjLf"
EOF

sudo chmod 600 /etc/default/login-form-monitor
sudo touch /var/log/login-form-monitor.log
sudo chmod 640 /var/log/login-form-monitor.log
```

**Bước 3 — Tạo script monitor**
> Nội dung script là bản bạn đã chạy ổn (DOWN/UP có embed). </br>
Nếu bạn đã có script hoàn chỉnh rồi thì chỉ cần đảm bảo file này **không bị “truncated”** do paste dài.

```bash
sudo tee /usr/local/bin/monitor_login_form.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/login-form-monitor

ts_utc(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_tz(){ TZ="${TIMEZONE}" date +"%Y-%m-%d %H:%M:%S"; }
hostn(){ hostname 2>/dev/null || echo "unknown-host"; }

log(){ echo "[$(ts_utc)] $*" | tee -a "${LOG_FILE}" >/dev/null; }

cooldown_ok(){
  local now last=0
  now="$(date +%s)"
  [[ -f "${STATE_FILE}" ]] && last="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"
  (( now - last < COOLDOWN_SECONDS )) && return 1
  echo "${now}" > "${STATE_FILE}" || true
  return 0
}

curl_check(){
  local url="$1"; shift
  local out err rc code tt
  err="$(mktemp)"; rc=0
  out="$(curl -sS -o /dev/null --max-time "${CURL_TIMEOUT_SECONDS}" -w "%{http_code} %{time_total}" "$url" "$@" 2>"$err")" || rc=$?
  if (( rc != 0 )); then
    echo "0 0 $(tr -d '\n' <"$err" | head -c 180)"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  code="$(awk '{print $1}' <<<"$out")"
  tt="$(awk '{print $2}' <<<"$out")"
  echo "${code} ${tt} -"
}

cstate(){
  local n="$1"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$n" || { echo "missing"; return; }
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$n" && { echo "running"; return; }
  echo "stopped"
}

dbhealth(){
  local n="$1" st h
  st="$(cstate "$n")"
  [[ "$st" != "running" ]] && { echo "n/a"; return; }
  h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n" 2>/dev/null || true)"
  [[ -z "$h" ]] && { echo "none"; return; }
  [[ "$h" == "healthy" ]] && echo "healthy" || echo "unhealthy:${h}"
}

send_discord_embed(){
  local status="$1" # DOWN/UP
  local error="$2"
  local ping_ms="$3"

  [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0

  local title color field_name field_value
  if [[ "$status" == "DOWN" ]]; then
    title="❌ Your service ${SERVICE_NAME} went down. ❌"
    color=15158332
    field_name="Error"
    field_value="${error}"
  else
    title="✅ Your service ${SERVICE_NAME} is up! ✅"
    color=3066993
    field_name="Ping"
    field_value="${ping_ms} ms"
  fi

  local payload
  payload="$(python3 - "$title" "$color" "$field_name" "$field_value" "${SERVICE_NAME}" "${SERVICE_URL}" "$(ts_tz)" "${TIMEZONE}" <<'PY'
import json,sys
title,color,fn,fv,sn,su,t,tz=sys.argv[1:9]
def clip(s,n=1024):
  s=str(s or "")
  return s if len(s)<=n else s[:n]
payload={
  "embeds":[
    {
      "title": clip(title,256),
      "color": int(color),
      "fields":[
        {"name":"Service Name","value":clip(sn), "inline":False},
        {"name":"Service URL","value":clip(su), "inline":False},
        {"name":f"Time ({tz})","value":clip(t), "inline":False},
        {"name":clip(fn,256),"value":clip(fv), "inline":False},
      ],
      "footer":{"text":"login-form monitor"}
    }
  ]
}
print(json.dumps(payload))
PY
)"
  curl -fsS -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

downs=()
err_detail=""

systemctl is-active --quiet nginx  || downs+=("nginx(service_down)")
systemctl is-active --quiet docker || downs+=("docker(service_down)")

if systemctl is-active --quiet docker; then
  f="$(cstate login_frontend)"; [[ "$f" != running ]] && downs+=("login_frontend(${f})")
  b="$(cstate login_backend)";  [[ "$b" != running ]] && downs+=("login_backend(${b})")
  d="$(cstate login_db)"
  if [[ "$d" != running ]]; then
    downs+=("login_db(${d})")
  else
    h="$(dbhealth login_db)"
    [[ "$h" == unhealthy:* ]] && downs+=("login_db(${h})")
  fi
fi

read -r code tt cerr < <(curl_check "http://127.0.0.1/" -H "Host: ${DOMAIN}")
if [[ "$code" == "0" ]]; then
  downs+=("origin_http(connect_failed)")
  err_detail="${cerr}"
elif (( code < 200 || code >= 400 )); then
  downs+=("origin_http(http_${code})")
fi

read -r scode stt scerr < <(curl_check "https://${DOMAIN}/" -k --resolve "${DOMAIN}:443:127.0.0.1")
if [[ "$scode" == "0" ]]; then
  downs+=("origin_https(connect_failed)")
  [[ -z "$err_detail" ]] && err_detail="${scerr}"
elif (( scode < 200 || scode >= 400 )); then
  downs+=("origin_https(http_${scode})")
fi

last="OK"; [[ -f "${LAST_STATUS_FILE}" ]] && last="$(cat "${LAST_STATUS_FILE}" 2>/dev/null || echo OK)"

if (( ${#downs[@]} > 0 )); then
  list="$(IFS=', '; echo "${downs[*]}")"
  if [[ -n "${err_detail}" ]]; then
    error="Down components: ${list}\nDetail: ${err_detail}"
  else
    error="Down components: ${list}"
  fi

  log "ALERT: DOWN ${list}"
  if cooldown_ok; then
    send_discord_embed "DOWN" "${error}" ""
  else
    log "ALERT suppressed due to cooldown (${COOLDOWN_SECONDS}s)"
  fi
  echo "DOWN" > "${LAST_STATUS_FILE}" || true
else
  ping_ms="0"
  if [[ "${stt}" != "-" && "${stt}" != "0" ]]; then
    ping_ms="$(python3 - <<PY
t=float("${stt}"); print(int(round(t*1000)))
PY
)"
  else
    ping_ms="$(python3 - <<PY
t=float("${tt}"); print(int(round(t*1000)))
PY
)"
  fi

  log "OK: healthy"
  if [[ "${last}" == "DOWN" ]]; then
    send_discord_embed "UP" "" "${ping_ms}"
  fi
  echo "OK" > "${LAST_STATUS_FILE}" || true
fi
BASH

sudo chmod +x /usr/local/bin/monitor_login_form.sh
```

**Bước 4 — Tạo systemd service + timer**
```bash
sudo tee /etc/systemd/system/login-form-monitor.service >/dev/null <<'UNIT'
[Unit]
Description=Login Form monitor (healthcheck + Discord alert)
After=network-online.target docker.service nginx.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/default/login-form-monitor
ExecStart=/usr/local/bin/monitor_login_form.sh
UNIT

sudo tee /etc/systemd/system/login-form-monitor.timer >/dev/null <<'TIMER'
[Unit]
Description=Run Login Form monitor every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now login-form-monitor.timer
```

# 4. Vận hành / Test
## 4.1. Chạy tay 1 lần (khuyến nghị để xác nhận)
```bash
sudo rm -f /var/run/login-form-monitor.state /var/run/login-form-monitor.last_status
sudo systemctl start login-form-monitor.service
```

## 4.2. Test DOWN/UP cho Docker
- DOWN
```bash
cd /home/ubuntu/login-form
docker compose down
sudo rm -f /var/run/login-form-monitor.state
sudo systemctl start login-form-monitor.service
```

- UP/RECOVERED:
```bash
cd /home/ubuntu/login-form
docker compose up -d
sudo rm -f /var/run/login-form-monitor.state
sudo systemctl start login-form-monitor.service
```

Sẽ nhận 2 embed:
- **DOWN**: `Down components: login_frontend(missing), login_backend(missing), login_db(missing), origin_https(http_502)…`
- **UP**: `Ping: X ms`

## 4.3. Xem timer đang chạy
```bash
systemctl list-timers | grep login-form-monitor
```

# 5. Troubleshooting (các lỗi hay gặp)
## 5.1. “Không thấy alert”
Kiểm tra:
```bash
sudo journalctl -u login-form-monitor.service -n 200 --no-pager
```
Lỗi thường gặp:
- `cooldown` đang chặn: xoá file state </br>
`sudo rm -f /var/run/login-form-monitor.state`
- Webhook sai hoặc thiếu dấu ngoặc kép trong file env.

## 5.2. File env sai format
Đảm bảo webhook trong `/etc/default/login-form-monitor` là:
```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/...."
```
Không khuyến nghị để trần không có ngoặc kép.

## 5.3. Script bị “truncated” do paste dài

Nếu lúc `tee` bị dính lệnh/đứt đoạn, hãy:

- Dán lại bằng here-doc như hướng dẫn, hoặc
- `sudo nano /usr/local/bin/monitor_login_form.sh` rồi paste sạch, lưu lại.

# 6. Bảo mật & khuyến nghị
- **Webhook Discord là secret**: chỉ để quyền đọc root (đã chmod 600).

- Không commit webhook vào git. Nếu muốn đưa vào repo, dùng file mẫu:

    - `ops/monitoring/login-form-monitor.env.example` (không chứa webhook thật).


# 7. Trạng thái hiện tại (đã xác nhận hoạt động)

Hệ thống hiện đã:

- Gửi Discord embed **DOWN** với “Down components: …”

- Gửi Discord embed **UP** với “Ping … ms”

- Kiểm tra được cả “docker compose down/up” và phản ánh rõ container nào missing/stopped.








