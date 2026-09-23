#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BRIGHT_WHITE='\033[1;37m'; NC='\033[0m'

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Авто-настройка инбаундов: Trojan + Hysteria 2      ${NC}"
echo -e "${GREEN}=====================================================${NC}"

if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ Нужен root${NC}"; exit 1; fi
if ! systemctl list-unit-files 2>/dev/null | grep -q "x-ui.service"; then
  echo -e "${RED}❌ Служба x-ui не найдена${NC}"; exit 1
fi

# --- [1/5] Домен + фикс webDomain (баг localhost) ---
echo -e "${CYAN}[1/5] Определение домена и фикс webDomain...${NC}"
DOMAIN=$(python3 << 'PY'
import sqlite3, json, subprocess
domain = ""
try:
    r = subprocess.run(['grep','-rh','server_name','/etc/nginx/'], capture_output=True, text=True)
    for line in r.stdout.split('\n'):
        if 'server_name' in line and 'localhost' not in line and '_' not in line and not line.strip().startswith('#'):
            cand = line.split('server_name')[1].strip().split(';')[0].strip().split()[0]
            if cand and '.' in cand: domain = cand; break
except: pass
if not domain:
    try:
        conn = sqlite3.connect("/etc/x-ui/x-ui.db"); c = conn.cursor()
        c.execute("SELECT stream_settings FROM inbounds WHERE enable=1")
        for (raw,) in c.fetchall():
            try:
                s = json.loads(raw)
                if 'tlsSettings' in s and s['tlsSettings'].get('serverName'):
                    domain = s['tlsSettings']['serverName']; break
            except: continue
        conn.close()
    except: pass
print(domain or "ERROR:DOMAIN_NOT_FOUND")
PY
)
if [[ "$DOMAIN" == "ERROR:DOMAIN_NOT_FOUND" ]] || [ -z "$DOMAIN" ]; then
  echo -e "${RED}❌ Домен не определён — укажите его в панели 3x-ui${NC}"; exit 1
fi
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='$DOMAIN' WHERE key='webDomain';"
systemctl start x-ui
sleep 2
echo -e "${GREEN}✅ Домен: $DOMAIN зафиксирован${NC}"

# --- Бэкап БД ПЕРЕД любыми удалениями ---
cp -a /etc/x-ui/x-ui.db "/etc/x-ui/x-ui.db.bak.$(date +%F-%H%M)"
echo -e "${GREEN}✅ Бэкап БД: /etc/x-ui/x-ui.db.bak.$(date +%F-%H%M)${NC}"

