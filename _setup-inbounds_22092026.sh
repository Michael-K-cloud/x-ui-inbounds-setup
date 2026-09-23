#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BRIGHT_WHITE='\033[1;37m'
NC='\033[0m'

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Авто-настройка инбаундов: Trojan + Hysteria 2      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ Скрипт должен быть запущен от имени root${NC}"
  exit 1
fi

# 2. Проверка наличия x-ui
if ! systemctl list-unit-files 2>/dev/null | grep -q "x-ui.service"; then
  echo -e "${RED}❌ Служба x-ui не найдена. Сначала установите панель.${NC}"
  exit 1
fi

# 3. АВТОМАТИЧЕСКОЕ определение домена
echo -e "${CYAN}[1/5] Определение домена и исправление webDomain...${NC}"
DOMAIN=$(python3 << 'PYTHON_SCRIPT'
import sqlite3, json, subprocess

domain = ""
try:
    result = subprocess.run(['grep', '-rh', 'server_name', '/etc/nginx/'], capture_output=True, text=True)
    for line in result.stdout.split('\n'):
        if 'server_name' in line and 'localhost' not in line and '_' not in line and not line.strip().startswith('#'):
            parts = line.split('server_name')
            if len(parts) > 1:
                candidate = parts[1].strip().split(';')[0].strip().split()[0]
                if candidate and '.' in candidate:
                    domain = candidate
                    break
except: pass

if not domain:
    try:
        conn = sqlite3.connect("/etc/x-ui/x-ui.db")
        c = conn.cursor()
        c.execute("SELECT stream_settings FROM inbounds WHERE enable=1")
        for row in c.fetchall():
            try:
                settings = json.loads(row[0])
                if 'tlsSettings' in settings and 'serverName' in settings['tlsSettings']:
                    domain = settings['tlsSettings']['serverName']
                    break
            except: continue
        conn.close()
    except: pass

print(domain if domain else "ERROR:DOMAIN_NOT_FOUND")
PYTHON_SCRIPT
)

if [[ "$DOMAIN" == "ERROR:DOMAIN_NOT_FOUND" ]] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Не удалось определить домен. Укажите его в панели 3x-ui.${NC}"
    exit 1
fi

# Исправление бага с localhost в ссылках
echo -e "${YELLOW}Исправление webDomain в базе данных (фикс бага с localhost)...${NC}"
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='$DOMAIN' WHERE key='webDomain';"
systemctl start x-ui
sleep 2
echo -e "${GREEN}✅ Домен определен: $DOMAIN и зафиксирован в настройках.${NC}"

# 4. Работа с БД: Умное создание инбаундов
echo -e "${CYAN}[2/5] Настройка инбаундов по эталонному шаблону...${NC}"

export DOMAIN

DB_RESULT=$(python3 << 'PYTHON_SCRIPT'
import sqlite3, json, random, string, os

DB_PATH = "/etc/x-ui/x-ui.db"
DOMAIN = os.environ.get('DOMAIN')

def get_random_port():
    return random.randint(10000, 60000)

def get_random_string(length):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

conn = sqlite3.connect(DB_PATH)
c = conn.cursor()

# --- TROJAN SETUP ---
trojan_port = get_random_port()
trojan_svc = get_random_string(10)

# Проверяем, есть ли уже клиенты у Trojan
c.execute("SELECT settings FROM inbounds WHERE protocol='trojan' LIMIT 1")
row = c.fetchone()
trojan_clients = []
if row:
    try:
        settings = json.loads(row[0])
        if "clients" in settings and len(settings["clients"]) > 0:
            trojan_clients = settings["clients"] # Сохраняем существующих!
    except: pass

if not trojan_clients:
    trojan_clients = [{
        "password": get_random_string(16),
        "email": f"trojan_auto_{trojan_port}",
        "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True
    }]

trojan_settings = {"clients": trojan_clients, "decryption": "none"}
trojan_stream = {
    "network": "grpc", "security": "tls",
    "tlsSettings": {
        "serverName": DOMAIN, "minVersion": "1.2", "maxVersion": "1.3",
        "certificates": [{"certificateFile": f"/root/cert/{DOMAIN}/fullchain.pem", "keyFile": f"/root/cert/{DOMAIN}/privkey.pem", "ocspStapling": 3600, "oneTimeLoading": False, "usage": "encipherment", "buildChain": False}],
        "alpn": ["h2", "http/1.1"], "settings": {"fingerprint": "chrome"}
    },
    "grpcSettings": {"serviceName": trojan_svc, "authority": DOMAIN, "multiMode": False},
    "externalProxy": [{"forceTls": "same", "dest": DOMAIN, "port": trojan_port, "remark": "", "sni": "", "alpn": []}]
}

c.execute("DELETE FROM inbounds WHERE protocol='trojan'")
c.execute("""INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, client_stats, listen, port, protocol, settings, stream_settings, tag, sniffing, node_id)
    VALUES (1, 0, 0, 0, ?, 1, 0, '', '', ?, 'trojan', ?, ?, 'trojan_auto', '', 0)""", 
    (f"🤖 Trojan-gRPC {trojan_port}", trojan_port, json.dumps(trojan_settings), json.dumps(trojan_stream)))


# --- HYSTERIA 2 SETUP ---
hysteria_port = get_random_port()

# Проверяем, есть ли уже клиенты у Hysteria
c.execute("SELECT settings FROM inbounds WHERE protocol IN ('hysteria', 'hysteria2') LIMIT 1")
row = c.fetchone()
hysteria_clients = []
if row:
    try:
        settings = json.loads(row[0])
        if "clients" in settings and len(settings["clients"]) > 0:
            hysteria_clients = settings["clients"] # Сохраняем существующих!
    except: pass

if not hysteria_clients:
    hysteria_clients = [{
        "password": get_random_string(16),
        "auth": get_random_string16 := get_random_string(16),
        "email": f"hysteria_auto_{hysteria_port}",
        "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "security": "auto"
    }]

hysteria_settings = {"clients": hysteria_clients, "version": 2}
hysteria_stream = {
    "network": "hysteria",
    "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "", "dir": "", "url": "", "rewriteHost": False, "insecure": False, "content": "", "headers": {}, "statusCode": 0}},
    "security": "tls",
    "tlsSettings": {
        "serverName": DOMAIN, "minVersion": "1.3", "maxVersion": "1.3",
        "certificates": [{"certificateFile": f"/root/cert/{DOMAIN}/fullchain.pem", "keyFile": f"/root/cert/{DOMAIN}/privkey.pem", "ocspStapling": 3600, "oneTimeLoading": False, "usage": "encipherment", "buildChain": False}],
        "alpn": ["h3"], "settings": {"fingerprint": "firefox"}
    }
}

c.execute("DELETE FROM inbounds WHERE protocol IN ('hysteria', 'hysteria2')")
c.execute("""INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, client_stats, listen, port, protocol, settings, stream_settings, tag, sniffing, node_id)
    VALUES (1, 0, 0, 0, ?, 1, 0, '', '', ?, 'hysteria', ?, ?, 'hysteria_auto', '', 0)""", 
    (f"🤖 Hysteria2 {hysteria_port}", hysteria_port, json.dumps(hysteria_settings), json.dumps(hysteria_stream)))

conn.commit()
conn.close()
print(f"{trojan_port}|{trojan_svc}|{hysteria_port}")
PYTHON_SCRIPT
)

