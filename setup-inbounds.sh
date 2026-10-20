#!/bin/bash
# ============================================================================
#  setup-inbounds.sh v2.0 — x-ui-inbounds-setup (Michael-K-cloud)
#
#  Эталонные инбаунды Trojan-gRPC + Hysteria2 и ПЕРЕНОС инбаундов между
#  серверами 3X-UI с полным сохранением клиентов (uuid/пароли/ключи не
#  перегенерируются — ссылки клиентов не ломаются).
#
#  Режимы:
#    (без аргументов) | local   — создать/обновить эталонные инбаунды
#                                 Trojan-gRPC + Hysteria2 на ЭТОМ сервере
#    export [FILE]              — консистентный экспорт локальных инбаундов
#                                 и клиентов в JSON-файл (на ИСХОДНОМ сервере)
#    import FILE                — импорт инбаундов из файла экспорта
#                                 (на ЦЕЛЕВОМ сервере)
#
#  Флаги:
#    --force-master   разрешить записывающий режим на мастере с нодами
#    --yes, -y        не спрашивать подтверждение
#    --dry-run        только план изменений, ничего не писать
#    -h, --help       справка
#
#  Переменные окружения (переопределение путей, в основном для тестирования):
#    XUI_DB           путь к БД панели        (по умолчанию /etc/x-ui/x-ui.db)
#    XUI_CERT_DIR     каталог сертификатов    (по умолчанию /root/cert)
#    XUI_NGINX_CONF   snippets-конфиг nginx   (по умолчанию /etc/nginx/snippets/includes.conf)
#    XUI_NGINX_DIR    каталог nginx для grep  (по умолчанию /etc/nginx/)
#    XUI_SERVICE      имя службы панели       (по умолчанию x-ui)
#    XUI_BACKUP_ROOT  каталог бэкапов         (по умолчанию /root/backups/inbounds-setup)
#    XUI_CONFIG_JSON  config.json xray        (по умолчанию /usr/local/x-ui/bin/config.json)
#
#  Безопасность (v2.0 — реализованы все 5 обязательных правок
#  по разбору Repo_inbounds-setup_fixes.md от 24.09.2026):
#    1) схема читается через PRAGMA table_info — никакого хардкода колонок
#       (старый INSERT с несуществующей client_stats на 3.3.1 падал);
#    2) все операции — только с локальными инбаундами (node_id=0);
#       на мастере с нодами записывающие режимы блокируются без --force-master;
#    3) связанные таблицы (client_inbounds, client_traffics, inbound_fallbacks)
#       вычищаются ДО удаления инбаундов — без сирот;
#    4) бэкап — консистентный (sqlite3 .backup, Online Backup API) с проверкой
#       integrity_check ДО любых изменений; без годной точки отката скрипт не пишет;
#    5) все записи — при ОСТАНОВЛЕННОЙ панели, в одной транзакции
#       (BEGIN IMMEDIATE … COMMIT, при любой ошибке ROLLBACK), со сверкой
#       счётчиков и integrity_check до и после.
#  Дополнительно: существующий инбаунд ОБНОВЛЯЕТСЯ НА МЕСТЕ (id, порт,
#  serviceName, tag сохраняются — ссылки и nginx-локации не ломаются);
#  учётные данные клиентов переносятся 1-в-1 (реестр полей union по всем
#  локальным инбаундам — порядок строк больше не влияет); UFW и nginx —
#  с бэкапом, nginx -t и автооткатом; живая БД читается только mode=ro&immutable=1.
# ============================================================================
set -u

SCRIPT_VERSION="2.0"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
CERT_DIR="${XUI_CERT_DIR:-/root/cert}"
NGINX_CONF="${XUI_NGINX_CONF:-/etc/nginx/snippets/includes.conf}"
NGINX_DIR="${XUI_NGINX_DIR:-/etc/nginx/}"
SVC="${XUI_SERVICE:-x-ui}"
BACKUP_ROOT="${XUI_BACKUP_ROOT:-/root/backups/inbounds-setup}"
CONFIG_JSON="${XUI_CONFIG_JSON:-/usr/local/x-ui/bin/config.json}"

TMPD=$(mktemp -d /tmp/inbounds-setup.XXXXXX) || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

usage() {
  cat <<USAGE
setup-inbounds.sh v${SCRIPT_VERSION} — эталонные инбаунды и перенос между серверами

Использование:
  bash setup-inbounds.sh                    локальный режим (Trojan-gRPC + Hysteria2)
  bash setup-inbounds.sh export [FILE]      экспорт инбаундов+клиентов (JSON, права 600)
  bash setup-inbounds.sh import FILE        импорт из файла экспорта
Флаги:
  --force-master   разрешить запись на мастере с нодами (ОПАСНО, осознанно)
  --yes, -y        без подтверждения
  --dry-run        только план, без изменений
USAGE
}

# ---------------------------------------------------------------- аргументы
MODE=""; FILE=""; FORCE_MASTER=0; ASSUME_YES=0; DRY_RUN=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    local|export|import) MODE="$1"; shift ;;
    --force-master) FORCE_MASTER=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo -e "${RED}❌ Неизвестный флаг: $1${NC}"; usage; exit 1 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ -n "$MODE" ] || MODE="local"