# --- [2/5] Сбор клиентов и пересоздание инбаундов ---
echo -e "${CYAN}[2/5] Копирование клиентов и создание эталонных инбаундов...${NC}"
export DOMAIN
DB_RESULT=$(python3 << 'PY'
import sqlite3, json, random, string, os, socket

DB = "/etc/x-ui/x-ui.db"; DOMAIN = os.environ['DOMAIN']
def rnd(n): return ''.join(random.choices(string.ascii_letters + string.digits, k=n))
def port_free(p, udp):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: s.bind(("0.0.0.0", p)); return True
    except OSError: return False
    finally: s.close()
def pick_port(prefer, udp):
    if prefer and port_free(prefer, udp): return prefer
    while True:
        p = random.randint(10000, 60000)
        if port_free(p, udp): return p

conn = sqlite3.connect(DB); c = conn.cursor()

# 1) Все уникальные клиенты из ВСЕХ инбаундов (ключ — subId, иначе email)
c.execute("SELECT settings FROM inbounds")
uniq = {}
for (raw,) in c.fetchall():
    try: obj = json.loads(raw)
    except Exception: continue
    for cl in (obj.get("clients") or []):
        key = cl.get("subId") or cl.get("email")
        if key and key not in uniq: uniq[key] = cl

# 2) Адаптация под протокол: объект копируется дословно,
#    flow убирается (только для VLESS), недостающие password/auth генерируются
def adapt(cl, proto):
    o = dict(cl); o.pop("flow", None)
    if proto == "trojan" and not o.get("password"): o["password"] = rnd(16)
    if proto == "hysteria" and not o.get("auth"):   o["auth"] = rnd(16)
    return o
t_clients = [adapt(cl, "trojan")   for cl in uniq.values()]
h_clients = [adapt(cl, "hysteria") for cl in uniq.values()]

# 3) Порты: переиспользуем порт удаляемого инбаунда, иначе свободный случайный
c.execute("SELECT port FROM inbounds WHERE protocol='trojan' LIMIT 1")
r = c.fetchone(); t_prefer = r[0] if r else None
c.execute("SELECT port FROM inbounds WHERE protocol IN ('hysteria','hysteria2') LIMIT 1")
r = c.fetchone(); h_prefer = r[0] if r else None
t_port = pick_port(t_prefer, udp=False)
h_port = pick_port(h_prefer, udp=True)
t_svc  = rnd(10)

cert = f"/root/cert/{DOMAIN}/fullchain.pem"; key = f"/root/cert/{DOMAIN}/privkey.pem"
t_stream = {
  "network":"grpc","security":"tls",
  "tlsSettings":{"serverName":DOMAIN,"minVersion":"1.2","maxVersion":"1.3",
    "certificates":[{"certificateFile":cert,"keyFile":key,"ocspStapling":3600,
      "oneTimeLoading":False,"usage":"encipherment","buildChain":False}],
    "alpn":["h2","http/1.1"],"settings":{"fingerprint":"chrome"}},
  "grpcSettings":{"serviceName":t_svc,"authority":DOMAIN,"multiMode":False},
  "externalProxy":[{"forceTls":"same","dest":DOMAIN,"port":t_port,"remark":"","sni":"","alpn":[]}]
}
h_stream = {
  "network":"hysteria",
  "hysteriaSettings":{"version":2,"udpIdleTimeout":60,
    "masquerade":{"type":"","dir":"","url":"","rewriteHost":False,"insecure":False,
      "content":"","headers":{},"statusCode":0}},
  "security":"tls",
  "tlsSettings":{"serverName":DOMAIN,"minVersion":"1.3","maxVersion":"1.3",
    "certificates":[{"certificateFile":cert,"keyFile":key,"ocspStapling":3600,
      "oneTimeLoading":False,"usage":"encipherment","buildChain":False}],
    "alpn":["h3"],"settings":{"fingerprint":"firefox"}}
}

# 4) Удаляем старые и вставляем эталонные (клиенты могут быть пустыми — это валидно)
c.execute("DELETE FROM inbounds WHERE protocol='trojan'")
c.execute("DELETE FROM inbounds WHERE protocol IN ('hysteria','hysteria2')")
c.execute("""INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,client_stats,listen,port,protocol,settings,stream_settings,tag,sniffing,node_id)
  VALUES (1,0,0,0,?,1,0,'','',?,'trojan',?,?,'trojan_auto','',0)""",
  (f"🤖 Trojan-gRPC {t_port}", t_port, json.dumps({"clients": t_clients}), json.dumps(t_stream)))
c.execute("""INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,client_stats,listen,port,protocol,settings,stream_settings,tag,sniffing,node_id)
  VALUES (1,0,0,0,?,1,0,'','',?,'hysteria',?,?,'hysteria_auto','',0)""",
  (f"🤖 Hysteria2 {h_port}", h_port, json.dumps({"clients": h_clients, "version": 2}), json.dumps(h_stream)))
conn.commit(); conn.close()
print(f"{t_port}|{t_svc}|{h_port}|{len(uniq)}")
PY
)
IFS='|' read -r T_PORT T_SVC H_PORT C_COUNT <<< "$DB_RESULT"
echo -e "${GREEN}✅ Trojan: порт $T_PORT, serviceName $T_SVC${NC}"
echo -e "${GREEN}✅ Hysteria2: порт $H_PORT${NC}"
echo -e "${GREEN}✅ Скопировано уникальных клиентов: $C_COUNT (данные сохранены 1-в-1)${NC}"

# --- [3/5] UFW с комментариями ---
echo -e "${CYAN}[3/5] Брандмауэр...${NC}"
ufw allow $T_PORT/tcp comment "Trojan-gRPC Auto" >/dev/null 2>&1
ufw allow $H_PORT/udp comment "Hysteria2 Auto" >/dev/null 2>&1
echo -e "${GREEN}✅ Порты открыты${NC}"

# --- [4/5] Патч Nginx (grpcs://) ---
echo -e "${CYAN}[4/5] Патч Nginx для маскировки Trojan через 443...${NC}"
NGINX_CONF="/etc/nginx/snippets/includes.conf"
[ -f "$NGINX_CONF" ] || { mkdir -p /etc/nginx/snippets; echo "# Nginx snippets for x-ui" > "$NGINX_CONF"; }
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%F-%H%M)"
if ! grep -q "location /$T_SVC" "$NGINX_CONF"; then
cat >> "$NGINX_CONF" << EOF

# Auto-generated Trojan gRPC fix (grpcs)
location /$T_SVC {
    grpc_pass grpcs://127.0.0.1:$T_PORT;
    grpc_ssl_name $DOMAIN;
    grpc_ssl_protocols TLSv1.2 TLSv1.3;
    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header Connection "";
}
EOF
fi
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx; echo -e "${GREEN}✅ Nginx обновлён${NC}"
else
  echo -e "${RED}❌ Ошибка Nginx — откат${NC}"
  cp "${NGINX_CONF}.bak.$(date +%F-%H%M)" "$NGINX_CONF"; systemctl reload nginx
fi

# --- [5/5] Итог ---
systemctl restart x-ui
sleep 3
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  ✅ Готово${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "Trojan:   порт ${T_PORT} (tcp), serviceName ${T_SVC}, маскировка через 443 включена"
echo -e "Hysteria: порт ${H_PORT} (udp)"
echo -e "Клиентов перенесено: ${C_COUNT}. Пароли и ключи НЕ выводятся — они в панели и у бота."