IFS='|' read -r T_PORT T_SVC H_PORT <<< "$DB_RESULT"
echo -e "${GREEN}✅ Trojan: порт $T_PORT, ServiceName: $T_SVC${NC}"
echo -e "${GREEN}✅ Hysteria: порт $H_PORT${NC}"

# 5. Настройка UFW с комментариями
echo -e "${CYAN}[3/5] Настройка брандмауэра (UFW)...${NC}"
ufw allow $T_PORT/tcp comment "Trojan-gRPC Auto" >/dev/null 2>&1
ufw allow $H_PORT/udp comment "Hysteria2 Auto" >/dev/null 2>&1
echo -e "${GREEN}✅ Порты открыты с комментариями.${NC}"

# 6. Патч Nginx для Trojan (grpcs://)
echo -e "${CYAN}[4/5] Патч Nginx для маскировки Trojan через 443...${NC}"
NGINX_CONF="/etc/nginx/snippets/includes.conf"
if [ ! -f "$NGINX_CONF" ]; then
    mkdir -p /etc/nginx/snippets
    echo "# Nginx snippets for x-ui" > "$NGINX_CONF"
fi

cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%F-%H%M)"

NGINX_BLOCK="
# Auto-generated Trojan gRPC fix (grpcs)
location /$T_SVC {
    grpc_pass grpcs://127.0.0.1:$T_PORT;
    grpc_ssl_name $DOMAIN;
    grpc_ssl_protocols TLSv1.2 TLSv1.3;
    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header Connection \"\";
}
"

if ! grep -q "location /$T_SVC" "$NGINX_CONF"; then
    echo "$NGINX_BLOCK" >> "$NGINX_CONF"
fi

if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}✅ Nginx успешно обновлен.${NC}"
else
    echo -e "${RED}❌ Ошибка Nginx! Откат...${NC}"
    cp "${NGINX_CONF}.bak.$(date +%F-%H%M)" "$NGINX_CONF"
    systemctl reload nginx
fi

# 7. Финал
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  ✅ Настройка инбаундов успешно завершена!${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo -e "${BRIGHT_WHITE}Данные для подключения (Прямые порты):${NC}"
echo -e "${CYAN}Trojan: trojan://<password>@${DOMAIN}:${T_PORT}?security=tls&type=grpc&serviceName=${T_SVC}&sni=${DOMAIN}#${DOMAIN}${NC}"
echo -e "${CYAN}Hysteria2: hysteria2://<password>@${DOMAIN}:${H_PORT}?alpn=h3&fp=firefox&security=tls&sni=${DOMAIN}#${DOMAIN}${NC}"
echo ""
echo -e "${YELLOW}⚠️ Пароли берутся из существующих клиентов или сгенерированы. Проверьте их в панели 3x-ui.${NC}"