if [ ${#ARGS[@]} -gt 0 ]; then FILE="${ARGS[0]}"; fi
if [ ${#ARGS[@]} -gt 1 ]; then echo -e "${RED}❌ Лишний аргумент: ${ARGS[1]}${NC}"; exit 1; fi
if [ "$MODE" = "import" ] && [ -z "$FILE" ]; then
  echo -e "${RED}❌ Режим import требует файл экспорта: setup-inbounds.sh import FILE${NC}"; exit 1
fi
if [ "$MODE" = "import" ] && [ ! -f "$FILE" ]; then
  echo -e "${RED}❌ Файл не найден: $FILE${NC}"; exit 1
fi

die() { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  x-ui-inbounds-setup v${SCRIPT_VERSION} — режим: ${MODE}${NC}"
echo -e "${GREEN}=====================================================${NC}"

# ------------------------------------------------------------ базовые проверки
[ "$(id -u)" -eq 0 ] || die "Нужен root"
command -v python3 >/dev/null 2>&1 || die "python3 не найден"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 не найден"
[ -f "$DB" ] || die "БД панели не найдена: $DB"
if ! systemctl list-unit-files 2>/dev/null | grep -q "${SVC}\.service"; then
  die "Служба ${SVC}.service не найдена — панель не установлена?"
fi

# защита от запуска на мастере (правка 2) — только для записывающих режимов
nodes_count() {
  local n
  n=$(sqlite3 "file:${DB}?mode=ro&immutable=1" "SELECT COUNT(*) FROM nodes;" 2>/dev/null)
  if [ -n "$n" ]; then echo "$n"; return; fi
  if sqlite3 "file:${DB}?mode=ro&immutable=1" "PRAGMA table_info(nodes);" 2>/dev/null | grep -q .; then
    echo "ERR"
  else
    echo 0   # таблицы nodes нет — обычный одиночный сервер
  fi
}
if [ "$MODE" != "export" ]; then
  NODES=$(nodes_count)
  [ "$NODES" = "ERR" ] && die "Не удалось прочитать nodes — схема неизвестна, останавливаюсь"
  if [ "$NODES" -gt 0 ]; then
    echo -e "${RED}❌ Это МАСТЕР: в таблице nodes $NODES записей. Скрипт меняет инбаунды${NC}"
    echo -e "${RED}   и может задеть синхронизацию с нодами. Запуск — только с явным флагом.${NC}"
    [ "$FORCE_MASTER" -eq 1 ] || exit 1
    echo -e "${YELLOW}⚠️  --force-master: продолжаю на мастере (инбаунды нод не трогаются, node_id=0)${NC}"
  fi
fi

# --------------------------------------------------------- python-библиотека
cat > "$TMPD/lib.py" <<'PYLIB'
# -*- coding: utf-8 -*-
"""Вся работа с БД — здесь. Живая БД читается только mode=ro&immutable=1.
Запись — единственной транзакцией при остановленной панели (гарантирует bash-часть)."""
import sqlite3, json, os, sys, random, string, socket, re, subprocess, datetime

DB       = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
CERT_DIR = os.environ.get("XUI_CERT_DIR", "/root/cert")
NGINX_DIR= os.environ.get("XUI_NGINX_DIR", "/etc/nginx/")
SNIFF_DEFAULT = '{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'

def rnd(n): return ''.join(random.choices(string.ascii_letters + string.digits, k=n))

def port_free(p, udp=False):
    try: p = int(p)
    except Exception: return False
    if p <= 0: return False
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try: s.bind(("0.0.0.0", p)); return True
    except OSError: return False
    finally: s.close()

def pick_port(prefer, udp=False, avoid=()):
    """(порт, изменился_ли). prefer — порт источника/существующий."""
    if prefer and int(prefer) not in avoid and port_free(prefer, udp):
        return int(prefer), False
    for _ in range(200):
        p = random.randint(10000, 60000)
        if p not in avoid and port_free(p, udp):
            return p, True
    raise SystemExit("ABORT: не найден свободный порт")

def ro_conn(db=None):
    return sqlite3.connect("file:%s?mode=ro&immutable=1" % (db or DB), timeout=15)

def cols_of(c, t):  return [r[1] for r in c.execute("PRAGMA table_info(%s)" % t).fetchall()]
def colinfo(c, t):  return c.execute("PRAGMA table_info(%s)" % t).fetchall()
def tables_of(c):   return {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}

def counters(c):
    out = {}
    for t in ("inbounds", "clients", "client_inbounds", "client_traffics"):
        try: out[t] = c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
        except Exception: out[t] = None
    return out

def client_key(cl):
    return cl.get("subId") or cl.get("email") or cl.get("id") or cl.get("uuid") or ""

def is_udp(proto): return proto in ("hysteria", "hysteria2")

def generic_insert(c, table, vals):
    """INSERT по фактической схеме: несуществующие колонки игнорируются,
    колонки с DEFAULT пропускаются, NOT NULL без дефолта получают типовую пустую wartość."""
    info = colinfo(c, table)
    fields, args = [], []
    for cid, name, ctype, notnull, dflt, pk in info:
        if pk and (ctype or "").upper().startswith("INTEGER"):
            continue
        if name in vals:
            fields.append(name); args.append(vals[name]); continue
        if dflt is not None:
            continue
        if notnull:
            t = (ctype or "").upper()
            fields.append(name)
            args.append(0 if t in ("INTEGER", "INT", "BIGINT", "NUMERIC", "REAL", "FLOAT") else "")
    if not fields:
        raise RuntimeError("таблица %s: нечего вставлять" % table)
    c.execute("INSERT INTO %s (%s) VALUES (%s)" % (table, ",".join(fields), ",".join("?" * len(fields))), args)
    return c.lastrowid

def unique_tag(c, base):
    tag, i = base, 2
    while c.execute("SELECT 1 FROM inbounds WHERE tag=? LIMIT 1", (tag,)).fetchone():
        tag = "%s_%d" % (base, i); i += 1
    return tag

def user_id(c):
    try:
        r = c.execute("SELECT MIN(id) FROM users").fetchone()
        if r and r[0] is not None: return r[0]
    except Exception: pass
    return 1

def local_filter(c):
    return " WHERE COALESCE(node_id,0)=0" if "node_id" in cols_of(c, "inbounds") else ""

def load_local_inbounds(c):
    icols = cols_of(c, "inbounds")
    rows = c.execute("SELECT * FROM inbounds" + local_filter(c) + " ORDER BY id").fetchall()
    return icols, [dict(zip(icols, r)) for r in rows]

def settings_clients(ib):
    try: return (json.loads(ib.get("settings") or "{}").get("clients") or [])
    except Exception: return []

def build_registry(inbs):
    """Реестр клиентов: union всех полей по всем локальным инбаундам.
    Ключ — subId|email|id|uuid. Учётка, встреченная в ЛЮБОМ протоколе,
    сохраняет свой password/auth/uuid — порядок строк больше не влияет."""
    reg = {}
    for ib in inbs:
        for cl in settings_clients(ib):
            k = client_key(cl)
            if not k: continue
            e = reg.setdefault(k, {})
            for f, v in cl.items():
                if f not in e or e.get(f) in ("", None):
                    e[f] = v
    return reg

def adapt(merged, proto, generated):
    """Копирует учётку 1-в-1; flow — только VLESS; недостающий password/auth —
    из реестра; генерация — только если учётка ни разу не встречалась в этом протоколе."""
    o = dict(merged); o.pop("flow", None)
    if proto == "trojan" and not o.get("password"):
        o["password"] = rnd(16); generated.append("%s(trojan)" % (client_key(o) or "?"))
    if proto in ("hysteria", "hysteria2") and not o.get("auth"):
        o["auth"] = rnd(16); generated.append("%s(hysteria)" % (client_key(o) or "?"))
    return o

def delete_inbounds_with_deps(c, ids, tabs):
    """Правка 3: зависимости вычищаются ДО удаления самих инбаундов."""
    if not ids: return 0
    marks = ",".join("?" * len(ids))
    for tbl, col in (("client_inbounds", "inbound_id"), ("client_traffics", "inbound_id"),
                     ("inbound_fallbacks", "master_id"), ("inbound_fallbacks", "child_id")):
        if tbl in tabs and col in cols_of(c, tbl):
            c.execute("DELETE FROM %s WHERE %s IN (%s)" % (tbl, col, marks), ids)
    c.execute("DELETE FROM inbounds WHERE id IN (%s)" % marks, ids)
    return len(ids)

def sync_fork_clients(c, tabs, inbound_id, clients_json, warn):
    """x-ui-pro хранит клиентов ещё и в таблицах clients/client_inbounds.
    Синхронизация best-effort: найти-или-создать клиента, обеспечить связь.
    На стандартной 3x-ui этих таблиц нет — функция просто не вызывается."""
    if not ("clients" in tabs and "client_inbounds" in tabs): return
    ccols, lcols = cols_of(c, "clients"), cols_of(c, "client_inbounds")
    if "inbound_id" not in lcols: return
    for cl in clients_json:
        try:
            cid = ensure_client(c, ccols, cl)
            if cid is not None:
                ensure_link(c, lcols, cid, inbound_id)
        except Exception as e:
            warn.append("fork-sync клиент %s: %s: %s" % (client_key(cl) or "?", type(e).__name__, e))

def ensure_client(c, ccols, cl):
    """Найти или создать строку в clients по uuid/email/sub_id. cl — JSON-подобный словарь."""
    idcol = ccols[0] if ccols else "id"
    cands = []
    if "uuid" in ccols:
        v = cl.get("id") or cl.get("uuid")
        if v: cands.append(("uuid", v))
    if "email" in ccols and cl.get("email"): cands.append(("email", cl["email"]))
    if "sub_id" in ccols and cl.get("subId"): cands.append(("sub_id", cl["subId"]))
    for col, val in cands:
        r = c.execute("SELECT %s FROM clients WHERE %s=? LIMIT 1" % (idcol, col), (val,)).fetchone()
        if r: return r[0]
    ins = {}
    if "email" in ccols and cl.get("email"): ins["email"] = cl["email"]
    if "uuid" in ccols: ins["uuid"] = cl.get("id") or cl.get("uuid") or rnd(32)
    if "sub_id" in ccols and cl.get("subId"): ins["sub_id"] = cl["subId"]
    if "enable" in ccols: ins["enable"] = 1 if cl.get("enable", True) else 0
    if "expiry_time" in ccols: ins["expiry_time"] = cl.get("expiryTime", 0) or 0
    if "limit_ip" in ccols and cl.get("limitIp") is not None: ins["limit_ip"] = cl["limitIp"]
    for f in ("up", "down", "total"):
        if f in ccols: ins[f] = cl.get(f, 0) or 0
    if not ins: return None
    return generic_insert(c, "clients", ins)

def ensure_link(c, lcols, cid, inbound_id):
    if "client_id" not in lcols or "inbound_id" not in lcols: return
    if c.execute("SELECT 1 FROM client_inbounds WHERE client_id=? AND inbound_id=? LIMIT 1",
                 (cid, inbound_id)).fetchone():
        return
    ins = {"client_id": cid, "inbound_id": inbound_id}
    if "enable" in lcols: ins["enable"] = 1
    generic_insert(c, "client_inbounds", ins)

def detect_domain_cmd():
    dom = ""
    try:
        conn = ro_conn(); c = conn.cursor()
        r = c.execute("SELECT value FROM settings WHERE key='webDomain'").fetchone()
        if r and r[0] and r[0] != "localhost" and "." in r[0]: dom = r[0]
        conn.close()
    except Exception:
        pass
    if not dom:
        try:
            r = subprocess.run(["grep", "-rh", "server_name", NGINX_DIR],
                               capture_output=True, text=True, timeout=20)
            cands = []
            for line in r.stdout.split("\n"):
                if "server_name" not in line or line.strip().startswith("#"): continue
                for cand in line.split("server_name", 1)[1].split(";")[0].split():
                    if "." in cand and "localhost" not in cand and "_" not in cand:
                        cands.append(cand)
            cands = list(dict.fromkeys(cands))
            pref = [x for x in cands if os.path.isfile("%s/%s/fullchain.pem" % (CERT_DIR, x))]
            dom = (pref or cands or [""])[0]
        except Exception:
            pass
    if not dom:
        try:
            conn = ro_conn(); c = conn.cursor()
            for (raw,) in c.execute("SELECT stream_settings FROM inbounds WHERE enable=1").fetchall():
                try:
                    s = json.loads(raw)
                    sn = (s.get("tlsSettings") or {}).get("serverName")
                    if sn: dom = sn; break
                except Exception: continue
            conn.close()
        except Exception:
            pass
    print(dom or "ERROR:DOMAIN_NOT_FOUND")

def stream_templates(DOMAIN, t_svc, t_port):
    cert = "%s/%s/fullchain.pem" % (CERT_DIR, DOMAIN)
    key  = "%s/%s/privkey.pem"  % (CERT_DIR, DOMAIN)
    t_stream = {
      "network": "grpc", "security": "tls",
      "tlsSettings": {"serverName": DOMAIN, "minVersion": "1.2", "maxVersion": "1.3",
        "certificates": [{"certificateFile": cert, "keyFile": key, "ocspStapling": 3600,
          "oneTimeLoading": False, "usage": "encipherment", "buildChain": False}],
        "alpn": ["h2", "http/1.1"], "settings": {"fingerprint": "chrome"}},
      "grpcSettings": {"serviceName": t_svc, "authority": DOMAIN, "multiMode": False},
      "externalProxy": [{"forceTls": "same", "dest": DOMAIN, "port": t_port,
                         "remark": "", "sni": "", "alpn": []}],
    }
    h_stream = {
      "network": "hysteria",
      "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60,
        "masquerade": {"type": "", "dir": "", "url": "", "rewriteHost": False,
                       "insecure": False, "content": "", "headers": {}, "statusCode": 0}},
      "security": "tls",
      "tlsSettings": {"serverName": DOMAIN, "minVersion": "1.3", "maxVersion": "1.3",
        "certificates": [{"certificateFile": cert, "keyFile": key, "ocspStapling": 3600,
          "oneTimeLoading": False, "usage": "encipherment", "buildChain": False}],
        "alpn": ["h3"], "settings": {"fingerprint": "firefox"}},
    }
    return t_stream, h_stream

# ------------------------------------------------------------------- EXPORT
def cmd_export():
    out_file = os.environ["EXPORT_FILE"]
    conn = ro_conn(); c = conn.cursor()   # bash уже сделал .backup-снапшот и передал его как XUI_DB
    tabs = tables_of(c)
    icols = cols_of(c, "inbounds")
    inbs = c.execute("SELECT * FROM inbounds" + local_filter(c) + " ORDER BY id").fetchall()
    inbs = [dict(zip(icols, r)) for r in inbs]
    dom = ""
    try:
        r = c.execute("SELECT value FROM settings WHERE key='webDomain'").fetchone()
        if r: dom = r[0] or ""
    except Exception: pass
    # эффективный домен: webDomain мог быть битым (localhost) — тогда берём
    # фактический из tlsSettings.serverName локальных инбаундов
    if not dom or dom == "localhost" or "." not in dom:
        for ib in inbs:
            try:
                s = json.loads(ib.get("stream_settings") or "{}")
                sn = (s.get("tlsSettings") or {}).get("serverName")
                if sn: dom = sn; break
            except Exception:
                continue

    exp = {
      "format": "x-ui-inbounds-export", "version": 1,
      "script": "setup-inbounds.sh %s" % os.environ.get("SCRIPT_VERSION", "?"),
      "created_utc": datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
      "hostname": socket.gethostname(), "source_domain": dom,
      "schema": {"inbounds_cols": icols,
                 "has_clients_table": "clients" in tabs,
                 "has_client_inbounds": "client_inbounds" in tabs},
      "inbounds": inbs,
    }

    ib_by_id = {ib["id"]: ib for ib in inbs}
    if "clients" in tabs:
        ccols = cols_of(c, "clients")
        idcol = ccols[0] if ccols else "id"
        rows = [dict(zip(ccols, r)) for r in c.execute("SELECT * FROM clients").fetchall()]
        def ck(row):
            for f in ("uuid", "email", "sub_id"):
                if f in row and row[f]: return str(row[f])
            return str(row.get(idcol))
        exp["clients"] = rows
        exp["_client_keys"] = {str(r[idcol]): ck(r) for r in rows}
        if "client_inbounds" in tabs:
            lcols = cols_of(c, "client_inbounds")
            links = []
            for r in c.execute("SELECT * FROM client_inbounds").fetchall():
                d = dict(zip(lcols, r))
                iid = d.get("inbound_id")
                if iid not in ib_by_id: continue      # только локальные (экспортируемые)
                ib = ib_by_id[iid]
                item = {k: v for k, v in d.items() if k not in ("id", "client_id", "inbound_id")}
                item["client_key"] = exp["_client_keys"].get(str(d.get("client_id")), "")
                item["inbound_key"] = "%s\u0000%s" % (ib.get("remark", ""), ib.get("protocol", ""))
                links.append(item)
            exp["client_inbounds"] = links
    conn.close()
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(exp, f, ensure_ascii=False, indent=1)
    try: os.chmod(out_file, 0o600)
    except Exception: pass
    protos = {}
    for ib in inbs: protos[ib["protocol"]] = protos.get(ib["protocol"], 0) + 1
    print("EXPORT_OK|%d|%s" % (len(inbs), json.dumps(protos, ensure_ascii=False)))

# ------------------------------------------------------------- PLAN / LOCAL
def prepare_local(c, tabs, DOMAIN):
    """Общий расчёт плана local-режима (используется и в plan, и в apply)."""
    _, inbs = load_local_inbounds(c)
    reg = build_registry(inbs)
    trojans = [i for i in inbs if i["protocol"] == "trojan"]
    hysts   = [i for i in inbs if i["protocol"] in ("hysteria", "hysteria2")]
    keep_t = trojans[0] if trojans else None
    keep_h = hysts[0] if hysts else None
    extras = trojans[1:] + hysts[1:]
    t_svc = None
    if keep_t:
        try: t_svc = (json.loads(keep_t["stream_settings"]).get("grpcSettings") or {}).get("serviceName")
        except Exception: pass
    svc_kept = bool(t_svc)
    if not t_svc: t_svc = rnd(10)
    t_port = int(keep_t["port"]) if keep_t else None
    h_port = int(keep_h["port"]) if keep_h else None
    return dict(inbs=inbs, reg=reg, keep_t=keep_t, keep_h=keep_h, extras=extras,
                t_svc=t_svc, svc_kept=svc_kept, t_port=t_port, h_port=h_port,
                trojans=trojans, hysts=hysts)

def cmd_plan_local():
    DOMAIN = os.environ["DOMAIN"]
    conn = ro_conn(); c = conn.cursor(); tabs = tables_of(c)
    p = prepare_local(c, tabs, DOMAIN)
    fork = "clients" in tabs and "client_inbounds" in tabs
    print("Домен (целевой webDomain): %s" % DOMAIN)
    print("Локальных инбаундов всего: %d" % len(p["inbs"]))
    print("Уникальных клиентов (по всем локальным инбаундам): %d" % len(p["reg"]))
    if p["keep_t"]:
        print("Trojan: существующий #%s «%s» порт %s — ОБНОВИТСЯ НА МЕСТЕ (id/порт/serviceName сохранятся)"
              % (p["keep_t"]["id"], p["keep_t"]["remark"], p["keep_t"]["port"]))
    else:
        print("Trojan: будет СОЗДАН новый инбаунд (порт свободный случайный, serviceName %s%s)"
              % (p["t_svc"], "" if p["svc_kept"] else " (новый)"))
    if p["keep_h"]:
        print("Hysteria: существующая #%s «%s» порт %s — ОБНОВИТСЯ НА МЕСТЕ"
              % (p["keep_h"]["id"], p["keep_h"]["remark"], p["keep_h"]["port"]))
    else:
        print("Hysteria: будет СОЗДАНА новая (порт свободный случайный)")
    if p["extras"]:
        print("БУДУТ УДАЛЕНЫ дубликаты локальных инбаундов:")
        for ib in p["extras"]:
            print("  - #%s «%s» %s порт %s" % (ib["id"], ib["remark"], ib["protocol"], ib["port"]))
        print("  (зависимости client_inbounds/client_traffics вычищаются вместе с ними)")
    print("serviceName Trojan: %s" % (p["t_svc"] + (" (сохранён существующий)" if p["svc_kept"] else " (новый)")))
    print("Таблицы clients/client_inbounds (x-ui-pro): %s" % ("есть — связи будут синхронизированы" if fork else "нет"))
    if "hosts" in tabs:
        print("WARN|Обнаружена таблица hosts (Managed Hosts, 3.7+): externalProxy может игнорироваться —")
        print("WARN|после запуска проверьте в подписке порт Trojan (ожидается прямой порт, а не :443).")
    conn.close()

def inbound_insert_vals(c, remark, port, proto, settings, stream, tag, sniff_src=None):
    vals = {"user_id": user_id(c), "up": 0, "down": 0, "total": 0, "remark": remark,
            "enable": 1, "expiry_time": 0, "listen": "", "port": int(port),
            "protocol": proto, "settings": settings, "stream_settings": stream,
            "tag": tag, "sniffing": sniff_src if sniff_src is not None else SNIFF_DEFAULT}
    if "node_id" in cols_of(c, "inbounds"): vals["node_id"] = 0
    return vals

def cmd_apply_local():
    DOMAIN = os.environ["DOMAIN"]
    conn = sqlite3.connect(DB, timeout=30); conn.isolation_level = None; c = conn.cursor()
    icols = cols_of(c, "inbounds"); colset = set(icols)
    missing = [r for r in ("port", "protocol", "settings", "stream_settings", "tag", "enable", "remark")
               if r not in colset]
    if missing:
        raise SystemExit("ABORT: в таблице inbounds нет колонок %s — схема неизвестна, скрипт несовместим" % missing)
    before = counters(c)
    ic = c.execute("PRAGMA integrity_check").fetchone()[0]
    if ic != "ok":
        raise SystemExit("ABORT: integrity_check до начала = %r — БД уже повреждена, ничего не пишем" % ic)
    tabs = tables_of(c)
    warn = []
    grpc_lines, ports_lines = [], []
    try:
        c.execute("BEGIN IMMEDIATE")
        p = prepare_local(c, tabs, DOMAIN)
        reg = p["reg"]

        # порты: существующие сохраняются; новые — только при их отсутствии (панель остановлена, bind-тест точен)
        t_port = p["t_port"] if p["t_port"] else pick_port(None, False)[0]
        h_port = p["h_port"] if p["h_port"] else pick_port(None, True, avoid=(t_port,))[0]

        # правка 3: дубликаты удаляются вместе с зависимостями
        n_del = delete_inbounds_with_deps(c, [i["id"] for i in p["extras"]], tabs)

        generated = []
        t_clients = [adapt(v, "trojan", generated) for v in reg.values()]
        h_clients = [adapt(v, "hysteria", generated) for v in reg.values()]
        t_stream, h_stream = stream_templates(DOMAIN, p["t_svc"], t_port)

        # Trojan: update-in-place или insert
        if p["keep_t"]:
            c.execute("UPDATE inbounds SET settings=?, stream_settings=? WHERE id=?",
                      (json.dumps({"clients": t_clients}), json.dumps(t_stream), p["keep_t"]["id"]))
            t_id = p["keep_t"]["id"]
        else:
            t_id = generic_insert(c, "inbounds", inbound_insert_vals(
                c, "🤖 Trojan-gRPC %d" % t_port, t_port, "trojan",
                json.dumps({"clients": t_clients}), json.dumps(t_stream), unique_tag(c, "trojan_auto")))
        # Hysteria: update-in-place или insert
        h_proto = p["keep_h"]["protocol"] if p["keep_h"] else "hysteria"
        if p["keep_h"]:
            c.execute("UPDATE inbounds SET settings=?, stream_settings=? WHERE id=?",
                      (json.dumps({"clients": h_clients, "version": 2}), json.dumps(h_stream), p["keep_h"]["id"]))
            h_id = p["keep_h"]["id"]
        else:
            h_id = generic_insert(c, "inbounds", inbound_insert_vals(
                c, "🤖 Hysteria2 %d" % h_port, h_proto,
                json.dumps({"clients": h_clients, "version": 2}), json.dumps(h_stream), unique_tag(c, "hysteria_auto")))

        # фикс webDomain (баг localhost) — при остановленной панели
        cur = c.execute("SELECT value FROM settings WHERE key='webDomain'").fetchone()
        if cur is None:
            try: c.execute("INSERT INTO settings (key,value) VALUES ('webDomain',?)", (DOMAIN,))
            except Exception as e: warn.append("webDomain insert: %s" % e)
        elif cur[0] != DOMAIN:
            c.execute("UPDATE settings SET value=? WHERE key='webDomain'", (DOMAIN,))

        # x-ui-pro: синхронизация clients/client_inbounds
        if "clients" in tabs and "client_inbounds" in tabs:
            sync_fork_clients(c, tabs, t_id, t_clients, warn)
            sync_fork_clients(c, tabs, h_id, h_clients, warn)

        if os.environ.get("INBOUNDS_SETUP_TEST_FAIL") == "mid":   # тестовый хук (rollback-тест)
            raise RuntimeError("INBOUNDS_SETUP_TEST_FAIL=mid")

        c.execute("COMMIT")
    except SystemExit:
        try: c.execute("ROLLBACK")
        except Exception: pass
        raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        print("ROLLBACK: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)

    after = counters(c)
    ic2 = c.execute("PRAGMA integrity_check").fetchone()[0]
    conn.close()
    print("[before] %s" % json.dumps(before))
    print("[after ] %s" % json.dumps(after))
    if ic2 != "ok":
        print("ABORT: integrity_check после записи = %r — восстановите БД из бэкапа" % ic2, file=sys.stderr)
        sys.exit(1)
    if before.get("clients") not in (None,) and before.get("clients") != after.get("clients") and after.get("clients") is not None:
        print("WARN|Число клиентов в таблице clients изменилось %s -> %s — проверьте вручную"
              % (before.get("clients"), after.get("clients")))
    for w in warn: print("WARN|%s" % w)
    print("LOCAL_OK|t_port=%d|t_svc=%s|h_port=%d|clients=%d|deleted=%d|generated=%s"
          % (t_port, p["t_svc"], h_port, len(reg), n_del, ",".join(generated) or "-"))
    print("GRPC|%s|%d" % (p["t_svc"], t_port))
    print("PORTS|%d|tcp" % t_port)
    print("PORTS|%d|udp" % h_port)

# ------------------------------------------------------------ IMPORT (plan/apply)
def load_export():
    with open(os.environ["EXPORT_FILE"], encoding="utf-8") as f:
        exp = json.load(f)
    if exp.get("format") != "x-ui-inbounds-export":
        raise SystemExit("ABORT: файл не похож на экспорт inbounds (format=%r)" % exp.get("format"))
    if exp.get("version") != 1:
        raise SystemExit("ABORT: неподдерживаемая версия формата: %r" % exp.get("version"))
    return exp

def rewrite_stream(raw, src_domain, tgt_domain, old_port, new_port):
    """Домен/сертификаты/externalProxy-порт — под целевой сервер. Секреты и serviceName не трогаются."""
    try: s = json.loads(raw)
    except Exception: return raw
    txt = json.dumps(s, ensure_ascii=False)
    if src_domain and src_domain != tgt_domain:
        txt = txt.replace(src_domain, tgt_domain)
    txt = re.sub(r"/root/cert/[^/\"\\]+/", "/root/cert/%s/" % tgt_domain, txt)
    if CERT_DIR != "/root/cert":
        txt = re.sub(re.escape(CERT_DIR) + r"/[^/\"\\]+/", "%s/%s/" % (CERT_DIR, tgt_domain), txt)
    try: s = json.loads(txt)
    except Exception: return txt
    ep = s.get("externalProxy")
    if isinstance(ep, list):
        for e in ep:
            if isinstance(e, dict) and old_port and e.get("port") == int(old_port):
                e["port"] = int(new_port)
    return json.dumps(s, ensure_ascii=False)

def plan_import(c, tabs, exp, DOMAIN):
    """Возвращает список действий: (inbound_export, match_row|None, proto, udp)."""
    _, locals_ = load_local_inbounds(c)
    plan = []
    for ib in exp.get("inbounds", []):
        proto = ib.get("protocol", ""); remark = ib.get("remark", "")
        match = next((x for x in locals_ if x["protocol"] == proto and x["remark"] == remark), None)
        plan.append((ib, match, proto, is_udp(proto)))
    return plan

def cmd_plan_import():
    DOMAIN = os.environ["DOMAIN"]
    exp = load_export()
    conn = ro_conn(); c = conn.cursor(); tabs = tables_of(c)
    plan = plan_import(c, tabs, exp, DOMAIN)
    src_domain = exp.get("source_domain") or "?"
    print("Файл экспорта: %s (сервер %s, домен %s, создан %s)"
          % (os.environ["EXPORT_FILE"], exp.get("hostname", "?"), src_domain, exp.get("created_utc", "?")))
    print("Целевой домен: %s%s" % (DOMAIN, "" if src_domain == DOMAIN else "  (домен в stream_settings будет перезаписан)"))
    print("Инбаундов в экспорте: %d" % len(plan))
    occupied = {}
    for ib, match, proto, udp in plan:
        clients = settings_clients(ib)
        if match:
            print("  = UPDATE  «%s» %s (целевой #%s, порт %s сохраняется)"
                  % (ib.get("remark"), proto, match["id"], match["port"]))
        else:
            p = ib.get("port")
            free = port_free(p, udp) if p else False
            note = "порт %s свободен — сохраняется (ссылки не изменятся)" % p if free else \
                   "порт %s занят — при применении будет выбран свободный (прямые ссылки ИЗМЕНЯТСЯ)" % p
            tag = ib.get("tag") or ""
            tagw = ""
            try:
                if tag and c.execute("SELECT 1 FROM inbounds WHERE tag=? LIMIT 1", (tag,)).fetchone():
                    tagw = ", tag «%s» занят — будет уникализирован" % tag
            except Exception: pass
            print("  + INSERT  «%s» %s: %s%s" % (ib.get("remark"), proto, note, tagw))
        print("      клиентов в settings: %d" % len(clients))
    if "clients" in tabs and "client_inbounds" in tabs:
        print("Таблицы clients/client_inbounds (x-ui-pro): есть — связи будут синхронизированы best-effort")
    if "hosts" in tabs:
        print("WARN|Обнаружена таблица hosts (Managed Hosts, 3.7+): externalProxy может игнорироваться —")
        print("WARN|после запуска проверьте порт Trojan в подписке.")
    conn.close()

def cmd_apply_import():
    DOMAIN = os.environ["DOMAIN"]
    exp = load_export()
    src_domain = exp.get("source_domain") or ""
    conn = sqlite3.connect(DB, timeout=30); conn.isolation_level = None; c = conn.cursor()
    icols = cols_of(c, "inbounds"); colset = set(icols)
    missing = [r for r in ("port", "protocol", "settings", "stream_settings", "tag", "enable", "remark")
               if r not in colset]
    if missing:
        raise SystemExit("ABORT: в таблице inbounds нет колонок %s — схема неизвестна, скрипт несовместим" % missing)
    before = counters(c)
    ic = c.execute("PRAGMA integrity_check").fetchone()[0]
    if ic != "ok":
        raise SystemExit("ABORT: integrity_check до начала = %r — ничего не пишем" % ic)
    tabs = tables_of(c)
    warn = []; grpc_lines = []; ports_lines = []
    n_ins = n_upd = 0
    try:
        c.execute("BEGIN IMMEDIATE")
        plan = plan_import(c, tabs, exp, DOMAIN)
        chosen = set()
        ib_ids = {}   # inbound_key (remark\x00protocol) → целевой id
        for ib, match, proto, udp in plan:
            remark = ib.get("remark", proto)
            if match:
                # UPDATE: settings (клиенты) — из источника; stream/port/tag — целевые (сохраняют ссылки)
                c.execute("UPDATE inbounds SET settings=? WHERE id=?", (ib.get("settings") or "{}", match["id"]))
                if "sniffing" in colset and ib.get("sniffing") is not None:
                    c.execute("UPDATE inbounds SET sniffing=? WHERE id=?", (ib["sniffing"], match["id"]))
                port = int(match["port"]); n_upd += 1
                tid = match["id"]
                stream_raw = match.get("stream_settings") or "{}"
            else:
                avoid = chosen | {r[0] for r in c.execute("SELECT port FROM inbounds").fetchall()}
                port, changed = pick_port(ib.get("port"), udp, avoid=avoid)
                chosen.add(port)
                if changed:
                    warn.append("«%s»: порт источника %s занят — назначен %d (прямые ссылки изменятся)"
                                % (remark, ib.get("port"), port))
                stream = rewrite_stream(ib.get("stream_settings") or "{}", src_domain, DOMAIN,
                                        ib.get("port"), port)
                tag = ib.get("tag") or ("%s_imp" % proto)
                vals = inbound_insert_vals(c, remark, port, proto, ib.get("settings") or "{}",
                                           stream, unique_tag(c, tag), ib.get("sniffing"))
                if "listen" in colset and ib.get("listen") is not None: vals["listen"] = ib["listen"]
                if "expiry_time" in colset and ib.get("expiry_time") is not None: vals["expiry_time"] = ib["expiry_time"]
                if "enable" in colset and ib.get("enable") is not None: vals["enable"] = ib["enable"]
                tid = generic_insert(c, "inbounds", vals)
                n_ins += 1
                stream_raw = stream
            # clients/client_inbounds sync
            if "clients" in tabs and "client_inbounds" in tabs:
                sync_fork_clients(c, tabs, tid, settings_clients(ib), warn)
            ib_ids["%s\u0000%s" % (remark, proto)] = tid
            # строки для bash: UFW и nginx
            try:
                st = json.loads(stream_raw)
                if proto == "trojan" and st.get("network") == "grpc":
                    svc = (st.get("grpcSettings") or {}).get("serviceName")
                    if svc: grpc_lines.append("GRPC|%s|%d" % (svc, port))
            except Exception: pass
            ports_lines.append("PORTS|%d|%s" % (port, "udp" if udp else "tcp"))
        # восстановление полной матрицы связей client_inbounds по экспорту (форк):
        # в settings JSON — только клиенты «своего» инбаунда, экспорт несёт всю матрицу
        if "clients" in tabs and "client_inbounds" in tabs and exp.get("client_inbounds"):
            ccols2 = cols_of(c, "clients")
            lcols2 = cols_of(c, "client_inbounds")
            key2cl = {}
            for row in exp.get("clients") or []:
                clx = {"id": row.get("uuid"), "uuid": row.get("uuid"), "email": row.get("email"),
                       "subId": row.get("sub_id"), "expiryTime": row.get("expiry_time"),
                       "limitIp": row.get("limit_ip"), "enable": row.get("enable", 1)}
                for f in ("uuid", "email", "sub_id"):
                    if row.get(f): key2cl.setdefault(str(row[f]), clx)
            for link in exp["client_inbounds"]:
                try:
                    tid = ib_ids.get(link.get("inbound_key"))
                    clx = key2cl.get(str(link.get("client_key")))
                    if tid is None or clx is None:
                        continue
                    cid = ensure_client(c, ccols2, clx)
                    if cid is not None:
                        ensure_link(c, lcols2, cid, tid)
                except Exception as e:
                    warn.append("восстановление связи %s→%s: %s: %s" % (link.get("client_key"),
                                (link.get("inbound_key") or "").split("\u0000")[0], type(e).__name__, e))
        # webDomain: если у цели пустой/localhost — фиксируем определённый
        cur = c.execute("SELECT value FROM settings WHERE key='webDomain'").fetchone()
        if cur is not None and (not cur[0] or cur[0] == "localhost"):
            c.execute("UPDATE settings SET value=? WHERE key='webDomain'", (DOMAIN,))
        if os.environ.get("INBOUNDS_SETUP_TEST_FAIL") == "mid":   # тестовый хук (rollback-тест)
            raise RuntimeError("INBOUNDS_SETUP_TEST_FAIL=mid")
        c.execute("COMMIT")
    except SystemExit:
        try: c.execute("ROLLBACK")
        except Exception: pass
        raise
    except Exception as e:
        try: c.execute("ROLLBACK")
        except Exception: pass
        print("ROLLBACK: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)
    after = counters(c)
    ic2 = c.execute("PRAGMA integrity_check").fetchone()[0]
    conn.close()
    print("[before] %s" % json.dumps(before))
    print("[after ] %s" % json.dumps(after))
    if ic2 != "ok":
        print("ABORT: integrity_check после записи = %r — восстановите БД из бэкапа" % ic2, file=sys.stderr)
        sys.exit(1)
    for w in warn: print("WARN|%s" % w)
    print("IMPORT_OK|inserted=%d|updated=%d" % (n_ins, n_upd))
    for l in grpc_lines: print(l)
    for l in ports_lines: print(l)

CMDS = {"export": cmd_export, "detect-domain": detect_domain_cmd,
        "plan-local": cmd_plan_local, "apply-local": cmd_apply_local,
        "plan-import": cmd_plan_import, "apply-import": cmd_apply_import}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd not in CMDS:
        print("usage: lib.py {%s}" % "|".join(CMDS), file=sys.stderr); sys.exit(2)
    CMDS[cmd]()
PYLIB

pyrun() {  # pyrun <команда> — с единым набором env
  SCRIPT_VERSION="$SCRIPT_VERSION" XUI_DB="$DB" XUI_CERT_DIR="$CERT_DIR" XUI_NGINX_DIR="$NGINX_DIR" \
  DOMAIN="${DOMAIN:-}" EXPORT_FILE="${FILE:-}" python3 "$TMPD/lib.py" "$1"
}

# ============================================================== РЕЖИМ EXPORT
if [ "$MODE" = "export" ]; then
  TS=$(date -u +%F_%H%M%S)
  HOST=$(hostname -s 2>/dev/null || echo server)
  OUT="${FILE:-/root/inbounds-export-${HOST}-${TS}.json}"
  echo -e "${CYAN}[1/3] Консистентный снапшот БД (sqlite3 .backup, панель НЕ останавливается)...${NC}"
  sqlite3 "file:${DB}?mode=ro" ".backup '${TMPD}/snap.db'" || die "не удалось создать снапшот БД"
  CHK=$(sqlite3 "file:${TMPD}/snap.db?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>/dev/null | head -1)
  [ "$CHK" = "ok" ] || die "integrity_check снапшота = ${CHK:-?} — экспорт из повреждённой БД не делаю"
  echo -e "${GREEN}✅ Снапшот: integrity=ok${NC}"
  echo -e "${CYAN}[2/3] Экспорт локальных инбаундов (node_id=0) и клиентов...${NC}"
  RES=$(XUI_DB="${TMPD}/snap.db" EXPORT_FILE="$OUT" SCRIPT_VERSION="$SCRIPT_VERSION" \
        python3 "$TMPD/lib.py" export) || die "экспорт не удался"
  [ -f "$OUT" ] || die "файл экспорта не создан"
  chmod 600 "$OUT" 2>/dev/null
  N=$(echo "$RES" | sed -n 's/^EXPORT_OK|\([0-9]*\)|.*/\1/p')
  PROTOS=$(echo "$RES" | sed -n 's/^EXPORT_OK|[0-9]*|\(.*\)$/\1/p')
  echo -e "${CYAN}[3/3] Готово${NC}"
  echo -e "${GREEN}=====================================================${NC}"
  echo -e "${GREEN}  ✅ Экспорт: $OUT${NC}"
  echo -e "${GREEN}=====================================================${NC}"
  echo -e "Инбаундов (только локальные): ${N:-?} · протоколы: ${PROTOS:-?}"
  echo -e "Размер: $(wc -c < "$OUT") байт · права: 600"
  echo -e "${YELLOW}⚠️  Файл содержит данные клиентов (uuid/пароли/ключи): не передавайте его по${NC}"
  echo -e "${YELLOW}   незащищённым каналам и не кладите в публичные репозитории. После переноса — удалите.${NC}"
  echo -e "Перенос на целевой сервер: скопируйте файл (scp/sftp) и выполните там:"
  echo -e "  bash setup-inbounds.sh import <файл> --dry-run   # сначала план"
  echo -e "  bash setup-inbounds.sh import <файл>             # затем применение"
  exit 0
fi

# ==================================================== РЕЖИМЫ LOCAL / IMPORT
echo -e "${CYAN}[1/6] Консистентный бэкап БД (sqlite3 .backup) + верификация...${NC}"
BK="${BACKUP_ROOT}/$(date -u +%F_%H%M%S)"
mkdir -p "$BK" || die "не могу создать каталог бэкапа $BK"
sqlite3 "file:${DB}?mode=ro" ".backup '${BK}/x-ui.db'" || die "не удалось создать бэкап БД"
CHK=$(sqlite3 "file:${BK}/x-ui.db?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>/dev/null | head -1)
CNT=$(sqlite3 "file:${BK}/x-ui.db?mode=ro&immutable=1" "SELECT 'inbounds='||COUNT(*) FROM inbounds;" 2>/dev/null)
CLI=$(sqlite3 "file:${BK}/x-ui.db?mode=ro&immutable=1" "SELECT 'clients='||COUNT(*) FROM clients;" 2>/dev/null)
echo -e "${GREEN}✅ Бэкап: ${BK}/x-ui.db | integrity=${CHK:-?} | ${CNT:-?} | ${CLI:-?}${NC}"
[ "$CHK" = "ok" ] || die "Бэкап не прошёл integrity_check (${CHK:-?}). Без годной точки отката писать нельзя."

echo -e "${CYAN}[2/6] Определение домена (webDomain панели → nginx → tlsSettings)...${NC}"
DOMAIN=$(pyrun detect-domain) || die "ошибка определения домена"
[ -n "$DOMAIN" ] && [ "$DOMAIN" != "ERROR:DOMAIN_NOT_FOUND" ] || die "Домен не определён — укажите webDomain в панели 3x-ui"
if [ ! -f "${CERT_DIR}/${DOMAIN}/fullchain.pem" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}⚠️  Нет сертификата ${CERT_DIR}/${DOMAIN}/fullchain.pem — для --dry-run продолжаю,${NC}"
    echo -e "${YELLOW}   но для реального применения сертификат обязателен${NC}"
  else
    die "Нет сертификата ${CERT_DIR}/${DOMAIN}/fullchain.pem — домен определён неверно или сертификат не выпущен"
  fi
fi
echo -e "${GREEN}✅ Домен: $DOMAIN (сертификат на месте)${NC}"

echo -e "${CYAN}[3/6] План изменений...${NC}"
if [ "$MODE" = "import" ]; then pyrun plan-import || die "планирование не удалось"; else pyrun plan-local || die "планирование не удалось"; fi
if [ "$DRY_RUN" -eq 1 ]; then
  echo -e "${YELLOW}--dry-run: изменения НЕ вносились.${NC}"; exit 0
fi
if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Продолжить? (yes/NO): "; read -r ANS
  [ "$ANS" = "yes" ] || { echo "Отменено пользователем"; exit 0; }
fi

echo -e "${CYAN}[4/6] Остановка панели, запись в БД (одна транзакция)...${NC}"
systemctl stop "$SVC" || die "не удалось остановить ${SVC}"
if [ "$MODE" = "import" ]; then APPLY_OUT=$(pyrun apply-import 2>&1); RC=$?; else APPLY_OUT=$(pyrun apply-local 2>&1); RC=$?; fi
if [ $RC -ne 0 ]; then
  echo "$APPLY_OUT"
  echo -e "${YELLOW}↩️  Транзакция откачена (ROLLBACK), БД не изменена. Запускаю панель обратно...${NC}"
  systemctl start "$SVC"
  die "запись в БД не удалась — ничего не применено; бэкап: ${BK}/x-ui.db"
fi
echo "$APPLY_OUT" | grep -v '^GRPC|\|^PORTS|\|^LOCAL_OK|\|^IMPORT_OK|'
GRPC_LINES=$(echo "$APPLY_OUT" | grep '^GRPC|' || true)
PORT_LINES=$(echo "$APPLY_OUT" | grep '^PORTS|' || true)
echo -e "${GREEN}✅ БД записана (integrity ok, счётчики выше)${NC}"

echo -e "${CYAN}[5/6] Запуск панели + брандмауэр...${NC}"
systemctl start "$SVC" || die "панель не запустилась! Бэкап: ${BK}/x-ui.db"
sleep 3
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
  CUR_SPECS=""
  while IFS='|' read -r _ pp proto; do
    [ -n "$pp" ] || continue
    CUR_SPECS="${CUR_SPECS} ${pp}/${proto}"
    case "$proto" in
      tcp) CMT="Trojan-gRPC Auto";;
      udp) CMT="Hysteria2 Auto";;
    esac
    ufw allow "${pp}/${proto}" comment "$CMT" >/dev/null 2>&1
  done <<< "$PORT_LINES"
  # чистка устаревших правил с нашими комментариями (порты прошлых запусков)
  OLD=$(ufw status numbered 2>/dev/null | grep -E '# (Trojan-gRPC Auto|Hysteria2 Auto|Inbounds-Setup)' | while read -r line; do
          num=$(echo "$line" | sed -n 's/^\[ *\([0-9]*\)\].*/\1/p')
          spec=$(echo "$line" | awk '{print $2}')
          case " $CUR_SPECS " in *" $spec "*) ;; *) [ -n "$num" ] && echo "$num";; esac
        done | sort -rn)
  for n in $OLD; do ufw --force delete "$n" >/dev/null 2>&1; done
  echo -e "${GREEN}✅ UFW: порты открыты, устаревшие правила подчищены${NC}"
else
  echo -e "${YELLOW}⚠️  UFW не найден или неактивен — правила не добавлялись (проверьте другой файрвол)${NC}"
fi

echo -e "${CYAN}[6/6] Патч nginx (маскировка Trojan-gRPC через 443)...${NC}"
if [ -n "$GRPC_LINES" ] && command -v nginx >/dev/null 2>&1; then
  mkdir -p "$(dirname "$NGINX_CONF")"
  [ -f "$NGINX_CONF" ] || echo "# Nginx snippets for x-ui" > "$NGINX_CONF"
  NGINX_BAK="${NGINX_CONF}.bak.$(date +%F-%H%M%S)"   # имя фиксируется ОДИН раз (правка 3d)
  cp "$NGINX_CONF" "$NGINX_BAK"
  ADDED=0
  while IFS='|' read -r _ svc port; do
    [ -n "$svc" ] || continue
    if ! grep -q "location /${svc}" "$NGINX_CONF"; then
      cat >> "$NGINX_CONF" <<EOF

# Auto-generated Trojan gRPC fix (grpcs) — setup-inbounds.sh v${SCRIPT_VERSION}
location /${svc} {
    grpc_pass grpcs://127.0.0.1:${port};
    grpc_ssl_name ${DOMAIN};
    grpc_ssl_protocols TLSv1.2 TLSv1.3;
    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header Connection "";
}
EOF
      ADDED=$((ADDED+1))
    fi
  done <<< "$GRPC_LINES"
  if [ "$ADDED" -eq 0 ]; then
    echo -e "${GREEN}✅ nginx: все location уже присутствуют — конфиг не менялся${NC}"
    rm -f "$NGINX_BAK"
  elif nginx -t >/dev/null 2>&1; then
    systemctl reload nginx && echo -e "${GREEN}✅ nginx: добавлено location: $ADDED, reload ok${NC}"
  else
    echo -e "${RED}❌ nginx -t не прошёл — АВТООТКАТ из ${NGINX_BAK}${NC}"
    cp "$NGINX_BAK" "$NGINX_CONF"; systemctl reload nginx 2>/dev/null
    echo -e "${YELLOW}⚠️  Маскировка Trojan через 443 НЕ настроена (прямой порт работает)${NC}"
  fi
else
  [ -z "$GRPC_LINES" ] && echo -e "nginx: gRPC-инбаундов нет — патч не требуется" \
    || echo -e "${YELLOW}⚠️  nginx не найден — маскировка gRPC не настраивалась${NC}"
fi

# ------------------------------------------------------------------ верификация
echo -e "${CYAN}Верификация после запуска...${NC}"
if systemctl is-active --quiet "$SVC"; then echo -e "${GREEN}✅ Панель ${SVC}: active${NC}"; else echo -e "${RED}❌ Панель ${SVC} не активна! Бэкап: ${BK}/x-ui.db${NC}"; fi
IC=$(sqlite3 "file:${DB}?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>/dev/null | head -1)
echo -e "БД: integrity=${IC:-?}"
if [ -f "$CONFIG_JSON" ]; then
  MISS=0
  while IFS='|' read -r _ pp proto; do
    [ -n "$pp" ] || continue
    grep -q ":${pp}\b" "$CONFIG_JSON" 2>/dev/null || { echo -e "${YELLOW}⚠️  порт $pp/$proto не найден в config.json (xray мог ещё не перегенерировать конфиг — перепроверьте через минуту)${NC}"; MISS=1; }
  done <<< "$PORT_LINES"
  [ "$MISS" -eq 0 ] && echo -e "${GREEN}✅ config.json: все порты инбаундов на месте${NC}"
fi
echo "$APPLY_OUT" | grep '^WARN|' | sed 's/^WARN|/⚠️  /' || true

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  ✅ Готово (режим: ${MODE})${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo -e "Бэкап БД:  ${BK}/x-ui.db (integrity=ok на момент создания)"
echo -e "Результат: $(echo "$APPLY_OUT" | grep '^LOCAL_OK\|^IMPORT_OK' | head -1)"
echo -e "Пароли и ключи НЕ выводятся — они в панели. Проверьте подписку и подключения клиентов."
