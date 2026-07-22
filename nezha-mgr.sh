#!/bin/bash

# ==============================================================
# Nezha Dashboard Manager - Professional Script (Binary Edition)
# 哪吒监控面板专业管理脚本 (Security + Stability + Speed)
# 专为原生安装打造，三S优化: 安全加固 / 高稳定 / 极速响应
# 版本号见下方 SCRIPT_VERSION（唯一来源）
# ==============================================================

# 脚本版本（唯一来源，其余位置一律引用此变量，勿再硬编码）
SCRIPT_VERSION="1.0.2"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 基础路径定义
INSTALL_DIR="/opt/nezha"
DASHBOARD_PATH="${INSTALL_DIR}/dashboard"
DATA_DIR="${INSTALL_DIR}/data"
SYSTEMD_FILE="/etc/systemd/system/nezha-dashboard.service"

# 检查 Root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 请使用 root 权限运行此脚本 (sudo -i)${PLAIN}"
        exit 1
    fi
}

# 检查系统架构与环境
check_sys() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS=$ID
    else
        echo -e "${RED}无法检测操作系统，建议使用 Debian/Ubuntu${PLAIN}"
        exit 1
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        s390x) ARCH="s390x" ;;
        *) echo -e "${RED}不支持的架构: ${ARCH}${PLAIN}"; exit 1 ;;
    esac
}

# ==============================================================
# 模块 1: 系统基础依赖
# ==============================================================
install_base() {
    echo -e "${BLUE}>>> 正在安装基础依赖...${PLAIN}"
    if [[ "${OS}" == "ubuntu" ]] || [[ "${OS}" == "debian" ]]; then
        apt-get update -y
        apt-get install -y wget curl socat cron tar unzip lsb-release gnupg2 ca-certificates openssl htop nginx python3 python3-bcrypt sqlite3
    elif [[ "${OS}" == "centos" ]]; then
        yum install -y wget curl socat cronie tar unzip openssl htop nginx python3 python3-bcrypt sqlite
    else
        echo -e "${RED}不支持的系统: ${OS}，请使用 Debian/Ubuntu/CentOS${PLAIN}"
        return 1
    fi
}

# ==============================================================
# 模块 2: Nginx 专属优化
# ==============================================================
optimize_system() {
    echo -e "${BLUE}>>> 执行 Nginx 专属优化...${PLAIN}"
    
    # 创建磁盘缓存目录
    mkdir -p /var/cache/nginx/nezha
    chown -R www-data:www-data /var/cache/nginx/ 2>/dev/null
    chmod 755 /var/cache/nginx/
    
    # 创建内存缓存目录 (可选，高性能模式)
    mkdir -p /dev/shm/nginx/nezha
    chown -R www-data:www-data /dev/shm/nginx/ 2>/dev/null
    chmod 755 /dev/shm/nginx/
    
    # 注册 tmpfiles.d，确保重启后 /dev/shm/nginx/nezha 自动创建（早于 nginx -t）
    cat > /etc/tmpfiles.d/nginx-shm.conf << EOF
d /dev/shm/nginx       0755 www-data www-data -
d /dev/shm/nginx/nezha 0755 www-data www-data -
EOF
    systemd-tmpfiles --create /etc/tmpfiles.d/nginx-shm.conf 2>/dev/null

    mkdir -p /etc/systemd/system/nginx.service.d
    cat > /etc/systemd/system/nginx.service.d/override.conf << EOF
[Service]
LimitNOFILE=102400
LimitNPROC=102400
EOF
    systemctl daemon-reload
    echo -e "${GREEN}Nginx Service Limit 优化完成${PLAIN}"
}

# ==============================================================
# 模块 3: 哪吒面板安装/更新 (二进制模式)
# ==============================================================
install_nezha() {
    echo -e "${BLUE}>>> 开始安装哪吒面板 (原生二进制)...${PLAIN}"
    # 首次安装判定：数据库此前不存在才视为全新安装（用于设置强密码，避免重装覆盖已改密码）
    local FRESH_INSTALL=0
    [ ! -f "${DATA_DIR}/sqlite.db" ] && FRESH_INSTALL=1
    mkdir -p ${INSTALL_DIR}
    mkdir -p ${DATA_DIR}

    echo -e "${CYAN}正在获取最新版本信息...${PLAIN}"
    local RELEASE_JSON
    RELEASE_JSON=$(curl -s https://api.github.com/repos/nezhahq/nezha/releases/latest)
    VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    LATEST_URL=$(echo "$RELEASE_JSON" | grep "browser_download_url" | grep "dashboard-linux-${ARCH}.zip" | cut -d '"' -f 4)

    if [ -z "$LATEST_URL" ]; then
        echo -e "${RED}获取下载链接失败，尝试使用备用链接${PLAIN}"
        if [ -n "$VERSION" ]; then
             LATEST_URL="https://github.com/nezhahq/nezha/releases/download/${VERSION}/dashboard-linux-${ARCH}.zip"
        else
             echo -e "${RED}无法获取版本信息${PLAIN}"
             return 1
        fi
    fi

    echo -e "${CYAN}正在下载: ${LATEST_URL}${PLAIN}"
    curl -L -o ${INSTALL_DIR}/dashboard.zip ${LATEST_URL} || { echo -e "${RED}下载失败，请检查网络连接${PLAIN}"; return 1; }

    echo -e "${CYAN}解压并安装...${PLAIN}"
    unzip -o ${INSTALL_DIR}/dashboard.zip -d ${INSTALL_DIR} || { echo -e "${RED}解压失败，文件可能已损坏${PLAIN}"; rm -f ${INSTALL_DIR}/dashboard.zip; return 1; }
    mv ${INSTALL_DIR}/dashboard-linux-${ARCH} ${INSTALL_DIR}/dashboard || { echo -e "${RED}二进制文件重命名失败，请检查解压内容${PLAIN}"; ls ${INSTALL_DIR}/; return 1; }
    chmod +x ${DASHBOARD_PATH}
    rm -f ${INSTALL_DIR}/dashboard.zip

    # 记录已安装版本（供新版本检测对比）
    if [ -n "$VERSION" ]; then
        echo "$VERSION" > "${INSTALL_DIR}/version"
        rm -f "${INSTALL_DIR}/upgrade_notified"
    fi

    echo -e "${CYAN}配置 Systemd 服务...${PLAIN}"
    cat > ${SYSTEMD_FILE} << EOF
[Unit]
Description=Nezha Dashboard
After=syslog.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${DASHBOARD_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nezha-dashboard
    systemctl restart nezha-dashboard
    echo -e "${GREEN}面板服务已启动${PLAIN}"

    # 数据库切 WAL 日志模式（读写不互相阻塞，避免库变大后加服务器/操作卡顿）
    ensure_wal
    # 等待面板就绪：生成健康脚本只读 PAT + 通过 API 写入默认 TCPing 监控
    ensure_health_pat
    add_default_monitors

    # 全新安装：把哪吒自动生成的默认 admin 密码替换为强随机密码并打印；登录有效期设为 30 天
    if [ "$FRESH_INSTALL" = "1" ]; then
        set_admin_password
        set_jwt_timeout
    fi
}

# ==============================================================
# 全新安装时为默认 admin 账号设置强随机密码
# ==============================================================
set_admin_password() {
    local DB="${DATA_DIR}/sqlite.db"

    # 确保 bcrypt 可用（哪吒密码为 bcrypt 哈希）
    if ! python3 -c 'import bcrypt' 2>/dev/null; then
        echo -e "${CYAN}安装 bcrypt 依赖 (python3-bcrypt)...${PLAIN}"
        apt-get install -y python3-bcrypt >/dev/null 2>&1
    fi
    if ! python3 -c 'import bcrypt' 2>/dev/null; then
        echo -e "${YELLOW}⚠ 无法安装 python3-bcrypt，已跳过强密码设置，请尽快手动修改默认密码${PLAIN}"
        return
    fi

    # 等待默认 admin 账号被 dashboard 首启创建
    local i=0
    local CHECK="import sqlite3,sys; c=sqlite3.connect(sys.argv[1],timeout=5); sys.exit(0 if c.execute(\"SELECT 1 FROM users WHERE username='admin'\").fetchone() else 1)"
    while [ $i -lt 15 ] && ! python3 -c "$CHECK" "$DB" 2>/dev/null; do
        sleep 2; i=$((i+1))
    done
    if ! python3 -c "$CHECK" "$DB" 2>/dev/null; then
        echo -e "${YELLOW}⚠ 未检测到默认 admin 账号，已跳过强密码设置${PLAIN}"
        return
    fi

    # 生成 20 位强随机密码（大小写+数字），写入 bcrypt 哈希
    local NEWPASS
    NEWPASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    if ! python3 - "$DB" "$NEWPASS" <<'PY'
import sqlite3, sys, bcrypt
db, pw = sys.argv[1], sys.argv[2]
h = bcrypt.hashpw(pw.encode(), bcrypt.gensalt(rounds=10)).decode()
c = sqlite3.connect(db, timeout=15)
c.execute("UPDATE users SET password=? WHERE username='admin'", (h,))
c.commit()
PY
    then
        echo -e "${YELLOW}⚠ 写入强密码失败，请手动修改默认密码${PLAIN}"
        return
    fi

    # 存入全局变量，安装完成后由 print_install_summary 在汇总框里统一打印
    NEZHA_ADMIN_PASS="$NEWPASS"
    echo -e "${GREEN}✅ 已为 admin 设置强密码（安装完成后在汇总中显示）${PLAIN}"
}

# ==============================================================
# 安装完成后的统一汇总框：访问地址 + Agent 对接 + 管理员账号/密码
# （强密码仅全新安装时由 set_admin_password 生成）
# ==============================================================
print_install_summary() {
    echo -e "${GREEN}=================================================${PLAIN}"
    echo -e "${GREEN}  访问地址      : ${PLAIN}https://${DOMAIN:-你的域名}"
    echo -e "${GREEN}  Agent 对接地址: ${PLAIN}${DOMAIN:-localhost}:443 (TLS 已开启)"
    if [ -n "$NEZHA_ADMIN_PASS" ]; then
        echo -e "${GREEN}  管理员账号    : ${PLAIN}admin"
        echo -e "${GREEN}  管理员密码    : ${PLAIN}${NEZHA_ADMIN_PASS}"
        echo -e "${GREEN}  (请妥善保存，登录后可在「个人设置」中修改)${PLAIN}"
        # 打印后清空，避免后续重装（不生成新密码）时重复打印旧值
        NEZHA_ADMIN_PASS=""
    else
        echo -e "${GREEN}  管理员        : ${PLAIN}第一个登录的用户将自动成为超级管理员"
    fi
    echo -e "${GREEN}=================================================${PLAIN}"
}

# ==============================================================
# 设置登录态有效期 jwt_timeout（单位：小时）。config.yaml 由 dashboard 首启生成，
# 默认值 1（约1小时就退登），这里改成 720（30天）省去频繁重登。
# ==============================================================
set_jwt_timeout() {
    local CFG="${DATA_DIR}/config.yaml" i=0
    while [ ! -f "$CFG" ] && [ $i -lt 15 ]; do sleep 2; i=$((i+1)); done
    [ ! -f "$CFG" ] && return
    if grep -q '^jwt_timeout:' "$CFG"; then
        sed -i 's/^jwt_timeout:.*/jwt_timeout: 720/' "$CFG"
    else
        echo 'jwt_timeout: 720' >> "$CFG"
    fi
    systemctl restart nezha-dashboard
    echo -e "${GREEN}✅ 登录有效期已设为 30 天 (jwt_timeout=720)${PLAIN}"
}

# ==============================================================
# 默认 TCPing 监控写入
# ==============================================================
add_default_monitors() {
    local DB="${DATA_DIR}/sqlite.db"
    local PORT
    PORT=$(grep -E '^[[:space:]]*listen_?port:' "${DATA_DIR}/config.yaml" 2>/dev/null | head -1 | grep -o '[0-9]\+')
    PORT=${PORT:-8008}

    echo -e "${CYAN}等待面板就绪...${PLAIN}"
    local i=0 code
    while [ $i -lt 20 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && break
        sleep 2; i=$((i+1))
    done

    echo -e "${CYAN}通过 API 检查并写入默认 TCPing 监控...${PLAIN}"
    # 用一个临时写权限 PAT 创建监控，用完即删；常驻只读 PAT 见 ensure_health_pat
    local RESULT
    RESULT=$(python3 - "$DB" "$PORT" <<'PY'
import sqlite3, sys, time, json, hashlib, secrets, urllib.request, urllib.error
db, port = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db, timeout=15)
# 等待 api_tokens / users 表创建完成（dashboard 首启后才建表）
for _ in range(15):
    try:
        c.execute("SELECT 1 FROM api_tokens LIMIT 1")
        c.execute("SELECT 1 FROM users LIMIT 1")
        break
    except sqlite3.OperationalError:
        time.sleep(2)
else:
    print("NOTREADY"); sys.exit(0)
row = c.execute("SELECT id FROM users ORDER BY id LIMIT 1").fetchone()
if not row:
    print("NOUSER"); sys.exit(0)
uid = row[0]
secret = secrets.token_hex(32); token = "nzp_" + secret
th = hashlib.sha256(token.encode()).hexdigest()
c.execute("DELETE FROM api_tokens WHERE name=?", ("__mgr_seed__",))
c.execute("INSERT INTO api_tokens (user_id,name,token_hash,scopes_csv,servers_csv,created_at,updated_at) "
          "VALUES (?,?,?,?,?,datetime('now'),datetime('now'))",
          (uid, "__mgr_seed__", th, "nezha:service:read,nezha:service:write", ""))
c.commit()
base = "http://127.0.0.1:%s/api/v1" % port
hdr = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, headers=hdr, method=method)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())
try:
    cur = api("GET", "/service")
    svcs = (cur.get("data") or {}).get("services") or {}
    if svcs:
        print("EXISTS:%d" % len(svcs)); sys.exit(0)
    rows = [
        ('东莞电信', '59.36.134.127:22'), ('东莞联通', '58.254.246.26:8443'),
        ('上海电信', '218.81.59.121:8443'), ('上海联通', '43.254.104.112:80'),
        ('Google', '8.8.8.8:443'), ('Cloudflare', '1.1.1.1:443'),
        ('DC1', '149.154.175.50:443'), ('DC2', '149.154.167.50:443'),
        ('DC5', '91.108.56.100:443'),
    ]
    n = 0
    for name, target in rows:
        api("POST", "/service", {
            "name": name, "type": 3, "target": target, "duration": 30,
            "cover": 0, "notify": False, "notification_group_id": 0,
            "fail_trigger_tasks": [], "recover_trigger_tasks": [],
            "skip_servers": {}, "enable_trigger_task": False, "hide_for_guest": False,
        })
        n += 1
    print("INSERTED:%d" % n)
except SystemExit:
    raise
except Exception as e:
    print("ERROR:%s" % e)
finally:
    c.execute("DELETE FROM api_tokens WHERE name=?", ("__mgr_seed__",)); c.commit()
PY
)
    case "$RESULT" in
        NOTREADY)   echo -e "${YELLOW}面板表未就绪，跳过默认监控写入${PLAIN}"; return ;;
        NOUSER)     echo -e "${YELLOW}尚无用户，跳过默认监控写入${PLAIN}"; return ;;
        EXISTS:*)   echo -e "${YELLOW}服务监控已存在 (${RESULT#EXISTS:} 条)，跳过默认写入${PLAIN}"; return ;;
        INSERTED:*) echo -e "${GREEN}已通过 API 写入 ${RESULT#INSERTED:} 条 TCPing 监控（无需重启面板）${PLAIN}" ;;
        ERROR:*)    echo -e "${YELLOW}写入默认监控失败：${RESULT#ERROR:}${PLAIN}"; return ;;
        *)          echo -e "${YELLOW}写入默认监控异常：${RESULT}${PLAIN}"; return ;;
    esac
}

# ==============================================================
# 数据库切 WAL 日志模式：读写不互相阻塞，库变大后仍不会"加服务器/操作卡住"。
# delete 模式下读写互锁，service_histories 累积到几百 MB 时面板会卡。WAL 一劳永逸。
# 用"停面板→设WAL→启"最可靠(无其它连接占库)；幂等，已是 wal 则跳过。Nezha 重启不会改回。
# ==============================================================
ensure_wal() {
    local DB="${DATA_DIR}/sqlite.db"
    local RO="file:${DB}?mode=ro"
    # 等 DB + users 表就绪(确保 dashboard 已初始化)
    local i=0
    while [ $i -lt 15 ]; do
        [ -f "$DB" ] && python3 -c "import sqlite3,sys;sqlite3.connect(sys.argv[1],timeout=5).execute('SELECT 1 FROM users LIMIT 1')" "$DB" 2>/dev/null && break
        sleep 2; i=$((i+1))
    done
    if [ ! -f "$DB" ]; then
        echo -e "${YELLOW}数据库未就绪，跳过 WAL 设置${PLAIN}"; return
    fi
    local CUR
    CUR=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1],uri=True,timeout=10).execute('PRAGMA journal_mode').fetchone()[0])" "$RO" 2>/dev/null)
    if [ "$CUR" = "wal" ]; then
        echo -e "${GREEN}数据库已是 WAL 模式，跳过${PLAIN}"; return
    fi
    echo -e "${CYAN}切换数据库到 WAL 模式...${PLAIN}"
    systemctl stop nezha-dashboard 2>/dev/null
    python3 -c "import sqlite3,sys;sqlite3.connect(sys.argv[1],timeout=20).execute('PRAGMA journal_mode=WAL')" "$DB" 2>/dev/null
    systemctl start nezha-dashboard
    sleep 3
    local NEW
    NEW=$(python3 -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1],uri=True,timeout=10).execute('PRAGMA journal_mode').fetchone()[0])" "$RO" 2>/dev/null)
    if [ "$NEW" = "wal" ]; then
        echo -e "${GREEN}✅ 数据库已切 WAL（读写不阻塞）${PLAIN}"
    else
        echo -e "${YELLOW}⚠ WAL 设置未生效（当前:${NEW}），可稍后在库空闲时重试${PLAIN}"
    fi
}

# ==============================================================
# 【API / PAT / MCP 安全策略 —— 务必遵守】
#   1. 常驻 PAT 一律只读（健康脚本用 nezha:inventory:read）。
#   2. 需要写时用「临时写 PAT，即用即删」(见 add_default_monitors)，scope 精确到
#      server:write / service:write，绝不带 delete。
#   3. 【铁律】nezha:server:exec 和 fs.read/fs.write/fs.delete（命令执行/文件读写删）
#      = 等于全军 RCE，任何 token、任何情况都【绝不授予】。
#   4. MCP（/mcp，enable_mcp）本项目【不使用】，保持默认关闭。它专为 LLM agent 暴露
#      exec+文件读写，叠加 LLM 不确定性与 prompt injection 风险；本项目走确定性 REST 即可。
#      若他人误开：config.yaml 设 enable_mcp: false 即一键断。
# ==============================================================
# 为健康脚本生成只读 PAT（scope: nezha:inventory:read），明文存 /opt/nezha/.nezha_pat (600)
# 直接插 api_tokens 表，与 OAuth2-only 登录方式零冲突；token_hash = sha256("nzp_"+secret)
# ==============================================================
ensure_health_pat() {
    local DB="${DATA_DIR}/sqlite.db"
    local PAT_FILE="${INSTALL_DIR}/.nezha_pat"
    if [ -s "$PAT_FILE" ]; then
        echo -e "${GREEN}健康脚本只读 PAT 已存在，跳过生成${PLAIN}"
        return 0
    fi
    local TOKEN
    TOKEN=$(python3 - "$DB" <<'PY'
import sqlite3, sys, time, hashlib, secrets
db = sys.argv[1]
c = sqlite3.connect(db, timeout=15)
for _ in range(15):
    try:
        c.execute("SELECT 1 FROM api_tokens LIMIT 1")
        c.execute("SELECT 1 FROM users LIMIT 1")
        break
    except sqlite3.OperationalError:
        time.sleep(2)
else:
    sys.exit(0)
row = c.execute("SELECT id FROM users ORDER BY id LIMIT 1").fetchone()
if not row:
    sys.exit(0)
uid = row[0]
secret = secrets.token_hex(32); token = "nzp_" + secret
th = hashlib.sha256(token.encode()).hexdigest()
c.execute("DELETE FROM api_tokens WHERE name=?", ("nezha-mgr-health",))
c.execute("INSERT INTO api_tokens (user_id,name,token_hash,scopes_csv,servers_csv,created_at,updated_at) "
          "VALUES (?,?,?,?,?,datetime('now'),datetime('now'))",
          (uid, "nezha-mgr-health", th, "nezha:inventory:read", ""))
c.commit()
print(token)
PY
)
    if [ -n "$TOKEN" ]; then
        echo "$TOKEN" > "$PAT_FILE"
        chmod 600 "$PAT_FILE"
        echo -e "${GREEN}✅ 已生成健康脚本只读 PAT${PLAIN}"
    else
        echo -e "${YELLOW}⚠ 只读 PAT 生成失败，健康脚本将无法取数，请确认面板已就绪后重试${PLAIN}"
    fi
}

# ==============================================================
# 模块 4: Nginx 配置 (三S优化版 - Security/Stability/Speed)
# ==============================================================
configure_nginx() {
    # 确保调用优化模块，适配 worker_rlimit_nofile
    optimize_system

    echo -e "${BLUE}>>> 配置 Nginx (三S优化 v${SCRIPT_VERSION}: 安全/稳定/速度)...${PLAIN}"
    
    echo -e "${CYAN}请输入您的域名 (例如 nezha.example.com):${PLAIN}"
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空!${PLAIN}"; return; fi
    
    echo -e "${CYAN}请输入面板实际运行端口 (默认 8008):${PLAIN}"
    read -r BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-8008}

    # 直接使用内存缓存 (更快)
    CACHE_PATH="/dev/shm/nginx/nezha"
    CACHE_SIZE="500m"
    echo -e "${GREEN}已启用内存缓存模式${PLAIN}"

    # 备份
    mv /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%F_%T)" 2>/dev/null
    
    # 目录准备
    mkdir -p /etc/nginx/certs
    mkdir -p /var/cache/nginx/nezha
    mkdir -p /dev/shm/nginx/nezha
    chmod 755 /var/cache/nginx/nezha
    chmod 755 /dev/shm/nginx/nezha
    chown -R www-data:www-data /var/cache/nginx
    chown -R www-data:www-data /dev/shm/nginx

    # 生成临时自签名证书 (让 Nginx 可以先启动)
    if [ ! -f /etc/nginx/certs/fullchain.cer ]; then
        echo -e "${CYAN}生成临时自签名证书...${PLAIN}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/nginx/certs/private.key \
            -out /etc/nginx/certs/fullchain.cer \
            -subj "/CN=${DOMAIN}" 2>/dev/null
        # 创建 chain.cer 符号链接
        ln -sf /etc/nginx/certs/fullchain.cer /etc/nginx/certs/chain.cer 2>/dev/null
        echo -e "${GREEN}临时证书已生成 (稍后将被正式证书替换)${PLAIN}"
    fi

    # 检测 nginx 版本，选择兼容的 HTTP/2 写法 (>=1.26 用 http2 on;，旧版用 listen ... http2)
    local nginx_ver HTTP2_DIRECTIVE
    nginx_ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$nginx_ver" ] && [ "$(printf '%s\n1.26\n' "$nginx_ver" | sort -V | head -1)" = "1.26" ]; then
        HTTP2_DIRECTIVE="listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        http2 on;"
    else
        HTTP2_DIRECTIVE="listen 443 ssl http2 default_server;
        listen [::]:443 ssl http2 default_server;"
    fi

    # 写入优化配置
    cat > /etc/nginx/nginx.conf << EOF
#################################################
#   /etc/nginx/nginx.conf  —  Debian 12 版     #
#   哪吒监控面板三S优化版 v${SCRIPT_VERSION}               #
#   安全加固 / 高稳定 / 极速响应               #
#   优化日期: $(date +%F)                      #
#################################################

# 1. 全局配置 - 硬件优化
user  www-data;
worker_processes  auto;
worker_rlimit_nofile 102400;

error_log  /var/log/nginx/error.log warn;
pid        /run/nginx.pid;

# 2. events 高性能配置
events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

# 3. http 主配置
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # -------- 隐藏版本信息 --------
    server_tokens off;

    # -------- 条件日志 - 减少2xx/3xx日志 --------
    # 注: 原为正则 ~^[23]，改列举以规避 CVE-2026-42533（map 正则匹配堆溢出）
    map \$status \$loggable {
        default 1;
        200 0;
        201 0;
        202 0;
        203 0;
        204 0;
        206 0;
        301 0;
        302 0;
        303 0;
        304 0;
        307 0;
        308 0;
    }

    # -------- 兼容的日志格式 --------
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                   '\$status \$body_bytes_sent "\$http_referer" '
                   '"\$http_user_agent" "\$http_x_forwarded_for" '
                   'rt=\$request_time '
                   'uct="\$upstream_connect_time" '
                   'uht="\$upstream_header_time" '
                   'urt="\$upstream_response_time"';

    # -------- Cloudflare 真实IP获取 --------
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 131.0.72.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    set_real_ip_from 2400:cb00::/32;
    set_real_ip_from 2606:4700::/32;
    set_real_ip_from 2803:f800::/32;
    set_real_ip_from 2405:b500::/32;
    set_real_ip_from 2405:8100::/32;
    set_real_ip_from 2a06:98c0::/29;
    set_real_ip_from 2c0f:f248::/32;

    real_ip_header    CF-Connecting-IP;
    real_ip_recursive on;

    # 真实IP变量映射
    map \$http_cf_connecting_ip \$real_ip {
        ""      \$remote_addr;
        default \$http_cf_connecting_ip;
    }

    # -------- 性能优化配置 --------
    sendfile on;
    sendfile_max_chunk 1m;
    tcp_nopush on;
    tcp_nodelay on;
    underscores_in_headers on;
    
    keepalive_timeout   120s;
    keepalive_requests  10000;
    client_max_body_size 500m;
    client_body_timeout 120s;
    client_header_timeout 120s;
    send_timeout 120s;
    reset_timedout_connection on;
    
    # 大内存优化
    client_body_buffer_size 256k;
    client_header_buffer_size 4k;
    large_client_header_buffers 8 16k;
    output_buffers 4 64k;
    postpone_output 1460;

    # -------- 代理全局优化 --------
    proxy_connect_timeout       10s;
    proxy_send_timeout          60s;
    proxy_read_timeout          60s;
    proxy_next_upstream_timeout 60s;
    proxy_next_upstream_tries   3;
    proxy_intercept_errors      on;

    # -------- Gzip 压缩配置 --------
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_proxied any;
    gzip_buffers 32 8k;
    gzip_static on;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml
        application/x-font-ttf
        font/opentype
        application/wasm
        application/x-web-app-manifest+json
        application/manifest+json;

    # -------- [安全] SSL 增强配置 --------
    ssl_protocols TLSv1.2 TLSv1.3;
    # TLS 1.3 优先，排除弱密码套件
    ssl_ciphers TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA;
    ssl_prefer_server_ciphers on;
    ssl_ecdh_curve X25519:secp384r1:secp256r1;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets on;
    ssl_buffer_size 4k;
    
    # [安全] 早期数据攻击防护 (0-RTT)
    ssl_early_data off;

    # -------- [稳定/安全] 限流配置 - 防CC攻击 --------
    # API 请求限流
    limit_req_zone \$binary_remote_addr zone=nezha_api:20m rate=50r/s;
    # WebSocket 连接限流
    limit_req_zone \$binary_remote_addr zone=nezha_ws:10m rate=50r/s;
    # 登录接口强限流 (防暴力破解)
    limit_req_zone \$binary_remote_addr zone=nezha_login:10m rate=5r/m;
    # 静态资源限流
    limit_req_zone \$binary_remote_addr zone=nezha_static:10m rate=100r/s;
    # gRPC 探针限流
    limit_req_zone \$binary_remote_addr zone=nezha_grpc:20m rate=100r/s;

    # 连接数限制
    limit_conn_zone \$binary_remote_addr zone=perip:10m;
    limit_conn_zone \$server_name zone=perserver:10m;

    # -------- upstream配置 - HTTP/1.1 --------
    upstream nezha_dashboard {
        server 127.0.0.1:${BACKEND_PORT} max_fails=3 fail_timeout=30s;
        keepalive 64;
        keepalive_requests 10000;
        keepalive_timeout 120s;
    }

    # -------- upstream配置 - gRPC 专用 --------
    upstream nezha_grpc {
        server 127.0.0.1:${BACKEND_PORT};
        keepalive 32;
    }

    # -------- 缓存配置 --------
    proxy_cache_path ${CACHE_PATH} levels=1:2 keys_zone=nezha_cache:100m 
                     max_size=${CACHE_SIZE} inactive=60m use_temp_path=off;

    proxy_cache_background_update on;
    proxy_cache_revalidate on;
    proxy_cache_lock on;
    proxy_cache_lock_timeout 5s;

    # ========================================================
    #  HTTP 重定向服务器
    # ========================================================
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name ${DOMAIN};

        # 安全重定向到HTTPS
        location / {
            return 301 https://\$server_name\$request_uri;
        }

        # 健康检查（HTTP版本）
        location = /nginx-health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        access_log off;
    }

    # ========================================================
    #  HTTPS 主服务器 - 哪吒监控面板
    # ========================================================
    server {
        ${HTTP2_DIRECTIVE}
        server_name ${DOMAIN};
        
        # 连接数限制
        limit_conn perip 50;
        limit_conn perserver 1000;
        
        # -------- SSL证书配置 --------
        ssl_certificate     /etc/nginx/certs/fullchain.cer;
        ssl_certificate_key /etc/nginx/certs/private.key;
        
        # [稳定] OCSP装订配置 - 加速 SSL 握手
        ssl_stapling on;
        ssl_stapling_verify on;
        ssl_trusted_certificate /etc/nginx/certs/chain.cer;
        resolver 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 valid=300s;
        resolver_timeout 10s;

        # -------- [安全] 安全头配置增强 --------
        # 注意: nginx 的 add_header 不跨层继承——只要某 location 自带 add_header，
        # 父级的安全头就会丢失。因此统一放进 snippet，并在每个自带 add_header 的
        # location 内 include 一次，确保整站生效。
        include /etc/nginx/snippets/nezha_security_headers.conf;

        # -------- [速度] 日志优化 - 减少 I/O --------
        access_log /var/log/nginx/nezha.access.log main buffer=128k flush=60s if=\$loggable;
        error_log  /var/log/nginx/nezha.error.log warn;

        # -------- robots.txt --------
        location = /robots.txt {
            return 200 "User-agent: *\nDisallow: /\n";
            add_header Content-Type text/plain;
            access_log off;
        }

        # -------- favicon.ico 特殊处理 --------
        location = /favicon.ico {
            proxy_pass http://nezha_dashboard;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header nz-realip \$real_ip;
            
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            
            access_log off;
            expires 30d;
            add_header Cache-Control "public, immutable";
            include /etc/nginx/snippets/nezha_security_headers.conf;
        }

        # -------- 静态资源缓存 --------
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|map|json|webp|avif|wasm)\$ {
            limit_req zone=nezha_static burst=200 nodelay;
            
            proxy_pass http://nezha_dashboard;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header nz-realip \$real_ip;
            
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            
            # 稳定的缓存配置
            proxy_cache nezha_cache;
            proxy_cache_key "\$scheme\$proxy_host\$request_uri\$is_args\$args";
            proxy_cache_valid 200 304 24h;
            proxy_cache_valid 404 1m;
            proxy_cache_valid any 1h;
            proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
            
            # 浏览器缓存
            expires 7d;
            add_header Cache-Control "public, immutable";
            add_header X-Cache-Status \$upstream_cache_status always;
            add_header Vary "Accept-Encoding";
            include /etc/nginx/snippets/nezha_security_headers.conf;
        }

        # -------- gRPC 探针通信 - 使用专用 upstream --------
        location ^~ /proto.NezhaService/ {
            limit_req zone=nezha_api burst=100 nodelay;
            
            grpc_pass grpc://nezha_grpc;

            grpc_set_header Host \$host;
            grpc_set_header nz-realip \$real_ip;
            grpc_set_header X-Real-IP \$real_ip;

            # gRPC超时配置
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_connect_timeout 10s;
            grpc_socket_keepalive on;

            # gRPC缓冲区
            client_max_body_size 50m;
            grpc_buffer_size 16m;

            error_page 502 503 504 /grpc_error.html;
        }

        # -------- 禁止网页终端 SSH (安全加固) --------
        location ~* ^/api/v1/ws/terminal {
            return 403;
            access_log off;
        }

        # -------- WebSocket 连接 (仅允许 server 和 file) --------
        location ~* ^/api/v1/ws/(server|file)(.*)\$ {
            limit_req zone=nezha_ws burst=50 nodelay;
            
            proxy_pass http://nezha_dashboard;

            # WebSocket头配置
            proxy_set_header Host \$host;
            proxy_set_header Origin https://\$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header nz-realip \$real_ip;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            # WebSocket超时
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 10s;

            # WebSocket优化
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_cache off;
            proxy_redirect off;
        }

        # -------- 登录接口保护 --------
        location ~* ^/api/v1/(login|auth) {
            limit_req zone=nezha_login burst=5 nodelay;
            
            proxy_pass http://nezha_dashboard;
            
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header nz-realip \$real_ip;

            proxy_http_version 1.1;
            proxy_set_header Connection "";
            
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
            proxy_connect_timeout 10s;
            
            # 禁用缓存
            add_header Cache-Control "no-cache, no-store, must-revalidate" always;
            add_header Pragma "no-cache" always;
            add_header Expires "0" always;
            include /etc/nginx/snippets/nezha_security_headers.conf;
        }

        # -------- API接口 --------
        location ~* ^/api/ {
            limit_req zone=nezha_api burst=100 nodelay;
            
            proxy_pass http://nezha_dashboard;

            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header nz-realip \$real_ip;

            proxy_http_version 1.1;
            proxy_set_header Connection "";
            
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            proxy_connect_timeout 10s;

            # API缓冲区优化
            proxy_buffer_size 64k;
            proxy_buffers 32 64k;
            proxy_busy_buffers_size 128k;

            add_header Cache-Control "no-cache" always;
            include /etc/nginx/snippets/nezha_security_headers.conf;
        }

        # -------- 主页面路由 --------
        location / {
            proxy_pass http://nezha_dashboard;

            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$real_ip;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header REMOTE-HOST \$real_ip;
            proxy_set_header nz-realip \$real_ip;

            proxy_http_version 1.1;
            
            # 主页面超时 - 优化为合理值
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            proxy_connect_timeout 60s;

            # 主页面缓冲区
            proxy_buffer_size 64k;
            proxy_buffers 32 64k;
            proxy_busy_buffers_size 128k;
            proxy_max_temp_file_size 0;

            # 主页面不缓存
            add_header Cache-Control "no-cache, no-store, must-revalidate" always;
            add_header Pragma "no-cache" always;
            add_header Expires "0" always;
            include /etc/nginx/snippets/nezha_security_headers.conf;

            # 隐藏服务器信息
            proxy_hide_header X-Powered-By;
            proxy_hide_header Server;
        }

        # -------- 健康检查 --------
        location = /nginx-health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # -------- 状态监控 (仅限本地访问) --------
        location = /nginx-status {
            stub_status on;
            access_log off;
            allow 127.0.0.1;
            allow ::1;
            deny all;
        }

        # -------- 错误页面 --------
        error_page 400 401 403 404 /40x.html;
        error_page 500 502 503 504 /50x.html;
        
        location = /40x.html {
            root /var/www/html;
            internal;
        }
        
        location = /50x.html {
            root /var/www/html;
            internal;
        }

        location = /grpc_error.html {
            root /var/www/html;
            internal;
        }

        # -------- 安全防护 --------
        # 隐藏文件保护
        location ~ /\. {
            deny all;
            access_log off;
            log_not_found off;
        }

        # 恶意路径阻止
        location ~* /(wp-admin|wp-login|phpmyadmin|admin|xmlrpc|wp-config|\.env|\.git) {
            deny all;
            access_log off;
            log_not_found off;
        }

        # 危险文件扩展名
        location ~* \.(sql|bak|backup|old|tmp|log|conf|ini|sh|bat|exe)\$ {
            deny all;
            access_log off;
            log_not_found off;
        }

        # 恶意扫描器 User-Agent 阻止
        # 注: 原为 http 块的 map \$bad_ua，正则移出 map 以规避 CVE-2026-42533
        if (\$http_user_agent ~* "(nmap|nikto|wikto|sf|sqlmap|bsqlbf|w3af|acunetix|havij|appscan)") {
            return 403;
        }
    }
}
EOF
    
    # 创建错误页面文件
    cat > /var/www/html/40x.html << 'ERREOF'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>访问错误</title>
<style>body{font-family:sans-serif;text-align:center;padding:80px;background:#0f172a;color:#94a3b8}h1{font-size:4rem;color:#f87171;margin:0}p{margin-top:16px;font-size:1.1rem}</style>
</head>
<body><h1>4xx</h1><p>请求错误，请检查地址或稍后再试。</p></body>
</html>
ERREOF

    cat > /var/www/html/50x.html << 'ERREOF'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>服务错误</title>
<style>body{font-family:sans-serif;text-align:center;padding:80px;background:#0f172a;color:#94a3b8}h1{font-size:4rem;color:#f87171;margin:0}p{margin-top:16px;font-size:1.1rem}</style>
</head>
<body><h1>5xx</h1><p>服务暂时不可用，请稍后再试。</p></body>
</html>
ERREOF

    cat > /var/www/html/grpc_error.html << 'ERREOF'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>gRPC 错误</title>
<style>body{font-family:sans-serif;text-align:center;padding:80px;background:#0f172a;color:#94a3b8}h1{font-size:4rem;color:#f87171;margin:0}p{margin-top:16px;font-size:1.1rem}</style>
</head>
<body><h1>gRPC Error</h1><p>gRPC 服务暂时不可用。</p></body>
</html>
ERREOF

    # 安全响应头 snippet (整站复用，避免 add_header 不继承导致丢失)
    mkdir -p /etc/nginx/snippets
    cat > /etc/nginx/snippets/nezha_security_headers.conf << 'SECEOF'
# 哪吒面板安全响应头 - 在每个自带 add_header 的 location 内 include 以避免继承丢失
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options SAMEORIGIN always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
add_header Cross-Origin-Resource-Policy "same-site" always;
SECEOF

    if nginx -t 2>/dev/null; then
        echo -e "${GREEN}Nginx 配置验证通过${PLAIN}"
        systemctl restart nginx
        echo -e "${GREEN}Nginx 已启动 (使用临时证书，请继续申请正式证书)${PLAIN}"
    else
        echo -e "${RED}Nginx 配置测试失败，请检查配置${PLAIN}"
        nginx -t
        return 1
    fi
}

# ==============================================================
# 证书续期成功推送脚本（由 acme.sh reloadcmd 在续期后触发）
# ==============================================================
deploy_cert_notify() {
    cat > /opt/nezha/nezha_cert_notify.sh << 'CNEOF'
#!/bin/bash
# SSL 证书续期成功后由 acme.sh reloadcmd 调用，推送 TG 通知。
# token / chat 运行时从 nezha_health.py 读取，不落地到本脚本。
PYSRC=/opt/nezha/nezha_health.py
TOKEN=$(grep -m1 '^TG_BOT_TOKEN' "$PYSRC" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')
CHAT=$(grep -m1 '^TG_CHAT_ID' "$PYSRC" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "请填写" ] || [ -z "$CHAT" ]; then exit 0; fi

CERT=/etc/nginx/certs/fullchain.cer
DOMAIN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | grep -oE 'CN ?= ?[^,]+' | sed -E 's/CN ?= ?//')
EXP_RAW=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
EXP=$(TZ='Asia/Shanghai' date -d "$EXP_RAW" '+%Y-%m-%d %H:%M' 2>/dev/null)
NOW=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')

MSG=$(printf '🔐 <b>#SSL证书已续期</b>\n🌐 域名：<code>%s</code>\n🕐 续期时间：%s\n📅 新到期：%s' "${DOMAIN:-未知}" "$NOW" "${EXP:-未知}")

curl -s -m 10 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT}" \
    --data-urlencode "text=${MSG}" \
    --data-urlencode "parse_mode=HTML" >/dev/null 2>&1
exit 0
CNEOF
    chmod +x /opt/nezha/nezha_cert_notify.sh
}

# ==============================================================
# 证书自动续期定时器（systemd，按 Asia/Shanghai，跟系统时区无关）
# 取代 acme.sh 自带 cron，避免各地区时区换算出错
# ==============================================================
setup_cert_renew_timer() {
    cat > /etc/systemd/system/nezha-cert-renew.service << 'SVCEOF'
[Unit]
Description=Nezha SSL Cert Auto Renew (acme.sh)

[Service]
Type=oneshot
ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
SVCEOF
    cat > /etc/systemd/system/nezha-cert-renew.timer << 'TMREOF'
[Unit]
Description=Nezha SSL Cert Auto Renew Timer

[Timer]
OnCalendar=*-*-* 06:00:00 Asia/Shanghai
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
TMREOF
    systemctl daemon-reload
    systemctl enable --now nezha-cert-renew.timer
    # 关闭 acme.sh 自带 crontab，统一由上面的 systemd 定时器接管
    if crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
        crontab -l 2>/dev/null | grep -v 'acme.sh --cron' | crontab -
    fi
}

# ==============================================================
# 模块 5: SSL 证书申请 (acme.sh + Cloudflare DNS API)
# ==============================================================
cert_management() {
    echo -e "${BLUE}>>> 证书管理 (acme.sh + Cloudflare DNS)...${PLAIN}"
    
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "${YELLOW}正在安装 acme.sh...${PLAIN}"
        read -p "请输入注册邮箱 (用于 SSL 通知): " EMAIL
        curl https://get.acme.sh | sh -s email="$EMAIL"
    fi

    # 续期检查改用 systemd timer（按 Asia/Shanghai 定时，跟系统时区无关）
    setup_cert_renew_timer

    echo -e "${CYAN}-------------------------------------------------------------${PLAIN}"
    echo -e "${CYAN}请一次性填写以下信息 (ZeroSSL + Cloudflare API):${PLAIN}"
    echo -e "${CYAN}-------------------------------------------------------------${PLAIN}"
    
    echo -e "${YELLOW}>> 提示 - Cloudflare 信息获取: https://dash.cloudflare.com/profile/api-tokens${PLAIN}"
    echo -e "${YELLOW}   (Token 需选择 'Edit Zone DNS' 模板)${PLAIN}"
    echo -e "${YELLOW}>> 提示 - Account ID 获取: Cloudflare 域名概览页右下角${PLAIN}"
    echo -e "${YELLOW}>> 提示 - ZeroSSL EAB 获取: https://app.zerossl.com/developer${PLAIN}"
    echo -e ""

    # 自动复用模块4 已写入 nginx.conf 的域名 (server_name)，回车即沿用
    local DEFAULT_DOMAIN
    DEFAULT_DOMAIN=$(grep -A 20 'listen 443' /etc/nginx/nginx.conf 2>/dev/null | grep 'server_name' | head -1 | awk '{print $2}' | tr -d ';')
    if [ -n "$DEFAULT_DOMAIN" ] && [ "$DEFAULT_DOMAIN" != "_" ]; then
        read -r -p "1. 您的域名 (Domain) [回车复用 ${DEFAULT_DOMAIN}]: " DOMAIN
        DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}
    else
        read -r -p "1. 您的域名 (Domain): " DOMAIN
    fi
    echo -e "${CYAN}请把以下 4 项一起粘贴进来 (每行一个，需带参数名，可中/英文冒号；粘贴完空一行回车结束)：${PLAIN}"
    echo -e "${YELLOW}  Cloudflare API Token: xxxxxxxx${PLAIN}"
    echo -e "${YELLOW}  Cloudflare Account ID: xxxxxxxx${PLAIN}"
    echo -e "${YELLOW}  ZeroSSL EAB KID: LgMkYoTv${PLAIN}"
    echo -e "${YELLOW}  ZeroSSL EAB HMAC Key: xxxxxxxx${PLAIN}"
    CF_TOKEN=""; CF_ACCOUNT_ID=""; KID=""; HMAC=""
    while IFS= read -r _line; do
        [ -z "$_line" ] && break
        # 取冒号(中/英文)后的值并去除首尾空格
        _val=$(printf '%s' "$_line" | sed -E 's/^[^:]*://; t; s/^[^：]*：//')
        _val=$(printf '%s' "$_val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        case "$(printf '%s' "$_line" | tr 'A-Z' 'a-z')" in
            *hmac*)    HMAC="$_val" ;;
            *kid*)     KID="$_val" ;;
            *token*)   CF_TOKEN="$_val" ;;
            *account*) CF_ACCOUNT_ID="$_val" ;;
        esac
    done
    # 必填项缺失时回退到单独补填 (KID/HMAC 为可选，留空则跳过 ZeroSSL 注册)
    [ -z "$CF_TOKEN" ]      && read -r -p "补填 Cloudflare API Token: " CF_TOKEN
    [ -z "$CF_ACCOUNT_ID" ] && read -r -p "补填 Cloudflare Account ID: " CF_ACCOUNT_ID
    echo -e "${GREEN}已识别 → Token:$([ -n "$CF_TOKEN" ] && echo ✔ || echo ✗)  Account:$([ -n "$CF_ACCOUNT_ID" ] && echo ✔ || echo ✗)  KID:$([ -n "$KID" ] && echo ✔ || echo —)  HMAC:$([ -n "$HMAC" ] && echo ✔ || echo —)${PLAIN}"

    echo -e "${CYAN}-------------------------------------------------------------${PLAIN}"
    echo -e "${BLUE}正在处理...${PLAIN}"

    if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空!${PLAIN}"; return; fi
    if [ -z "$CF_TOKEN" ] || [ -z "$CF_ACCOUNT_ID" ]; then echo -e "${RED}Cloudflare 信息不完整!${PLAIN}"; return; fi

    export CF_Token="$CF_TOKEN"
    export CF_Account_ID="$CF_ACCOUNT_ID"

    # 如果填写了 ZeroSSL 信息则注册
    if [ -n "$KID" ] && [ -n "$HMAC" ]; then
         echo -e "${BLUE}正在注册 ZeroSSL 账户...${PLAIN}"
         ~/.acme.sh/acme.sh --register-account --server zerossl --eab-kid "$KID" --eab-hmac-key "$HMAC"
    else
         echo -e "${YELLOW}未提供 ZeroSSL 凭据，尝试直接申请 (若失败请检查每90天是否需要一次 EAB)...${PLAIN}"
    fi

    # 申请证书
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --server zerossl

    # 部署证书续期成功推送脚本（由 reloadcmd 在续期后触发）
    deploy_cert_notify

    # 安装证书并自动重载 Nginx（续期成功后推送 TG 通知）
    echo -e "${BLUE}>>> 正在安装证书 (包含 chain.cer)...${PLAIN}"

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file       /etc/nginx/certs/private.key  \
        --fullchain-file /etc/nginx/certs/fullchain.cer \
        --ca-file        /etc/nginx/certs/chain.cer \
        --reloadcmd     "systemctl reload nginx && /opt/nezha/nezha_cert_notify.sh"

    chmod 755 /etc/nginx/certs
    chmod 644 /etc/nginx/certs/*.cer 2>/dev/null
    chmod 600 /etc/nginx/certs/private.key 2>/dev/null
    
    systemctl restart nginx
    echo -e "${GREEN}证书安装完成!${PLAIN}"
}

# ==============================================================
# 模块 6: GitHub OAuth 配置
# ==============================================================
configure_oauth() {
    echo -e "${BLUE}>>> 配置 GitHub OAuth 登录...${PLAIN}"
    echo -e "${YELLOW}是否配置 GitHub OAuth 2.0 登录? [Y/n]${PLAIN}"
    read -r CONFIGURE_OAUTH
    
    [[ -z "$CONFIGURE_OAUTH" ]] && CONFIGURE_OAUTH="y"
    
    if [[ "$CONFIGURE_OAUTH" =~ ^[yY]$ ]]; then
        # 显示 Callback URL
        echo -e ""
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e "${CYAN}  请在 GitHub OAuth App 中填写 Callback URL:${PLAIN}"
        echo -e "${GREEN}  https://你的域名/api/v1/oauth2/callback${PLAIN}"
        echo -e "${CYAN}=================================================${PLAIN}"
        echo -e ""
        
        # 自动获取域名 (从 Nginx 配置或证书中读取)
        if [ -z "$DOMAIN" ]; then
            # 方法1: 从 Nginx 配置读取 server_name (HTTPS 块)
            DOMAIN=$(grep -A 20 'listen 443' /etc/nginx/nginx.conf 2>/dev/null | grep 'server_name' | head -1 | awk '{print $2}' | tr -d ';')
            
            # 方法2: 如果失败，从任意 server_name 读取
            if [ -z "$DOMAIN" ]; then
                DOMAIN=$(grep 'server_name' /etc/nginx/nginx.conf 2>/dev/null | grep -v '#' | grep -v '_' | head -1 | awk '{print $2}' | tr -d ';')
            fi
            
            # 方法3: 从证书读取 CN
            if [ -z "$DOMAIN" ] && [ -f /etc/nginx/certs/fullchain.cer ]; then
                DOMAIN=$(openssl x509 -in /etc/nginx/certs/fullchain.cer -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
            fi
            
            # 方法4: 从证书读取 SAN
            if [ -z "$DOMAIN" ] && [ -f /etc/nginx/certs/fullchain.cer ]; then
                DOMAIN=$(openssl x509 -in /etc/nginx/certs/fullchain.cer -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | grep 'DNS:' | head -1 | sed 's/.*DNS:\([^,]*\).*/\1/')
            fi
        fi
        
        # 始终显示域名状态
        if [ -n "$DOMAIN" ]; then
            echo -e "${GREEN}当前域名: ${DOMAIN}${PLAIN}"
        else
            echo -e "${YELLOW}未检测到域名，Agent 对接地址需在网页中手动设置${PLAIN}"
        fi
        
        echo -e "${YELLOW}>> GitHub OAuth App 创建地址: https://github.com/settings/applications/new${PLAIN}"
        echo -e "${YELLOW}   回调地址填: https://${DOMAIN:-你的域名}/api/v1/oauth2/callback${PLAIN}"
        echo -e ""
        echo -e "${CYAN}请输入 GitHub Client ID:${PLAIN}"
        read -r CLIENT_ID
        echo -e "${CYAN}请输入 GitHub Client Secret:${PLAIN}"
        read -r CLIENT_SECRET

        if [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ]; then
            CONFIG_FILE="${DATA_DIR}/config.yaml"

            # 备份现有配置
            if [ -f "$CONFIG_FILE" ]; then
                cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%F_%T)"
                echo -e "${GREEN}已备份现有配置${PLAIN}"
            else
                # 如果配置不存在，先启动一次让面板生成默认配置
                mkdir -p ${DATA_DIR}
                systemctl start nezha-dashboard 2>/dev/null
                local _j=0
                while [ ! -f "$CONFIG_FILE" ] && [ $_j -lt 10 ]; do
                    sleep 2; _j=$((_j + 1))
                done
                systemctl stop nezha-dashboard 2>/dev/null
            fi

            systemctl stop nezha-dashboard 2>/dev/null

            # 先删除可能存在的旧配置（避免重复）
            sed -i '/^install_host:/d' "$CONFIG_FILE" 2>/dev/null
            sed -i '/^site_name:/d' "$CONFIG_FILE" 2>/dev/null
            sed -i '/^tls:/d' "$CONFIG_FILE" 2>/dev/null
            sed -i '/^language:/d' "$CONFIG_FILE" 2>/dev/null
            sed -i '/^location:/d' "$CONFIG_FILE" 2>/dev/null
            sed -i '/^oauth2:/,/^[a-z_]*:/{ /^oauth2:/d; /^  /d; }' "$CONFIG_FILE" 2>/dev/null

            # 追加新配置
            cat >> "$CONFIG_FILE" <<EOF
install_host: "${DOMAIN:-localhost}:443"
site_name: "Nezha Monitoring"
tls: true
language: zh_CN
location: Asia/Shanghai
oauth2:
  GitHub:
    client_id: "${CLIENT_ID}"
    client_secret: "${CLIENT_SECRET}"
    endpoint:
      auth_url: "https://github.com/login/oauth/authorize"
      token_url: "https://github.com/login/oauth/access_token"
    user_info_url: "https://api.github.com/user"
    user_id_path: "id"
EOF
            
            systemctl restart nezha-dashboard
            echo -e ""
            echo -e "${GREEN}GitHub OAuth 配置完成!${PLAIN}"
        else
            echo -e "${RED}输入信息不完整，跳过配置${PLAIN}"
        fi
    else
        echo -e "${YELLOW}已跳过 OAuth 配置${PLAIN}"
        echo -e "${CYAN}提示: 如需后续配置，请运行脚本选择选项 5${PLAIN}"
    fi
}

# ==============================================================
# 模块 7: 查看优化状态
# ==============================================================
show_optimization_status() {
    echo -e "${BLUE}>>> Nginx 优化状态检查...${PLAIN}"
    echo -e ""
    
    # 检查 Nginx 版本
    echo -e "${CYAN}Nginx 版本:${PLAIN}"
    nginx -v 2>&1
    echo -e ""
    
    # 检查缓存目录
    echo -e "${CYAN}缓存目录状态:${PLAIN}"
    if [ -d /dev/shm/nginx/nezha ]; then
        echo -e "  内存缓存: ${GREEN}已启用${PLAIN} (/dev/shm/nginx/nezha)"
        du -sh /dev/shm/nginx/nezha 2>/dev/null || echo "  大小: 0"
    else
        echo -e "  内存缓存: ${YELLOW}未创建${PLAIN}"
    fi
    
    if [ -d /var/cache/nginx/nezha ]; then
        echo -e "  磁盘缓存: ${GREEN}已创建${PLAIN} (/var/cache/nginx/nezha)"
        du -sh /var/cache/nginx/nezha 2>/dev/null || echo "  大小: 0"
    else
        echo -e "  磁盘缓存: ${YELLOW}未创建${PLAIN}"
    fi
    echo -e ""
    
    # 检查服务状态
    echo -e "${CYAN}服务状态:${PLAIN}"
    if systemctl is-active --quiet nginx; then
        echo -e "  Nginx: ${GREEN}运行中${PLAIN}"
    else
        echo -e "  Nginx: ${RED}已停止${PLAIN}"
    fi
    
    if systemctl is-active --quiet nezha-dashboard; then
        echo -e "  Nezha Dashboard: ${GREEN}运行中${PLAIN}"
    else
        echo -e "  Nezha Dashboard: ${RED}已停止${PLAIN}"
    fi
    echo -e ""
    
    # 检查配置语法
    echo -e "${CYAN}Nginx 配置检查:${PLAIN}"
    if nginx -t 2>&1; then
        echo -e "  ${GREEN}配置语法正确${PLAIN}"
    else
        echo -e "  ${RED}配置存在问题${PLAIN}"
    fi
    echo -e ""
    
    # 显示优化提示
    echo -e "${CYAN}已应用的优化:${PLAIN}"
    echo -e "  ✓ 移除无效的 epoll_events 指令"
    echo -e "  ✓ 添加专用 gRPC upstream"
    echo -e "  ✓ 条件日志减少磁盘 I/O"
    echo -e "  ✓ SSL Session Tickets 已开启"
    echo -e "  ✓ 主页面超时优化为 300s"
    echo -e "  ✓ 添加 /nginx-status 监控端点"
    echo -e ""
}

# ==============================================================
# 模块 8: 查看实时日志
# ==============================================================
show_logs() {
    clear
    echo -e "${BLUE}>>> 日志查看菜单${PLAIN}"
    echo -e ""
    echo -e "  1. 面板日志 (nezha-dashboard)"
    echo -e "  2. Nginx 访问日志"
    echo -e "  3. Nginx 错误日志"
    echo -e "  4. 系统日志 (syslog)"
    echo -e ""
    echo -e "  0. 返回主菜单"
    echo -e ""
    read -p "请选择日志类型: " log_choice
    
    case "$log_choice" in
        1)
            echo -e ""
            echo -e "${YELLOW}正在查看面板实时日志... (按 Ctrl+C 退出)${PLAIN}"
            echo -e ""
            trap 'echo -e "\n${GREEN}已退出日志查看${PLAIN}"' INT
            journalctl -u nezha-dashboard -f --no-pager
            trap - INT
            ;;
        2)
            echo -e ""
            echo -e "${YELLOW}正在查看 Nginx 访问日志... (按 Ctrl+C 退出)${PLAIN}"
            echo -e ""
            trap 'echo -e "\n${GREEN}已退出日志查看${PLAIN}"' INT
            tail -f /var/log/nginx/nezha.access.log 2>/dev/null || tail -f /var/log/nginx/access.log
            trap - INT
            ;;
        3)
            echo -e ""
            echo -e "${YELLOW}正在查看 Nginx 错误日志... (按 Ctrl+C 退出)${PLAIN}"
            echo -e ""
            trap 'echo -e "\n${GREEN}已退出日志查看${PLAIN}"' INT
            tail -f /var/log/nginx/nezha.error.log 2>/dev/null || tail -f /var/log/nginx/error.log
            trap - INT
            ;;
        4)
            echo -e ""
            echo -e "${YELLOW}正在查看系统日志... (按 Ctrl+C 退出)${PLAIN}"
            echo -e ""
            trap 'echo -e "\n${GREEN}已退出日志查看${PLAIN}"' INT
            journalctl -f --no-pager
            trap - INT
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            sleep 1
            ;;
    esac
    
    press_any_key
}
# ==============================================================
# 辅助函数: 按任意键返回菜单
# ==============================================================
press_any_key() {
    echo -e ""
    echo -e "${CYAN}按任意键返回菜单...${PLAIN}"
    read -n 1 -s -r
}

# ==============================================================
# 辅助函数: 获取服务状态
# ==============================================================
get_service_status() {
    if systemctl is-active --quiet nginx 2>/dev/null; then
        NGINX_STATUS="${GREEN}运行中${PLAIN}"
    else
        NGINX_STATUS="${RED}已停止${PLAIN}"
    fi
    
    if systemctl is-active --quiet nezha-dashboard 2>/dev/null; then
        NEZHA_STATUS="${GREEN}运行中${PLAIN}"
    else
        NEZHA_STATUS="${RED}已停止${PLAIN}"
    fi
    NEZHA_VER=$(cat /opt/nezha/version 2>/dev/null)
    NEZHA_VER=${NEZHA_VER:-未知}

    if systemctl is-active --quiet nezha-notify.timer 2>/dev/null; then
        NOTIFY_STATUS="${GREEN}已启用${PLAIN}"
    else
        NOTIFY_STATUS="${RED}未启用${PLAIN}"
    fi

    if systemctl is-active --quiet nezha-health 2>/dev/null; then
        HEALTH_STATUS="${GREEN}运行中${PLAIN}"
    else
        HEALTH_STATUS="${RED}未运行${PLAIN}"
    fi

    if systemctl is-active --quiet nezha-upgrade.timer 2>/dev/null; then
        DETECT_STATUS="${GREEN}已启用${PLAIN}"
    else
        DETECT_STATUS="${RED}未启用${PLAIN}"
    fi

    if [ "$(grep '^AUTO_UPDATE=' "$UPGRADE_SCRIPT" 2>/dev/null | head -1 | sed -E 's/.*"(.*)".*/\1/')" = "true" ]; then
        AUTOUP_STATUS="${GREEN}已开启${PLAIN}"
    else
        AUTOUP_STATUS="${RED}未开启${PLAIN}"
    fi

    # 检测证书状态
    CERT_FILE="/etc/nginx/certs/fullchain.cer"
    if [ -f "$CERT_FILE" ]; then
        # 获取证书信息
        CERT_ISSUER=$(openssl x509 -in "$CERT_FILE" -noout -issuer 2>/dev/null)
        CERT_SUBJECT=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null)
        CERT_EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2)
        
        # 检查是否为正式 CA 颁发的证书
        if echo "$CERT_ISSUER" | grep -qiE "(ZeroSSL|Let.s Encrypt|DigiCert|Sectigo|Comodo|GeoTrust|GlobalSign|R3|E1)"; then
            # 正式证书 - 检查过期时间
            EXPIRY_EPOCH=$(date -d "$CERT_EXPIRY" +%s 2>/dev/null)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
            if [ $DAYS_LEFT -lt 0 ]; then
                CERT_STATUS="${RED}已过期${PLAIN}"
            elif [ $DAYS_LEFT -lt 7 ]; then
                CERT_STATUS="${YELLOW}即将过期 (${DAYS_LEFT}天)${PLAIN}"
            else
                CERT_STATUS="${GREEN}正式证书${PLAIN} (${DAYS_LEFT}天后过期)"
            fi
        else
            # 检查是否自签名
            if [ "$CERT_ISSUER" = "$CERT_SUBJECT" ]; then
                CERT_STATUS="${YELLOW}临时证书${PLAIN} (请申请正式证书)"
            else
                # 未知 CA
                CERT_STATUS="${YELLOW}未知 CA${PLAIN}"
            fi
        fi
    else
        CERT_STATUS="${RED}未安装${PLAIN}"
    fi
}

# ==============================================================
# 服务控制函数
# ==============================================================
service_control() {
    echo -e "${BLUE}>>> 服务控制...${PLAIN}"
    echo -e ""
    echo -e " 1. 启动 Nginx"
    echo -e " 2. 重启 Nginx"
    echo -e " 3. 停止 Nginx"
    echo -e " 4. 启动 哪吒面板"
    echo -e " 5. 重启 哪吒面板"
    echo -e " 6. 停止 哪吒面板"
    echo -e " 7. 重启全部服务"
    echo -e " 0. 返回主菜单"
    echo -e ""
    read -p "请选择操作: " action
    
    case "$action" in
        1)
            echo -e "${CYAN}启动 Nginx...${PLAIN}"
            systemctl start nginx && echo -e "${GREEN}Nginx 已启动${PLAIN}" || echo -e "${RED}启动失败${PLAIN}"
            ;;
        2)
            echo -e "${CYAN}重启 Nginx...${PLAIN}"
            systemctl restart nginx && echo -e "${GREEN}Nginx 已重启${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
            ;;
        3)
            echo -e "${CYAN}停止 Nginx...${PLAIN}"
            systemctl stop nginx && echo -e "${GREEN}Nginx 已停止${PLAIN}" || echo -e "${RED}停止失败${PLAIN}"
            ;;
        4)
            echo -e "${CYAN}启动 哪吒面板...${PLAIN}"
            systemctl start nezha-dashboard && echo -e "${GREEN}哪吒面板 已启动${PLAIN}" || echo -e "${RED}启动失败${PLAIN}"
            ;;
        5)
            echo -e "${CYAN}重启 哪吒面板...${PLAIN}"
            systemctl restart nezha-dashboard && echo -e "${GREEN}哪吒面板 已重启${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
            ;;
        6)
            echo -e "${CYAN}停止 哪吒面板...${PLAIN}"
            systemctl stop nezha-dashboard && echo -e "${GREEN}哪吒面板 已停止${PLAIN}" || echo -e "${RED}停止失败${PLAIN}"
            ;;
        7)
            echo -e "${CYAN}重启全部服务...${PLAIN}"
            systemctl restart nginx
            systemctl restart nezha-dashboard
            echo -e "${GREEN}全部服务已重启${PLAIN}"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
    press_any_key
}

# ==============================================================
# 同步界面美化代码到 Nezha config.yaml
# ==============================================================
sync_custom_code() {
    local CONFIG_FILE="${DATA_DIR}/config.yaml"

    # 内嵌界面美化代码，存入 bash 变量（quoted heredoc，$ 和单引号不被解释）
    local CUSTOM_CODE
    CUSTOM_CODE=$(cat << 'HTMLEOF'
<script>
    /* 全局设置变量 */
    window.CustomBackgroundImage = 'https://picsum.photos/3840/2160';
    window.CustomMobileBackgroundImage = 'https://picsum.photos/1080/1920';
    window.CustomDesc = 'Bud';
    window.ShowNetTransfer = true;
    window.FixedTopServerName = true;
    /* 禁用右侧的小人插画 */
    window.DisableAnimatedMan = true;

    /* 加载 MiSans 字体 (jsDelivr CDN，font.sec.mi-sans.com 不可达) */
    ['https://cdn.jsdelivr.net/npm/misans@4.0.0/lib/Normal/MiSans-Regular.min.css',
     'https://cdn.jsdelivr.net/npm/misans@4.0.0/lib/Normal/MiSans-Bold.min.css'
    ].forEach(function(href) {
        var link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = href;
        document.head.appendChild(link);
    });

    /* 天数徽章自定义阈值着色：>7天绿色，4-7天黄色，≤3天红色，永久蓝色 */
    function applyBadgeColors() {
        document.querySelectorAll('div.flex.items-center.gap-2 > div.text-muted-foreground').forEach(badge => {
            const days = parseInt(badge.textContent.match(/(\d+)/)?.[1]);
            if (isNaN(days)) return;
            if (days <= 3) {
                badge.style.setProperty('background-color', '#ef4444', 'important');
            } else if (days <= 7) {
                badge.style.setProperty('background-color', '#f59e0b', 'important');
            } else {
                badge.style.setProperty('background-color', '#22c55e', 'important');
            }
        });
        document.querySelectorAll('div.text-muted-foreground').forEach(badge => {
            if (badge.textContent.includes('永久')) {
                badge.style.setProperty('background-color', '#3b82f6', 'important');
                badge.style.setProperty('color', '#fff', 'important');
                badge.style.setProperty('padding', '1px 4px', 'important');
                badge.style.setProperty('border-radius', '4px', 'important');
                badge.style.setProperty('font-weight', '500', 'important');
                badge.style.setProperty('display', 'inline-block', 'important');
            }
        });
    }
    const observerBadge = new MutationObserver(applyBadgeColors);
    observerBadge.observe(document.body, { childList: true, subtree: true });

    /* 修改页脚右侧 */
    const observerFooterRight = new MutationObserver(() => {
        const footerRight = document.querySelector('.server-footer-theme');
        if (footerRight) {
            footerRight.innerHTML = '<section>Powered by <a href="https://github.com/nezhahq/nezha" target="_blank">NeZha</a></section>';
            observerFooterRight.disconnect();
        }
    });

    observerFooterRight.observe(document.body, {
        childList: true, subtree: true
    });
</script>
<style>
    /* 默认字体 */
    * {
        font-family: 'MiSans', sans-serif;
    }

    /* 背景模糊效果 */
    .dark .bg-cover::after {
        content: '';
        position: absolute;
        inset: 0;
        backdrop-filter: blur(6px);
        background-color: rgba(0, 0, 0, 0.6);
    }

    .light .bg-cover::after {
        content: '';
        position: absolute;
        inset: 0;
        backdrop-filter: blur(6px);
        background-color: rgba(255, 255, 255, 0.3);
    }

    /* --- 动态颜色天数徽章 --- */
    div.flex.items-center.gap-2>div[role="progressbar"] {
        display: none !important;
    }

    div.flex.items-center.gap-2>p.text-muted-foreground {
        font-size: 11px !important;
        font-weight: 500 !important;
    }

    div.flex.items-center.gap-2>div.text-muted-foreground {
        font-weight: 500 !important;
        color: #fff !important;
        padding: 1px 4px !important;
        font-size: 10px !important;
        border-radius: 4px;
        transition: background-color 0.3s ease;
    }

    div.flex.items-center.gap-2:has(div[class*="bg-green"])>div.text-muted-foreground {
        background-color: #22c55e !important;
    }

    div.flex.items-center.gap-2:has(div[class*="bg-yellow"])>div.text-muted-foreground,
    div.flex.items-center.gap-2:has(div[class*="bg-orange"])>div.text-muted-foreground {
        background-color: #f59e0b !important;
    }

    div.flex.items-center.gap-2:has(div[class*="bg-red"])>div.text-muted-foreground {
        background-color: #ef4444 !important;
    }

    /* ===== 毛玻璃效果 ===== */

    /* Dark 模式 - 卡片 */
    .dark [class*="rounded-lg"],
    .dark [class*="rounded-xl"],
    .dark [class*="rounded-["]:not([class*="border-none"]):not([class*="inline-flex"]) {
        background-color: rgba(15, 23, 42, 0.55) !important;
        backdrop-filter: blur(12px) saturate(180%) !important;
        -webkit-backdrop-filter: blur(12px) saturate(180%) !important;
        border: 1px solid rgba(255, 255, 255, 0.3) !important;
        box-shadow: 0 4px 24px rgba(0, 0, 0, 0.25) !important;
        transition: box-shadow 0.3s ease, border-color 0.3s ease, transform 0.3s ease !important;
    }

    /* Dark 模式 - 卡片悬停 */
    .dark [class*="rounded-lg"]:hover,
    .dark [class*="rounded-xl"]:hover,
    .dark [class*="rounded-["]:not([class*="border-none"]):not([class*="inline-flex"]):hover {
        border-color: rgba(255, 255, 255, 0.3) !important;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35) !important;
        transform: translateY(-3px) !important;
    }

    /* Light 模式 - 卡片 */
    .light [class*="rounded-lg"],
    .light [class*="rounded-xl"],
    .light [class*="rounded-["]:not([class*="border-none"]):not([class*="inline-flex"]) {
        background-color: rgba(255, 255, 255, 0.55) !important;
        backdrop-filter: blur(12px) saturate(180%) !important;
        -webkit-backdrop-filter: blur(12px) saturate(180%) !important;
        border: 1px solid rgba(255, 255, 255, 0.65) !important;
        box-shadow: 0 4px 24px rgba(0, 0, 0, 0.08) !important;
        transition: box-shadow 0.3s ease, border-color 0.3s ease, transform 0.3s ease !important;
    }

    /* Light 模式 - 卡片悬停 */
    .light [class*="rounded-lg"]:hover,
    .light [class*="rounded-xl"]:hover,
    .light [class*="rounded-["]:not([class*="border-none"]):not([class*="inline-flex"]):hover {
        border-color: rgba(255, 255, 255, 0.9) !important;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.12) !important;
        transform: translateY(-3px) !important;
    }

    /* 下载徽章统一为带底色风格（与上传一致） */
    .dark div.inline-flex.text-foreground:not([class*="bg-"]) {
        background-color: hsl(var(--secondary)) !important;
        color: hsl(var(--secondary-foreground)) !important;
    }

    .light div.inline-flex.text-foreground:not([class*="bg-"]) {
        background-color: hsl(var(--secondary)) !important;
        color: hsl(var(--secondary-foreground)) !important;
    }

    /* 导航栏毛玻璃 */
    .dark header {
        background-color: rgba(15, 23, 42, 0.55) !important;
        backdrop-filter: blur(16px) !important;
        -webkit-backdrop-filter: blur(16px) !important;
        border-bottom: 1px solid rgba(255, 255, 255, 0.3) !important;
    }

    .light header {
        background-color: rgba(255, 255, 255, 0.55) !important;
        backdrop-filter: blur(16px) !important;
        -webkit-backdrop-filter: blur(16px) !important;
        border-bottom: 1px solid rgba(255, 255, 255, 0.7) !important;
    }

    /* --- 服务器标题行 (名字居中) --- */
    div:has(> p.break-normal.font-bold) {
        width: 100%;
        justify-content: center !important;
        align-items: baseline !important;
    }

    p.break-normal.font-bold {
        font-size: 15px !important;
        font-weight: 700 !important;
        color: var(--color-text, inherit) !important;
    }

    div:has(> p.break-normal.font-bold)>div:nth-child(2)>span {
        font-size: 16px !important;
    }

    /* ===================== 美化增强模块 ===================== */

    /* 等宽数字：刷新时数字不抖动 */
    body {
        font-variant-numeric: tabular-nums;
    }

    /* --- 卡片入场：网格内子项淡入上滑（前几个错峰） --- */
    @keyframes nz-fade-up {
        from { opacity: 0; transform: translateY(10px); }
        to   { opacity: 1; transform: translateY(0); }
    }
    [class*="grid"] > * {
        animation: nz-fade-up 0.45s cubic-bezier(0.4, 0, 0.2, 1) both;
    }
    [class*="grid"] > *:nth-child(2) { animation-delay: 0.04s; }
    [class*="grid"] > *:nth-child(3) { animation-delay: 0.08s; }
    [class*="grid"] > *:nth-child(4) { animation-delay: 0.12s; }
    [class*="grid"] > *:nth-child(5) { animation-delay: 0.16s; }
    [class*="grid"] > *:nth-child(6) { animation-delay: 0.20s; }
    [class*="grid"] > *:nth-child(7) { animation-delay: 0.24s; }
    [class*="grid"] > *:nth-child(8) { animation-delay: 0.28s; }
    [class*="grid"] > *:nth-child(n+9) { animation-delay: 0.32s; }

    /* --- 在线状态呼吸灯：绿色圆点脉动发光 --- */
    @keyframes nz-pulse-online {
        0%   { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.7); }
        70%  { box-shadow: 0 0 0 7px rgba(34, 197, 94, 0); }
        100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
    }
    [class~="rounded-full"][class*="bg-green-500"],
    [class~="rounded-full"][class*="bg-green-600"] {
        animation: nz-pulse-online 2s infinite;
    }

    /* --- 资源进度条：圆角 + 渐变填充 + 平滑过渡 + 高负载发光 --- */
    div[role="progressbar"],
    div[role="progressbar"] > div {
        border-radius: 9999px !important;
    }
    div[role="progressbar"] > div {
        transition: transform 0.5s cubic-bezier(0.4, 0, 0.2, 1),
                    width 0.5s cubic-bezier(0.4, 0, 0.2, 1),
                    background-color 0.3s ease !important;
    }
    div[role="progressbar"] > div[class*="bg-green"] {
        background-image: linear-gradient(90deg, #16a34a, #4ade80) !important;
    }
    div[role="progressbar"] > div[class*="bg-yellow"],
    div[role="progressbar"] > div[class*="bg-orange"] {
        background-image: linear-gradient(90deg, #d97706, #fbbf24) !important;
    }
    div[role="progressbar"] > div[class*="bg-red"] {
        background-image: linear-gradient(90deg, #dc2626, #f87171) !important;
        box-shadow: 0 0 8px rgba(239, 68, 68, 0.6) !important;
    }

    /* --- 主题细滚动条 --- */
    * {
        scrollbar-width: thin;
        scrollbar-color: rgba(148, 163, 184, 0.4) transparent;
    }
    ::-webkit-scrollbar { width: 8px; height: 8px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb {
        background: rgba(148, 163, 184, 0.4);
        border-radius: 4px;
    }
    ::-webkit-scrollbar-thumb:hover {
        background: rgba(148, 163, 184, 0.65);
    }

    /* --- 选中文字高亮色 --- */
    ::selection {
        background: rgba(59, 130, 246, 0.35);
    }

    /* --- 尊重系统"减少动画"偏好 --- */
    @media (prefers-reduced-motion: reduce) {
        *, *::before, *::after {
            animation-duration: 0.001ms !important;
            animation-iteration-count: 1 !important;
            transition-duration: 0.001ms !important;
        }
    }
</style>
HTMLEOF
)

    # 等待 Nezha 首次启动生成 config.yaml（最多等 20 秒）
    local i=0
    while [ ! -f "$CONFIG_FILE" ] && [ $i -lt 10 ]; do
        echo -e "${YELLOW}等待 Nezha 生成配置文件... (${i}/10)${PLAIN}"
        sleep 2
        i=$((i + 1))
    done

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}配置文件不存在，请先安装并启动面板${PLAIN}"
        return 1
    fi

    echo -e "${CYAN}>> 同步界面美化代码到 config.yaml...${PLAIN}"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%F_%T)" 2>/dev/null
    systemctl stop nezha-dashboard 2>/dev/null

    CONFIG_FILE="$CONFIG_FILE" CUSTOM_CODE="$CUSTOM_CODE" python3 << 'PYEOF'
import os

config_path  = os.environ['CONFIG_FILE']
html_content = os.environ['CUSTOM_CODE']

with open(config_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# 删除旧 custom_code 块（key 行 + 后续缩进行；含块内空行）
# 注意：Nezha 重新保存配置时会把字面块 | 里的空行规范成无缩进空行，
# 所以空行也必须算作块的一部分跳过，否则会在空行处提前结束、
# 把剩余 HTML 当成顶层 YAML 保留，导致 config.yaml 解析失败。
result = []
skip = False
for line in lines:
    if line.startswith('custom_code:'):
        skip = True
        continue
    if skip and (line.strip() == '' or line[:1] in (' ', '\t')):
        continue
    skip = False
    result.append(line)

# 追加新 custom_code（YAML literal block）
result.append('custom_code: |\n')
for line in html_content.splitlines():
    result.append('  ' + line + '\n')

with open(config_path, 'w', encoding='utf-8') as f:
    f.writelines(result)

print('custom_code 写入完成')
PYEOF

    local EXIT_CODE=$?
    systemctl restart nezha-dashboard
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}界面美化代码同步完成，面板已重启${PLAIN}"
    else
        echo -e "${RED}同步失败，请检查 Python3 是否可用${PLAIN}"
    fi
}

# ==============================================================
# 模块 10: 到期通知管理 (Telegram Bot)
# ==============================================================
NOTIFY_SCRIPT="/opt/nezha/nezha_notify.py"

# ==============================================================
# 模块 11: 服务器健康告警 (Telegram Bot - WebSocket 守护进程)
# ==============================================================
HEALTH_SCRIPT="/opt/nezha/nezha_health.py"
HEALTH_SERVICE="/etc/systemd/system/nezha-health.service"
BOT_SCRIPT="/opt/nezha/nezha_bot.py"
BOT_SERVICE="/etc/systemd/system/nezha-bot.service"

deploy_health_script() {
    cat > "$HEALTH_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
# 哪吒服务器健康告警 - REST API 守护进程，5秒轮询/15秒判离线 + 持续超阈值资源告警

import json, time, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta

# ============ 配置 ============
TG_BOT_TOKEN      = "请填写"
TG_CHAT_ID        = "请填写"
CPU_THRESHOLD     = 90    # CPU 告警阈值 %
MEM_THRESHOLD     = 90    # 内存告警阈值 %
DISK_THRESHOLD    = 90    # 磁盘告警阈值 %
CPU_INTERVAL      = 60    # CPU 持续超阈值多少秒后才告警
MEM_INTERVAL      = 60    # 内存持续超阈值多少秒后才告警
DISK_INTERVAL     = 60    # 磁盘持续超阈值多少秒后才告警
NET_IN_THRESHOLD  = 0     # 入站带宽告警阈值 MB/s，0=不启用
NET_OUT_THRESHOLD = 0     # 出站带宽告警阈值 MB/s，0=不启用
OFFLINE_SECS      = 15    # 超过多少秒未上报视为离线
PANEL_RESTART_GRACE = 120 # 面板重启后 last_active 全体归零的宽限秒数，期间不做离线判定
TG_FAIL_BACKOFF   = 30    # TG 发送失败后的默认退避秒数（429 则以接口返回的 retry_after 为准）
OFFLINE_ALERT_ENABLED   = True   # 离线/上线告警独立开关
RESOURCE_ALERT_ENABLED = False  # CPU/内存/磁盘告警独立开关
OFFLINE_REMINDER_MINS  = [15, 30, 45, 60, 120, 300, 480, 720]  # 持续离线提醒间隔（分钟）
CHECK_INTERVAL    = 5     # 守护进程检测间隔（秒）
NEZHA_HOST        = "127.0.0.1"
NEZHA_PORT        = 8008
STATE_FILE        = "/opt/nezha/nezha_health_state.json"
PAT_FILE          = "/opt/nezha/.nezha_pat"   # 只读 PAT（nezha:inventory:read），由安装脚本生成
# ==============================

CST = timezone(timedelta(hours=8))

_last_api_fail  = 0.0   # 最近一次 API 取数失败的时刻，用于识别面板重启
_tg_pause_until = 0.0   # TG 发送失败/限流后的静默截止时刻

COUNTRY_CODES = {
    'AD','AE','AF','AG','AL','AM','AO','AR','AT','AU','AZ','BA','BB','BD','BE',
    'BF','BG','BH','BI','BJ','BN','BO','BR','BS','BT','BW','BY','BZ','CA','CD',
    'CF','CG','CH','CI','CL','CM','CN','CO','CR','CU','CV','CY','CZ','DE','DJ',
    'DK','DM','DO','DZ','EC','EE','EG','ER','ES','ET','FI','FJ','FM','FR','GA',
    'GB','GD','GE','GH','GM','GN','GQ','GR','GT','GW','GY','HK','HN','HR','HT',
    'HU','ID','IE','IL','IN','IQ','IR','IS','IT','JM','JO','JP','KE','KG','KH',
    'KI','KM','KN','KP','KR','KW','KY','KZ','LA','LB','LC','LI','LK','LR','LS',
    'LT','LU','LV','LY','MA','MC','MD','ME','MG','MK','ML','MM','MN','MO','MR',
    'MT','MU','MV','MW','MX','MY','MZ','NA','NE','NG','NI','NL','NO','NP','NR',
    'NZ','OM','PA','PE','PG','PH','PK','PL','PT','PW','PY','QA','RO','RS','RU',
    'RW','SA','SB','SC','SD','SE','SG','SI','SK','SL','SM','SN','SO','SR','SS',
    'ST','SV','SY','SZ','TD','TG','TH','TJ','TL','TM','TN','TO','TR','TT','TV',
    'TW','TZ','UA','UG','US','UY','UZ','VA','VC','VE','VN','VU','WS','YE','ZA',
    'ZM','ZW',
}

def get_data():
    """通过 REST API 获取服务器实时状态（带只读 PAT 认证），返回 {"servers": [...]}。

    与旧的裸 WebSocket 帧解析相比：数据同源（last_active 纳秒精度一致，离线判定精度不变），
    且 REST 还多返回 load_1/5/15。需要 /opt/nezha/.nezha_pat 内的 nezha:inventory:read PAT。
    """
    try:
        with open(PAT_FILE) as f:
            pat = f.read().strip()
    except Exception:
        raise RuntimeError(f"PAT 文件不可读: {PAT_FILE}")
    if not pat:
        raise RuntimeError(f"PAT 为空: {PAT_FILE}")
    req = urllib.request.Request(
        f"http://{NEZHA_HOST}:{NEZHA_PORT}/api/v1/server",
        headers={"Authorization": f"Bearer {pat}"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        d = json.loads(resp.read())
    return {"servers": d.get("data") or []}


def pct(used, total):
    if not total:
        return 0.0
    return used * 100.0 / total


def parse_last_active(ts_str):
    """Parse RFC3339/ISO8601 timestamp, return Unix seconds."""
    if not ts_str:
        return 0
    ts_str = ts_str.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(ts_str)
        if dt.year <= 1:  # Go zero time: 0001-01-01
            return 0
        return dt.timestamp()
    except Exception:
        return 0


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


class TGError(RuntimeError):
    """发送失败，retry_after 为建议的退避秒数。"""
    def __init__(self, msg, retry_after=TG_FAIL_BACKOFF):
        super().__init__(msg)
        self.retry_after = retry_after


def send_tg(message):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = json.dumps({
        "chat_id": TG_CHAT_ID,
        "text": message,
        "parse_mode": "HTML"
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        # 429 限流：Telegram 在 parameters.retry_after 给出应等待的秒数，必须遵守。
        # 群组限流约 20 条/分钟，批量掉线时很容易撞上；若无视它按轮询间隔重发，
        # 只会不断延长限流时间。
        if e.code == 429:
            try:
                body = json.loads(e.read() or b"{}")
            except Exception:
                body = {}
            raise TGError("限流 429", (body.get("parameters") or {}).get("retry_after", TG_FAIL_BACKOFF))
        raise TGError(f"HTTP {e.code}")
    if not result.get("ok"):
        raise TGError(f"TG send failed: {result}")


def run_check():
    now_ts  = time.time()
    now_cst = datetime.now(CST)
    time_str = now_cst.strftime("%Y-%m-%d %H:%M:%S")

    global _last_api_fail, _tg_pause_until
    try:
        data = get_data()
    except Exception as e:
        _last_api_fail = now_ts
        print(f"[{time_str}] API 取数失败: {e}")
        return

    state = load_state()
    orig  = load_state()   # 独立副本，某条告警发送失败时用于回滚该机器的状态
    msgs  = []

    # 面板 v2.3.0 起，agent 一断连就把 last_active 清零（v2.2.10 会保留最后心跳时间），
    # 面板重启时同样全体归零。零值本身分不出「这台掉线」还是「面板刚重启」，靠范围区分：
    # 面板重启 = API 刚从不可用恢复 或 本轮全员归零；其余零值都是这台机器真掉线。
    servers = [(s, parse_last_active(s.get("last_active", ""))) for s in data.get("servers", [])]
    zero_n  = sum(1 for _, la in servers if not la)
    panel_restarting = (now_ts - _last_api_fail) < PANEL_RESTART_GRACE or (servers and zero_n == len(servers))

    for srv, last_act in servers:
        name     = srv.get("name", "unknown")
        s_data   = srv.get("state") or {}
        h_data   = srv.get("host") or {}
        cc       = ((srv.get("geoip") or {}).get("country_code") or "").upper()

        prev = state.get(name, {})
        cur  = dict(prev)

        if not last_act:
            if panel_restarting:
                continue                          # 数据不可信，整轮跳过，不动 state
            last_act = prev.get("last_seen", 0)   # 回退到最后一次已知心跳，照常做 15s 判定
        else:
            cur["last_seen"] = last_act

        flag = ""
        if cc and len(cc) == 2 and cc in COUNTRY_CODES:
            flag = chr(0x1F1E6 + ord(cc[0]) - 65) + chr(0x1F1E6 + ord(cc[1]) - 65)
        label = f"{flag + ' ' if flag else ''}<b>#{name}</b>"

        is_online = (now_ts - last_act) < OFFLINE_SECS if last_act else False
        cpu      = s_data.get("cpu", 0)
        mem_pct  = pct(s_data.get("mem_used", 0), h_data.get("mem_total", 0))
        disk_pct = pct(s_data.get("disk_used", 0), h_data.get("disk_total", 0))
        net_in   = s_data.get("net_in_speed",  0) / 1048576   # bytes/s → MB/s
        net_out  = s_data.get("net_out_speed", 0) / 1048576
        tcp_cnt  = s_data.get("tcp_conn_count", 0)
        udp_cnt  = s_data.get("udp_conn_count", 0)

        # ---- 离线 / 上线 ----
        was_online = prev.get("online", True)
        cur["online"] = is_online

        # 在线时记录最近一次状态快照，供掉线消息显示「掉线前最后状态」
        if is_online:
            cur["last_snapshot"] = {"cpu": cpu, "mem": mem_pct, "disk": disk_pct,
                                    "tcp": tcp_cnt, "udp": udp_cnt}

        # 离线计时追踪（始终执行，与告警开关无关）
        if not is_online and was_online:
            cur["offline_since"] = last_act or now_ts
            cur["offline_reminder_idx"] = 0
            cur["offline_reminder_ts"] = now_ts
        elif is_online and not was_online:
            for k in ("offline_since", "offline_reminder_idx", "offline_reminder_ts"):
                cur.pop(k, None)
        elif not is_online and not was_online and not prev.get("offline_since"):
            cur["offline_since"] = last_act or now_ts
            cur["offline_reminder_idx"] = 0
            cur["offline_reminder_ts"] = now_ts

        if OFFLINE_ALERT_ENABLED:
            if not is_online and was_online:
                last_str = datetime.fromtimestamp(last_act, CST).strftime("%Y-%m-%d %H:%M:%S") if last_act else "未知"
                snap = prev.get("last_snapshot")
                snap_line = (
                    f"\n📊C:<b><u>{snap['cpu']:.1f}%</u></b> R:<b><u>{snap['mem']:.1f}%</u></b> D:<b><u>{snap['disk']:.1f}%</u></b> 🌐<b><u>{snap['tcp']}/{snap['udp']}</u></b>"
                ) if snap else ""
                msgs.append((name,
                    f"❌ <b>服务器已离线</b>\n"
                    f"{label}\n"
                    f"🕐 最后在线:{last_str}"
                    f"{snap_line}"
                ))
            elif is_online and not was_online:
                off_since = prev.get("offline_since", 0)
                if off_since:
                    secs = int(now_ts - off_since)
                    h = secs // 3600; m = (secs % 3600) // 60; s = secs % 60
                    if h:
                        dur = f"{h}小时{m}分钟" if m else f"{h}小时"
                    elif m:
                        dur = f"{m}分钟{s}秒" if s else f"{m}分钟"
                    else:
                        dur = f"{s}秒"
                    dur_suffix = f"（{dur}）"
                else:
                    dur_suffix = ""
                res_line = (
                    f"\n📊C:<b><u>{cpu:.1f}%</u></b> R:<b><u>{mem_pct:.1f}%</u></b> D:<b><u>{disk_pct:.1f}%</u></b> 🌐<b><u>{tcp_cnt}/{udp_cnt}</u></b>"
                )
                msgs.append((name,
                    f"✅ <b>服务器已恢复上线</b>\n"
                    f"{label}\n"
                    f"🕐 恢复:{time_str}{dur_suffix}"
                    f"{res_line}"
                ))
            elif not is_online and not was_online:
                offline_since = cur.get("offline_since", 0)
                reminder_idx  = cur.get("offline_reminder_idx", 0)
                last_rts      = cur.get("offline_reminder_ts", offline_since)
                if offline_since:
                    if reminder_idx < len(OFFLINE_REMINDER_MINS):
                        fire_ts = offline_since + OFFLINE_REMINDER_MINS[reminder_idx] * 60
                    else:
                        fire_ts = last_rts + OFFLINE_REMINDER_MINS[-1] * 60
                    if now_ts >= fire_ts:
                        secs = int(now_ts - offline_since)
                        m = secs // 60; h = m // 60; m %= 60
                        dur = (f"{h}小时{m}分钟" if m else f"{h}小时") if h else f"{m}分钟"
                        msgs.append((name,
                            f"❌ <b>服务器仍未恢复</b>\n"
                            f"{label}\n"
                            f"⏱ 已离线:<b>{dur}</b>"
                        ))
                        cur["offline_reminder_idx"] = reminder_idx + 1
                        cur["offline_reminder_ts"] = now_ts

        if not is_online:
            # 离线时清除资源计时
            for k in ("cpu_since", "mem_since", "disk_since",
                      "cpu_alerted", "mem_alerted", "disk_alerted"):
                cur.pop(k, None)
            state[name] = cur
            continue

        # ---- 资源告警（持续超阈值指定秒数才发） ----
        if not RESOURCE_ALERT_ENABLED:
            state[name] = cur
            continue

        def check_res(key, val, threshold, interval):
            was_alerted = prev.get(f"{key}_alerted", False)
            since       = prev.get(f"{key}_since", 0)
            if val >= threshold:
                if not since:
                    cur[f"{key}_since"] = now_ts
                else:
                    cur[f"{key}_since"] = since
                    if (now_ts - since) >= interval and not was_alerted:
                        cur[f"{key}_alerted"] = True
                        return "alert"
                cur.setdefault(f"{key}_alerted", False)
            else:
                cur[f"{key}_since"]   = 0
                cur[f"{key}_alerted"] = False
                if was_alerted:
                    return "recover"
            return None

        cpu_r    = check_res("cpu",     cpu,      CPU_THRESHOLD,  CPU_INTERVAL)
        mem_r    = check_res("mem",     mem_pct,  MEM_THRESHOLD,  MEM_INTERVAL)
        disk_r   = check_res("disk",    disk_pct, DISK_THRESHOLD, DISK_INTERVAL)
        net_in_r = check_res("net_in",  net_in,   NET_IN_THRESHOLD,  60) if NET_IN_THRESHOLD  > 0 else None
        net_out_r= check_res("net_out", net_out,  NET_OUT_THRESHOLD, 60) if NET_OUT_THRESHOLD > 0 else None

        checks = [
            ("CPU",    cpu,      CPU_THRESHOLD,  "%",    cpu_r),
            ("内存",   mem_pct,  MEM_THRESHOLD,  "%",    mem_r),
            ("磁盘",   disk_pct, DISK_THRESHOLD, "%",    disk_r),
            ("入站带宽", net_in, NET_IN_THRESHOLD,  "MB/s", net_in_r),
            ("出站带宽", net_out,NET_OUT_THRESHOLD, "MB/s", net_out_r),
        ]
        alerts   = [(n, v, t, u) for n, v, t, u, r in checks if r == "alert"]
        recovers = [n            for n, v, t, u, r in checks if r == "recover"]

        if alerts:
            parts = "\n".join(
                f"  {n}: <b>{v:.1f}{u}</b>（阈值 {t}{u}）" for n, v, t, u in alerts
            )
            msgs.append((name,
                f"⚠️ <b>服务器资源告警</b>（{time_str}）\n"
                f"{label}\n{parts}\n"
                f"📊C:<b><u>{cpu:.1f}%</u></b> R:<b><u>{mem_pct:.1f}%</u></b> D:<b><u>{disk_pct:.1f}%</u></b> 🌐<b><u>{tcp_cnt}/{udp_cnt}</u></b>"
                + (f" ⇅{net_in:.1f}/{net_out:.1f}MB/s" if NET_IN_THRESHOLD or NET_OUT_THRESHOLD else "")
            ))
        if recovers:
            msgs.append((name,
                f"✅ <b>资源告警已解除</b>（{time_str}）\n"
                f"{label}\n"
                + "  " + " / ".join(recovers) + " 已恢复正常"
            ))

        state[name] = cur

    # 先发送再落盘：发送失败的机器回滚状态，下一轮会重新判定并重发，
    # 否则状态已翻转而消息没发出去，这条告警就被永久吞掉了。
    for name, msg in msgs:
        if time.time() < _tg_pause_until:
            state[name] = orig.get(name, {})   # 仍在退避期，整批延后
            continue
        try:
            send_tg(msg)
            print(f"[{time_str}] 已发送: {msg[:60]}...")
        except Exception as e:
            wait = getattr(e, "retry_after", TG_FAIL_BACKOFF)
            _tg_pause_until = time.time() + wait
            state[name] = orig.get(name, {})
            print(f"[{time_str}] 发送失败(已回滚状态，{wait}s 后重试): {e}")

    save_state(state)

    if not msgs:
        print(f"[{time_str}] 检查完成，无告警")


def main():
    import sys
    if "--daemon" in sys.argv:
        print(f"健康监控启动 | 离线检测: {CHECK_INTERVAL}s | CPU: {CPU_INTERVAL}s | 内存: {MEM_INTERVAL}s | 磁盘: {DISK_INTERVAL}s")
        sys.stdout.flush()
        while True:
            try:
                run_check()
            except Exception as e:
                ts = datetime.now(CST).strftime("%Y-%m-%d %H:%M:%S")
                print(f"[{ts}] 检查异常: {e}")
            sys.stdout.flush()
            time.sleep(CHECK_INTERVAL)
    else:
        run_check()


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$HEALTH_SCRIPT"
}

_health_service_install() {
    cat > "$HEALTH_SERVICE" << EOF
[Unit]
Description=Nezha Health Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u ${HEALTH_SCRIPT} --daemon
Restart=always
RestartSec=5
StandardOutput=append:/var/log/nezha_health.log
StandardError=append:/var/log/nezha_health.log

[Install]
WantedBy=multi-user.target
EOF
    # 健康脚本每 CHECK_INTERVAL 秒写一行心跳，不轮转会无限增长（实测两个月 40MB/89 万行）。
    # 各服务用 StandardOutput=append: 持有 fd，必须用 copytruncate，否则轮转后仍写旧文件。
    cat > /etc/logrotate.d/nezha << 'EOF'
/var/log/nezha_health.log /var/log/nezha_notify.log /var/log/nezha_bot.log /var/log/nezha_upgrade.log {
    daily
    size 20M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    systemctl daemon-reload
    systemctl enable nezha-health
    # 健康脚本依赖只读 PAT 取数，确保其存在（幂等：已存在则跳过）
    ensure_health_pat
    systemctl restart nezha-health
}

manage_health() {
    if [ ! -f "$HEALTH_SCRIPT" ]; then
        deploy_health_script
    fi

    while true; do
    clear
    local cur_token cur_chatid cpu_thr mem_thr disk_thr cpu_intv mem_intv disk_intv net_in_thr net_out_thr offline_secs svc_status
    cur_token=$(grep  'TG_BOT_TOKEN'      "$HEALTH_SCRIPT" | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
    cur_chatid=$(grep 'TG_CHAT_ID'        "$HEALTH_SCRIPT" | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
    cpu_thr=$(grep    'CPU_THRESHOLD'     "$HEALTH_SCRIPT" | head -1 | grep -o '[0-9]*')
    mem_thr=$(grep    'MEM_THRESHOLD'     "$HEALTH_SCRIPT" | head -1 | grep -o '[0-9]*')
    disk_thr=$(grep   'DISK_THRESHOLD'    "$HEALTH_SCRIPT" | head -1 | grep -o '[0-9]*')
    cpu_intv=$(grep   'CPU_INTERVAL'      "$HEALTH_SCRIPT" | head -1 | awk -F= '{print $2}' | awk '{print $1}')
    mem_intv=$(grep   'MEM_INTERVAL'      "$HEALTH_SCRIPT" | head -1 | awk -F= '{print $2}' | awk '{print $1}')
    disk_intv=$(grep  'DISK_INTERVAL'     "$HEALTH_SCRIPT" | head -1 | awk -F= '{print $2}' | awk '{print $1}')
    net_in_thr=$(grep  'NET_IN_THRESHOLD'  "$HEALTH_SCRIPT" | head -1 | awk -F= '{print $2}' | awk '{print $1}')
    net_out_thr=$(grep 'NET_OUT_THRESHOLD' "$HEALTH_SCRIPT" | head -1 | awk -F= '{print $2}' | awk '{print $1}')
    offline_secs=$(grep 'OFFLINE_SECS' "$HEALTH_SCRIPT" | head -1 | grep -o '[0-9]*')
    offline_alert_raw=$(grep 'OFFLINE_ALERT_ENABLED' "$HEALTH_SCRIPT" | head -1 | grep -o 'True\|False')
    if [ "$offline_alert_raw" = "True" ]; then
        offline_alert_display="${GREEN}已开启${PLAIN}"
    else
        offline_alert_display="${RED}已关闭${PLAIN}"
    fi
    resource_alert_raw=$(grep 'RESOURCE_ALERT_ENABLED' "$HEALTH_SCRIPT" | head -1 | grep -o 'True\|False')
    if [ "$resource_alert_raw" = "True" ]; then
        resource_alert_display="${GREEN}已开启${PLAIN}"
    else
        resource_alert_display="${RED}已关闭${PLAIN}"
    fi
    if systemctl is-active --quiet nezha-health 2>/dev/null; then
        svc_status="${GREEN}运行中${PLAIN}"
    else
        svc_status="${RED}未运行${PLAIN}"
    fi

    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║${PLAIN}${BLUE}           服务器健康告警管理 (Telegram Bot)           ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  Bot Token  : ${cur_token:0:20}...                    ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  Chat ID    : ${cur_chatid}                                  ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  资源告警   : ${resource_alert_display}  (CPU ${cpu_thr}% | 内存 ${mem_thr}% | 磁盘 ${disk_thr}%)  ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  带宽告警   : 入站 ${net_in_thr} MB/s | 出站 ${net_out_thr} MB/s (0=关闭)  ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  持续时间   : CPU ${cpu_intv}s | 内存 ${mem_intv}s | 磁盘 ${disk_intv}s         ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  离线检测   : ${offline_secs}s  告警: ${offline_alert_display}                         ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  守护进程   : ${svc_status}                                 ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   1.  配置健康告警 (Token / Chat ID / 离线)          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   2.  配置 CPU/内存/磁盘告警                         ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   3.  开启/关闭离线告警                              ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   4.  立即测试一次检测                               ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   5.  停止守护进程                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   0.  返回主菜单                                     ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}"
    read -p " 请输入选项: " hchoice

    case "$hchoice" in
        1)
            echo -e ""
            echo -e "${CYAN}请粘贴 Bot Token 和 Chat ID（同行或换行均可，空行结束）:${PLAIN}"
            local raw_input="" _line
            while IFS= read -r _line; do
                [[ -z "$_line" ]] && break
                raw_input="$raw_input $_line"
            done
            new_token=$(echo "$raw_input" | grep -oE '[0-9]+:[A-Za-z0-9_-]+' | head -1)
            new_chatid=$(echo "${raw_input//$new_token/}" | grep -oE '\-?[0-9]{7,}' | head -1)
            read -p "离线多少秒后告警 [当前 ${offline_secs:-30}s]: " new_offline

            [ -z "$new_token" ] || [ -z "$new_chatid" ] && {
                echo -e "${RED}未能识别 Token 或 Chat ID，请检查格式${PLAIN}"; sleep 2; continue
            }
            [ -z "$new_offline" ] && new_offline=${offline_secs:-30}

            echo -e ""
            if [ -n "$cpu_thr" ]; then
                echo -e "${CYAN}CPU/内存/磁盘当前阈值: ${cpu_thr}% / ${mem_thr}% / ${disk_thr}%（不配置则保留）${PLAIN}"
            else
                echo -e "${CYAN}CPU/内存/磁盘未配置，不配置将使用默认值 90% / 90% / 90%${PLAIN}"
            fi
            read -p "是否配置 CPU/内存/磁盘告警阈值? [y/N]: " configure_res
            if [[ "$configure_res" =~ ^[yY]$ ]]; then
                new_resource_enabled="True"
                read -p "CPU 告警阈值 % [默认90]: " new_cpu
                read -p "内存告警阈值 % [默认90]: " new_mem
                read -p "磁盘告警阈值 % [默认90]: " new_disk
                read -p "入站带宽告警 MB/s [默认0=不告警]: " new_net_in
                read -p "出站带宽告警 MB/s [默认0=不告警]: " new_net_out
                read -p "CPU 持续超阈值多少秒后告警 [默认60]: " new_cpu_intv
                read -p "内存持续超阈值多少秒后告警 [默认60]: " new_mem_intv
                read -p "磁盘持续超阈值多少秒后告警 [默认60]: " new_disk_intv
            else
                new_resource_enabled="False"
            fi

            [ -z "$new_cpu" ]       && new_cpu=${cpu_thr:-90}
            [ -z "$new_mem" ]       && new_mem=${mem_thr:-90}
            [ -z "$new_disk" ]      && new_disk=${disk_thr:-90}
            [ -z "$new_net_in" ]    && new_net_in=${net_in_thr:-0}
            [ -z "$new_net_out" ]   && new_net_out=${net_out_thr:-0}
            [ -z "$new_cpu_intv" ]  && new_cpu_intv=${cpu_intv:-60}
            [ -z "$new_mem_intv" ]  && new_mem_intv=${mem_intv:-60}
            [ -z "$new_disk_intv" ] && new_disk_intv=${disk_intv:-60}

            # 重新部署最新脚本，清除旧状态，再写入配置
            deploy_health_script
            rm -f /opt/nezha/nezha_health_state.json
            sed -i "s|^TG_BOT_TOKEN      = .*|TG_BOT_TOKEN      = \"${new_token}\"|"   "$HEALTH_SCRIPT"
            sed -i "s|^TG_CHAT_ID        = .*|TG_CHAT_ID        = \"${new_chatid}\"|"  "$HEALTH_SCRIPT"
            sed -i "s|^CPU_THRESHOLD     = .*|CPU_THRESHOLD     = ${new_cpu}|"          "$HEALTH_SCRIPT"
            sed -i "s|^MEM_THRESHOLD     = .*|MEM_THRESHOLD     = ${new_mem}|"          "$HEALTH_SCRIPT"
            sed -i "s|^DISK_THRESHOLD    = .*|DISK_THRESHOLD    = ${new_disk}|"         "$HEALTH_SCRIPT"
            sed -i "s|^NET_IN_THRESHOLD  = .*|NET_IN_THRESHOLD  = ${new_net_in}|"       "$HEALTH_SCRIPT"
            sed -i "s|^NET_OUT_THRESHOLD = .*|NET_OUT_THRESHOLD = ${new_net_out}|"      "$HEALTH_SCRIPT"
            sed -i "s|^CPU_INTERVAL      = .*|CPU_INTERVAL      = ${new_cpu_intv}|"     "$HEALTH_SCRIPT"
            sed -i "s|^MEM_INTERVAL      = .*|MEM_INTERVAL      = ${new_mem_intv}|"     "$HEALTH_SCRIPT"
            sed -i "s|^DISK_INTERVAL     = .*|DISK_INTERVAL     = ${new_disk_intv}|"    "$HEALTH_SCRIPT"
            sed -i "s|^OFFLINE_SECS      = .*|OFFLINE_SECS      = ${new_offline}|"           "$HEALTH_SCRIPT"
            sed -i "s|^RESOURCE_ALERT_ENABLED = .*|RESOURCE_ALERT_ENABLED = ${new_resource_enabled}|" "$HEALTH_SCRIPT"
            # 保留用户原有的离线告警开关（重新部署会重置为默认 True）
            [ "$offline_alert_raw" = "False" ] && sed -i "s|^OFFLINE_ALERT_ENABLED   = .*|OFFLINE_ALERT_ENABLED   = False|" "$HEALTH_SCRIPT"
            echo -e "${GREEN}配置已保存${PLAIN}"

            _health_service_install
            echo -e "${GREEN}守护进程已启动并设为开机自启${PLAIN}"
            echo -e "${CYAN}正在发送测试消息...${PLAIN}"
            python3 - <<PYTEST
import urllib.request, json, sys
token = "${new_token}"
chat  = "${new_chatid}"
msg   = "✅ <b>Nezha 健康告警配置成功</b>\nBot 推送正常，告警将实时发送至此。"
url   = f"https://api.telegram.org/bot{token}/sendMessage"
data  = json.dumps({"chat_id": chat, "text": msg, "parse_mode": "HTML"}).encode()
req   = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=10)
    print("OK")
except Exception as e:
    print(f"FAIL:{e}", file=sys.stderr)
    sys.exit(1)
PYTEST
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ 测试消息已发送，请确认 Telegram 收到${PLAIN}"
                # 仅在 TG 测试通过后，首次自动拉起新版本检测 + 自动更新（复用本套 TG 配置）
                if [ ! -f "$UPGRADE_SCRIPT" ]; then
                    deploy_upgrade_script
                    sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE="true"/' "$UPGRADE_SCRIPT"
                    setup_upgrade_timer
                    echo -e "${GREEN}✅ 已自动开启「新版本检测 + 自动更新」(每天 10:00 北京时间，可在菜单 4 调整)${PLAIN}"
                fi
            else
                echo -e "${RED}❌ 发送失败，请检查 Token / Chat ID${PLAIN}"
            fi
            sleep 2
            continue
            ;;
        2)
            echo -e ""
            echo -e "${CYAN}当前阈值: CPU ${cpu_thr}% | 内存 ${mem_thr}% | 磁盘 ${disk_thr}%${PLAIN}"
            read -p "CPU 告警阈值 % [当前 ${cpu_thr:-90}]: " new_cpu
            read -p "内存告警阈值 % [当前 ${mem_thr:-90}]: " new_mem
            read -p "磁盘告警阈值 % [当前 ${disk_thr:-90}]: " new_disk
            read -p "入站带宽告警 MB/s [当前 ${net_in_thr:-0}, 0=不告警]: " new_net_in
            read -p "出站带宽告警 MB/s [当前 ${net_out_thr:-0}, 0=不告警]: " new_net_out
            read -p "CPU 持续超阈值多少秒后告警 [当前 ${cpu_intv:-60}s]: " new_cpu_intv
            read -p "内存持续超阈值多少秒后告警 [当前 ${mem_intv:-60}s]: " new_mem_intv
            read -p "磁盘持续超阈值多少秒后告警 [当前 ${disk_intv:-60}s]: " new_disk_intv

            [ -z "$new_cpu" ]       && new_cpu=${cpu_thr:-90}
            [ -z "$new_mem" ]       && new_mem=${mem_thr:-90}
            [ -z "$new_disk" ]      && new_disk=${disk_thr:-90}
            [ -z "$new_net_in" ]    && new_net_in=${net_in_thr:-0}
            [ -z "$new_net_out" ]   && new_net_out=${net_out_thr:-0}
            [ -z "$new_cpu_intv" ]  && new_cpu_intv=${cpu_intv:-60}
            [ -z "$new_mem_intv" ]  && new_mem_intv=${mem_intv:-60}
            [ -z "$new_disk_intv" ] && new_disk_intv=${disk_intv:-60}

            sed -i "s|^CPU_THRESHOLD     = .*|CPU_THRESHOLD     = ${new_cpu}|"          "$HEALTH_SCRIPT"
            sed -i "s|^MEM_THRESHOLD     = .*|MEM_THRESHOLD     = ${new_mem}|"          "$HEALTH_SCRIPT"
            sed -i "s|^DISK_THRESHOLD    = .*|DISK_THRESHOLD    = ${new_disk}|"         "$HEALTH_SCRIPT"
            sed -i "s|^NET_IN_THRESHOLD  = .*|NET_IN_THRESHOLD  = ${new_net_in}|"       "$HEALTH_SCRIPT"
            sed -i "s|^NET_OUT_THRESHOLD = .*|NET_OUT_THRESHOLD = ${new_net_out}|"      "$HEALTH_SCRIPT"
            sed -i "s|^CPU_INTERVAL      = .*|CPU_INTERVAL      = ${new_cpu_intv}|"     "$HEALTH_SCRIPT"
            sed -i "s|^MEM_INTERVAL      = .*|MEM_INTERVAL      = ${new_mem_intv}|"     "$HEALTH_SCRIPT"
            sed -i "s|^DISK_INTERVAL     = .*|DISK_INTERVAL     = ${new_disk_intv}|"    "$HEALTH_SCRIPT"
            sed -i "s|^RESOURCE_ALERT_ENABLED = .*|RESOURCE_ALERT_ENABLED = True|"     "$HEALTH_SCRIPT"
            echo -e "${GREEN}告警阈值已保存，资源告警已开启${PLAIN}"
            systemctl restart nezha-health 2>/dev/null
            sleep 1
            continue
            ;;
        3)
            if grep -q '^OFFLINE_ALERT_ENABLED   = True' "$HEALTH_SCRIPT"; then
                sed -i "s|^OFFLINE_ALERT_ENABLED   = .*|OFFLINE_ALERT_ENABLED   = False|" "$HEALTH_SCRIPT"
                echo -e "${YELLOW}离线告警已关闭${PLAIN}"
            else
                sed -i "s|^OFFLINE_ALERT_ENABLED   = .*|OFFLINE_ALERT_ENABLED   = True|" "$HEALTH_SCRIPT"
                echo -e "${GREEN}离线告警已开启${PLAIN}"
            fi
            systemctl restart nezha-health 2>/dev/null
            sleep 1
            continue
            ;;
        4)
            echo -e ""
            echo -e "${CYAN}正在运行一次检测...${PLAIN}"
            python3 "$HEALTH_SCRIPT" && echo -e "${GREEN}执行完成${PLAIN}" || echo -e "${RED}执行失败${PLAIN}"
            press_any_key
            ;;
        5)
            systemctl disable --now nezha-health 2>/dev/null
            echo -e "${YELLOW}守护进程已停止${PLAIN}"
            sleep 1
            continue
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            sleep 1
            continue
            ;;
    esac
    done
}

deploy_notify_script() {
    cat > "$NOTIFY_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import base64
import json
import os
import socket
import sqlite3
import struct
import urllib.request
from datetime import datetime, timezone, timedelta

# ============ 配置 ============
DB_PATH      = "/opt/nezha/data/sqlite.db"
STATE_PATH   = "/opt/nezha/notify_state.json"
TG_BOT_TOKEN = "请填写"
TG_CHAT_ID   = "请填写"
# ==============================

CST = timezone(timedelta(hours=8))

# 各剩余天数对应的推送间隔（小时），推送窗口为 09:00-23:00 CST
INTERVAL = {0: 1, 1: 2, 2: 3, 3: 4}

COUNTRY_CODES = {
    'AD','AE','AF','AG','AL','AM','AO','AR','AT','AU','AZ','BA','BB','BD','BE',
    'BF','BG','BH','BI','BJ','BN','BO','BR','BS','BT','BW','BY','BZ','CA','CD',
    'CF','CG','CH','CI','CL','CM','CN','CO','CR','CU','CV','CY','CZ','DE','DJ',
    'DK','DM','DO','DZ','EC','EE','EG','ER','ES','ET','FI','FJ','FM','FR','GA',
    'GB','GD','GE','GH','GM','GN','GQ','GR','GT','GW','GY','HK','HN','HR','HT',
    'HU','ID','IE','IL','IN','IQ','IR','IS','IT','JM','JO','JP','KE','KG','KH',
    'KI','KM','KN','KP','KR','KW','KY','KZ','LA','LB','LC','LI','LK','LR','LS',
    'LT','LU','LV','LY','MA','MC','MD','ME','MG','MK','ML','MM','MN','MO','MR',
    'MT','MU','MV','MW','MX','MY','MZ','NA','NE','NG','NI','NL','NO','NP','NR',
    'NZ','OM','PA','PE','PG','PH','PK','PL','PT','PW','PY','QA','RO','RS','RU',
    'RW','SA','SB','SC','SD','SE','SG','SI','SK','SL','SM','SN','SO','SR','SS',
    'ST','SV','SY','SZ','TD','TG','TH','TJ','TL','TM','TN','TO','TR','TT','TV',
    'TW','TZ','UA','UG','US','UY','UZ','VA','VC','VE','VN','VU','WS','YE','ZA',
    'ZM','ZW',
}


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    try:
        with open(STATE_PATH, "w") as f:
            json.dump(state, f, ensure_ascii=False)
    except Exception:
        pass


def get_api_ccs():
    """从 Nezha WebSocket API 获取 name→country_code 映射，失败返回空字典。"""
    try:
        s = socket.create_connection(("127.0.0.1", 8008), timeout=5)
        try:
            key = base64.b64encode(os.urandom(16)).decode()
            s.sendall((
                "GET /api/v1/ws/server HTTP/1.1\r\n"
                "Host: 127.0.0.1:8008\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "Origin: http://127.0.0.1:8008\r\n\r\n"
            ).encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                buf += s.recv(4096)
            rest = buf.split(b"\r\n\r\n", 1)[1]
            for _ in range(10):
                while len(rest) < 2:
                    rest += s.recv(4096)
                opcode = rest[0] & 0x0F
                plen = rest[1] & 0x7F
                off = 2
                if plen == 126:
                    while len(rest) < off + 2: rest += s.recv(4096)
                    plen = struct.unpack(">H", rest[off:off+2])[0]; off += 2
                elif plen == 127:
                    while len(rest) < off + 8: rest += s.recv(4096)
                    plen = struct.unpack(">Q", rest[off:off+8])[0]; off += 8
                while len(rest) < off + plen:
                    rest += s.recv(65536)
                payload, rest = rest[off:off+plen], rest[off+plen:]
                if opcode == 1:
                    data = json.loads(payload.decode())
                    return {srv["name"]: srv.get("country_code", "")
                            for srv in data.get("servers", [])}
        finally:
            s.close()
    except Exception:
        pass
    return {}


def should_notify(days_left, hour, minute=0):
    """推送窗口 09:00-23:59 CST；仅用于 days_left >= 0 的服务器"""
    if hour == 23 and days_left == 0:
        return minute % 10 == 0
    if not (9 <= hour <= 23):
        return False
    if minute != 0:
        return False
    key = days_left if days_left in INTERVAL else None
    if key is not None:
        return (hour - 9) % INTERVAL[key] == 0
    if 4 <= days_left <= 7:
        return hour == 9
    return False


def fetch_servers():
    api_ccs = get_api_ccs()

    conn = sqlite3.connect(DB_PATH, timeout=10)
    try:
        try:
            rows = conn.execute("SELECT id, name, country_code, public_note FROM servers").fetchall()
            has_cc = True
        except Exception:
            rows = conn.execute("SELECT id, name, public_note FROM servers").fetchall()
            has_cc = False
    finally:
        conn.close()

    with_date = []
    permanent = []
    not_set   = []
    for row in rows:
        sid          = row[0]
        name         = row[1]
        country_code = row[2] if has_cc else ""
        note         = row[3] if has_cc else row[2]
        country_code = api_ccs.get(name) or country_code or ""
        try:
            end_date_str = json.loads(note or "{}")["billingDataMod"]["endDate"]
            end_date_str = end_date_str.replace("Z", "+00:00")
            exp_dt = datetime.fromisoformat(end_date_str).astimezone(CST)
            with_date.append((sid, name, country_code, exp_dt))
        except (KeyError, ValueError, TypeError, AttributeError):
            try:
                billing = json.loads(note or "{}").get("billingDataMod")
                if billing is not None:
                    permanent.append((name, country_code))
                else:
                    not_set.append((sid, name, country_code))
            except Exception:
                not_set.append((sid, name, country_code))
    return with_date, permanent, not_set


def _panel_url():
    try:
        seen = False
        with open("/etc/nginx/nginx.conf") as f:
            for ln in f:
                if "listen 443" in ln:
                    seen = True
                if seen and "server_name" in ln:
                    d = ln.split("server_name", 1)[1].strip().rstrip(";").split()[0]
                    if d and d != "_":
                        return "https://" + d
                    seen = False
    except Exception:
        pass
    return ""


PANEL_URL = _panel_url()


def _flag(cc):
    cc = (cc or "").upper()
    if len(cc) == 2 and cc in COUNTRY_CODES:
        return chr(0x1F1E6 + ord(cc[0]) - 65) + chr(0x1F1E6 + ord(cc[1]) - 65)
    return ""


def send_tg(message, sbtns=None):
    # sbtns: [(emoji, id, name, cc)]，每个生成一个 askdate 按钮(bot 私聊引导设日期)，每行2个，最多20个
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    body = {"chat_id": TG_CHAT_ID, "text": message, "parse_mode": "HTML"}
    rows = []
    if sbtns:
        rb = [{"text": f"{e} {_flag(cc)}{nm}".strip(), "callback_data": f"askdate:{sid}"}
              for e, sid, nm, cc in sbtns[:20]]
        rows = [rb[i:i + 2] for i in range(0, len(rb), 2)]
    if PANEL_URL:
        rows.append([{"text": "👉 进入面板", "url": PANEL_URL}])
    if rows:
        body["reply_markup"] = {"inline_keyboard": rows}
    payload = json.dumps(body).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        result = json.loads(resp.read())
    if not result.get("ok"):
        raise RuntimeError(f"TG send failed: {result}")


def main():
    import sys
    show_all = "--all" in sys.argv

    now_cst   = datetime.now(CST)
    hour      = now_cst.hour
    minute    = now_cst.minute
    today     = now_cst.date()
    now_ts    = now_cst.timestamp()

    first_run          = not os.path.exists(STATE_PATH)
    state              = load_state()
    first_seen         = state.get("first_seen", {})
    last_expiry        = state.get("last_expiry", {})
    new_server_notified = set(state.get("new_server_notified", []))
    change_push_ts     = state.get("change_push_ts", {})

    with_date, permanent, not_set = fetch_servers()

    dated          = []   # (days_left, line)，最后按 days_left 升序：已过期/快到期在最前
    renew_btns     = []   # (id, name, cc)：给到期/将到期(<=7天)的服务器挂续期按钮
    immediate_msgs = []

    def make_label(cc_raw, name):
        cc = (cc_raw or "").upper()
        if cc and len(cc) == 2 and cc in COUNTRY_CODES:
            flag = chr(0x1F1E6 + ord(cc[0]) - 65) + chr(0x1F1E6 + ord(cc[1]) - 65)
        else:
            flag = ""
        return f"{flag + ' ' if flag else ''}<b>#{name}</b>"

    for sid, name, country_code, exp_dt in with_date:
        days_left = (exp_dt.date() - today).days
        date_str  = exp_dt.strftime("%Y-%m-%d")
        label     = make_label(country_code, name)

        # 到期日变更立即推送（仅定时任务模式，非首次运行且记录过旧日期，60秒冷却）
        if not show_all:
            if not first_run and name in last_expiry and last_expiry[name] != date_str:
                last_push = change_push_ts.get(name, 0)
                if now_ts - last_push >= 60:
                    old = last_expiry[name]
                    try:
                        old_days = (datetime.fromisoformat(old + "T00:00:00+08:00").date() - today).days
                        old_info = "已过期" if old_days < 0 else f"剩余 {old_days} 天"
                    except Exception:
                        old_info = old
                    new_info = "已过期" if days_left < 0 else f"剩余 {days_left} 天"
                    immediate_msgs.append(
                        f"🔄 <b>到期日期已更新</b>\n\n"
                        f"{label}\n"
                        f"└ 旧: <s>{old}</s>（{old_info}）\n"
                        f"└ 新: <b>{date_str}（{new_info}）</b>"
                    )
                    change_push_ts[name] = now_ts
                    last_expiry[name] = date_str  # 冷却期推送后才更新
                # 冷却期间不更新 last_expiry，保留旧值以便冷却后再次检测
            else:
                last_expiry[name] = date_str


        # 文案
        if days_left < 0:
            line = f"{label}\n└ ⚫ <b>已过期 · {date_str}</b>"
        elif days_left == 0:
            line = f"{label}\n└ 🔴 <b>今天到期！· {date_str}</b>"
        elif days_left <= 3:
            line = f"{label}\n└ 🟡 <b>剩余 {days_left} 天 · {date_str}</b>"
        elif days_left <= 7:
            line = f"{label}\n└ 🟣 <b>剩余 {days_left} 天 · {date_str}</b>"
        else:
            line = f"{label}\n└ 🟢 <b>剩余 {days_left} 天 · {date_str}</b>"

        # 是否展示：--all 全展示；定时模式按原推送窗口规则
        if show_all:
            show = True
        elif days_left < 0:
            show = (minute == 0)          # 已过期全天整点推
        else:
            show = should_notify(days_left, hour, minute)
        if show:
            dated.append((days_left, line))
            if days_left <= 7:   # 仅给"本次真正显示"的到期/将到期(<=7天)挂续期按钮，避免按钮与正文不一致
                renew_btns.append((sid, name, country_code))

    # 未设置到期日：发现10分钟后仍未设置则推送一次
    new_servers = []
    for sid, name, cc in not_set:
        if first_run:
            # 首次运行：静默记录所有现有服务器，不触发推送
            first_seen[name] = now_ts
            new_server_notified.add(name)
        else:
            if name not in first_seen:
                first_seen[name] = now_ts
            if not show_all and name not in new_server_notified:
                seen_val = first_seen[name]
                if isinstance(seen_val, str):
                    try:
                        seen_ts = datetime.fromisoformat(seen_val).timestamp()
                    except Exception:
                        seen_ts = now_ts
                    first_seen[name] = seen_ts
                else:
                    seen_ts = seen_val
                if now_ts - seen_ts >= 600:
                    new_servers.append((name, cc))
                    new_server_notified.add(name)

    if new_servers:
        lines = "\n\n".join(
            f"{make_label(cc, name)}\n└ 🚨 <b>请设置到期日期</b>"
            for name, cc in new_servers
        )
        immediate_msgs.append(f"🆕 <b>新服务器已添加</b>\n\n{lines}")

    # 每天 9:00 / 14:00 / 21:00 推送未设置的
    alert_not_set = not_set if (show_all or (minute == 0 and hour in (9, 14, 21))) else []

    # 先发即时消息
    for msg in immediate_msgs:
        try:
            send_tg(msg)
        except Exception as e:
            print(f"即时推送失败: {e}")

    # 仅定时任务模式保存状态（--all 不写状态，避免覆盖变更记录）
    if not show_all:
        state["first_seen"]          = first_seen
        state["last_expiry"]         = last_expiry
        state["new_server_notified"] = list(new_server_notified)
        state["change_push_ts"]      = change_push_ts
        save_state(state)

    if not dated and not (show_all and permanent) and not alert_not_set:
        if immediate_msgs:
            print(f"已发送 {len(immediate_msgs)} 条即时通知")
        return

    dated.sort(key=lambda x: x[0])     # 升序：已过期(负数)最前，越快到期越靠前
    sections = [line for _, line in dated]
    if show_all:
        for name, cc in permanent:
            sections.append(f"{make_label(cc, name)}\n└ 🔵 <b>永久</b>")
    title    = "📋 <b>服务器到期状态总览</b>" if show_all else "⚠️ <b>服务器到期提醒</b>"
    not_set_block = ("🚨 <b>未设置到期日</b>\n" + "\n".join(
        f"  · {make_label(cc, name)}" for sid, name, cc in alert_not_set
    )) if alert_not_set else ""
    if sections:
        msg = f"{title}\n\n" + "\n\n".join(sections)
        if not_set_block:
            msg += "\n\n" + not_set_block
    else:
        msg = f"{title}\n\n{not_set_block}"

    # 仅给到期/将到期(≤7天)的服务器挂续期按钮(🔄)，点了私聊设日期
    sbtns = [("🔄", sid, nm, cc) for sid, nm, cc in renew_btns]
    sbtns += [("📅", sid, nm, cc) for sid, nm, cc in alert_not_set]   # 未设置的挂"设日期"按钮，与正文一致
    send_tg(msg, sbtns=sbtns)
    print(f"已发送：{len(dated)} 条到期项，{len(alert_not_set)} 未设日期，{len(immediate_msgs)} 即时通知")


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$NOTIFY_SCRIPT"
}

manage_notify() {
    # 首次使用时部署脚本
    if [ ! -f "$NOTIFY_SCRIPT" ]; then
        deploy_notify_script
    fi

    while true; do
    clear
    # 读取当前配置
    local cur_token cur_chatid cron_status
    cur_token=$(grep 'TG_BOT_TOKEN' "$NOTIFY_SCRIPT" | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
    cur_chatid=$(grep 'TG_CHAT_ID'  "$NOTIFY_SCRIPT" | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
    if systemctl is-active --quiet nezha-notify.timer 2>/dev/null; then
        cron_status="${GREEN}已启用${PLAIN}"
    else
        cron_status="${RED}未启用${PLAIN}"
    fi

    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║${PLAIN}${BLUE}              到期通知管理 (Telegram Bot)              ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  Bot Token  : ${cur_token:0:20}...                    ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  Chat ID    : ${cur_chatid}                                  ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  定时任务   : ${cron_status}                                 ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   1.  配置到期推送                                    ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   2.  立即测试发送                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   3.  关闭定时通知                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   0.  返回主菜单                                     ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}"
    read -p " 请输入选项: " nchoice

    case "$nchoice" in
        1)
            echo -e ""
            echo -e "${CYAN}请粘贴 Bot Token 和 Chat ID（同行或换行均可，空行结束）:${PLAIN}"
            local raw_input="" _line
            while IFS= read -r _line; do
                [[ -z "$_line" ]] && break
                raw_input="$raw_input $_line"
            done
            new_token=$(echo "$raw_input" | grep -oE '[0-9]+:[A-Za-z0-9_-]+' | head -1)
            new_chatid=$(echo "${raw_input//$new_token/}" | grep -oE '\-?[0-9]{7,}' | head -1)

            if [ -z "$new_token" ] || [ -z "$new_chatid" ]; then
                echo -e "${RED}未能识别 Token 或 Chat ID，请检查格式${PLAIN}"
                sleep 2
                continue
            fi

            # 重新部署最新脚本，再写入配置
            deploy_notify_script
            sed -i "s|^TG_BOT_TOKEN = .*|TG_BOT_TOKEN = \"${new_token}\"|" "$NOTIFY_SCRIPT"
            sed -i "s|^TG_CHAT_ID   = .*|TG_CHAT_ID   = \"${new_chatid}\"|" "$NOTIFY_SCRIPT"
            echo -e "${GREEN}配置已保存${PLAIN}"

            # 部署 systemd timer（按 Asia/Shanghai 时区触发）
            cat > /etc/systemd/system/nezha-notify.service << 'SVCEOF'
[Unit]
Description=Nezha VPS Expiry Notification

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/nezha/nezha_notify.py
StandardOutput=append:/var/log/nezha_notify.log
StandardError=append:/var/log/nezha_notify.log
SVCEOF
            cat > /etc/systemd/system/nezha-notify.timer << 'TMREOF'
[Unit]
Description=Nezha VPS Expiry Notification Timer

[Timer]
OnCalendar=*-*-* *:*:00 Asia/Shanghai
AccuracySec=10s

[Install]
WantedBy=timers.target
TMREOF
            systemctl daemon-reload
            systemctl enable --now nezha-notify.timer
            # 清理旧 cron 条目（如有）
            ( crontab -l 2>/dev/null | grep -v "nezha_notify.py" | grep -v "^TZ=Asia/Shanghai" ) | crontab -
            echo -e "${GREEN}定时任务已启用 (每分钟检测变更，整点推送到期提醒，北京时间)${PLAIN}"

            # 立即推送全部服务器当前到期状态
            echo -e "${CYAN}正在推送全部服务器到期状态...${PLAIN}"
            python3 "$NOTIFY_SCRIPT" --all && echo -e "${GREEN}推送完成${PLAIN}" || echo -e "${RED}推送失败，请检查 Token / Chat ID${PLAIN}"
            sleep 2
            continue
            ;;
        2)
            echo -e ""
            echo -e "${CYAN}正在运行通知脚本...${PLAIN}"
            python3 "$NOTIFY_SCRIPT" && echo -e "${GREEN}执行完成（无到期服务器则无输出）${PLAIN}" || echo -e "${RED}执行失败，请检查配置${PLAIN}"
            press_any_key
            ;;
        3)
            systemctl disable --now nezha-notify.timer 2>/dev/null
            echo -e "${YELLOW}定时任务已关闭${PLAIN}"
            sleep 1
            continue
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            sleep 1
            continue
            ;;
    esac
    done
}

# ==============================================================
# 模块 12: 新版本检测推送 (复用健康告警的 Telegram 配置)
# ==============================================================
UPGRADE_SCRIPT="/opt/nezha/nezha_upgrade.sh"

# ==============================================================
# 模块: TG 管理 Bot（getUpdates 长轮询 / 内联按钮 / 到期管理；统一归口处理"立即更新"按钮）
# 安全：bot 用读写 PAT(inventory:read+server:write+service:write，无 delete/exec)；
#       常驻只读 PAT 见 ensure_health_pat；exec/fs/MCP 一律不开（见文件顶注释）。
# ==============================================================
deploy_bot_script() {
    cat > "$BOT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
# 哪吒 TG 管理 bot - getUpdates 长轮询 / 消息内联按钮 / 到期·续期管理
# 统一归口：本 bot 是该 TG token 唯一的 getUpdates 消费者（含"立即更新"按钮）
# 安全：只读写数据层(server/service write)，绝不 exec/fs；last_used_ip 非本机即自动吊销
import json, time, os, sqlite3, subprocess, re, urllib.request, urllib.parse, urllib.error
from datetime import datetime, timezone, timedelta

# ============ 配置（部署时 sed 填 TG_BOT_TOKEN）============
TG_BOT_TOKEN    = "请填写"
NEZHA_HOST      = "127.0.0.1"
NEZHA_PORT      = 8008
DB_PATH         = "/opt/nezha/data/sqlite.db"
PAT_FILE        = "/opt/nezha/.nezha_bot_pat"
STATE_FILE      = "/opt/nezha/nezha_bot_state.json"
UPGRADE_TRIGGER = "/opt/nezha/.upgrade_now"   # 收到"立即更新"回调即 touch，upgrade 脚本监听
VERSION_FILE    = "/opt/nezha/version"        # 当前面板版本(检查更新用)
TOKEN_NAME      = "nezha-mgr-bot"
PAGE_SIZE       = 15
OFFLINE_SECS    = 30
# =========================================================

CST = timezone(timedelta(hours=8))
COUNTRY_CODES = {
    'AD','AE','AF','AG','AL','AM','AO','AR','AT','AU','AZ','BA','BB','BD','BE',
    'BF','BG','BH','BI','BJ','BN','BO','BR','BS','BT','BW','BY','BZ','CA','CD',
    'CF','CG','CH','CI','CL','CM','CN','CO','CR','CU','CV','CY','CZ','DE','DJ',
    'DK','DM','DO','DZ','EC','EE','EG','ER','ES','ET','FI','FJ','FM','FR','GA',
    'GB','GD','GE','GH','GM','GN','GQ','GR','GT','GW','GY','HK','HN','HR','HT',
    'HU','ID','IE','IL','IN','IQ','IR','IS','IT','JM','JO','JP','KE','KG','KH',
    'KI','KM','KN','KP','KR','KW','KY','KZ','LA','LB','LC','LI','LK','LR','LS',
    'LT','LU','LV','LY','MA','MC','MD','ME','MG','MK','ML','MM','MN','MO','MR',
    'MT','MU','MV','MW','MX','MY','MZ','NA','NE','NG','NI','NL','NO','NP','NR',
    'NZ','OM','PA','PE','PG','PH','PK','PL','PT','PW','PY','QA','RO','RS','RU',
    'RW','SA','SB','SC','SD','SE','SG','SI','SK','SL','SM','SN','SO','SR','SS',
    'ST','SV','SY','SZ','TD','TG','TH','TJ','TL','TM','TN','TO','TR','TT','TV',
    'TW','TZ','UA','UG','US','UY','UZ','VA','VC','VE','VN','VU','WS','YE','ZA',
    'ZM','ZW',
}


def flag(cc):
    cc = (cc or "").upper()
    if len(cc) == 2 and cc in COUNTRY_CODES:
        return chr(0x1F1E6 + ord(cc[0]) - 65) + chr(0x1F1E6 + ord(cc[1]) - 65)
    return ""


# ---------- 状态持久化 ----------
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(s):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(s, f, ensure_ascii=False)
    except Exception:
        pass


# ---------- 面板 API（带读写 PAT）----------
def read_pat():
    with open(PAT_FILE) as f:
        return f.read().strip()


def nezha(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "http://%s:%s/api/v1%s" % (NEZHA_HOST, NEZHA_PORT, path),
        data=data, method=method,
        headers={"Authorization": "Bearer " + read_pat(),
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def get_servers():
    return nezha("GET", "/server").get("data") or []


def get_server(sid):
    for s in get_servers():
        if s.get("id") == sid:
            return s
    return None


# ---------- Telegram API ----------
def tg(method, **params):
    body = {k: (json.dumps(v) if isinstance(v, (dict, list)) else v)
            for k, v in params.items()}
    data = urllib.parse.urlencode(body).encode()
    try:
        with urllib.request.urlopen(
                "https://api.telegram.org/bot%s/%s" % (TG_BOT_TOKEN, method),
                data=data, timeout=70) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print("tg http err %s: %s" % (e.code, e.read().decode()[:120]))
    except Exception as e:
        print("tg err:", e)
    return {}


def kb(rows):
    return {"inline_keyboard": rows}


def btn(text, data):
    return {"text": text, "callback_data": data}


# ---------- 到期解析 / 计算 ----------
def parse_expiry(srv):
    """return (kind, date|None). kind: 'date'|'permanent'|'none'"""
    try:
        note = json.loads(srv.get("public_note") or "{}")
        bd = note.get("billingDataMod")
        if bd is None:
            return ("none", None)
        end = bd.get("endDate")
        if not end:
            return ("permanent", None)
        dt = datetime.fromisoformat(end.replace("Z", "+00:00")).astimezone(CST)
        if dt.year <= 1:
            return ("permanent", None)
        return ("date", dt.date())
    except Exception:
        return ("none", None)


def expiry_text(srv):
    kind, d = parse_expiry(srv)
    if kind == "permanent":
        return "永久"
    if kind == "none":
        return "未设置"
    today = datetime.now(CST).date()
    dl = (d - today).days
    s = d.strftime("%Y-%m-%d")
    if dl < 0:
        return "已过期 %s" % s
    if dl == 0:
        return "今天到期 %s" % s
    return "%s（剩%d天）" % (s, dl)


def set_expiry(sid, date_obj):
    """⚠️ PATCH /server 是整体替换（漏传字段会被清零）！
    故从 DB 读全量可写字段 → 只改 public_note.endDate(归一中午12:00) → 带完整 ServerForm PATCH。"""
    c = sqlite3.connect(DB_PATH, timeout=10)
    row = c.execute(
        "SELECT name,note,public_note,display_index,hide_for_guest,enable_d_dns,"
        "ddns_profiles_raw,override_ddns_domains_raw FROM servers WHERE id=?",
        (sid,)).fetchone()
    if not row:
        raise RuntimeError("服务器不存在")
    name, note, pub, di, hide, enddns, ddnsp, ovr = row
    pj = json.loads(pub or "{}")
    bd = pj.get("billingDataMod")
    if not isinstance(bd, dict):
        bd = {}
    bd["endDate"] = date_obj.strftime("%Y-%m-%dT12:00:00+08:00")
    pj["billingDataMod"] = bd
    form = {
        "name": name or "",
        "display_index": di or 0,
        "note": note or "",
        "public_note": json.dumps(pj, ensure_ascii=False),
        "hide_for_guest": bool(hide),
        "enable_ddns": bool(enddns),
        "ddns_profiles": json.loads(ddnsp or "[]"),
        "override_ddns_domains": json.loads(ovr or "{}"),
    }
    nezha("PATCH", "/server/%d" % sid, form)


def normalize_expiry():
    """把所有 endDate 归一到当天 12:00(CST 中午)。Nezha 前端按剩余小时四舍五入(round)显示天数，
    endDate 设在中午时 round 的整数跳变点正好落在午夜→面板天数白天稳定、午夜才减一，且与日历天/TG通知一致。
    (设 00:00 或 23:59:59 都会导致中午掉一天。)只改时间、保留日期与其它字段；已是 12:00 的跳过。"""
    n = 0
    for s in get_servers():
        try:
            end = (json.loads(s.get("public_note") or "{}").get("billingDataMod") or {}).get("endDate")
            if not end or end.startswith("0000"):
                continue
            dt = datetime.fromisoformat(end.replace("Z", "+00:00")).astimezone(CST)
            if dt.year <= 1 or (dt.hour, dt.minute, dt.second) == (12, 0, 0):
                continue
        except Exception:
            continue   # 无法解析/未设置的到期值，静默跳过
        try:
            set_expiry(s["id"], dt.date())   # 写成该 CST 日期的 12:00
            n += 1
            print("归一到期日: %s -> %s 12:00" % (s.get("name"), dt.date()))
        except Exception as e:
            print("归一异常 %s: %s" % (s.get("name"), e))
    return n


# ---------- 视图渲染 ----------
def label(srv):
    f = flag((srv.get("geoip") or {}).get("country_code"))
    return ("%s " % f if f else "") + "#" + srv.get("name", "?")


def view_main():
    # 每个功能一个入口；后续新功能在此加一行按钮即可
    return ("🛰 <b>Nezha 管理</b>\n选择功能：",
            kb([[btn("📊 状态概览", "status")],
                [btn("📅 设置到期日", "setdate:0")],
                [btn("🔄 检查更新", "checkupd")]]))


def check_versions():
    # 返回 (当前版本, GitHub最新版)；任一获取失败对应项为 ""
    cur = ""
    try:
        cur = open(VERSION_FILE).read().strip()
    except Exception:
        pass
    latest = ""
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/nezhahq/nezha/releases/latest",
            headers={"User-Agent": "nezha-bot"})
        with urllib.request.urlopen(req, timeout=15) as r:
            latest = (json.load(r).get("tag_name") or "").strip()
    except Exception as e:
        print("check_versions err:", e)
    return cur, latest


def view_status():
    servers = get_servers()
    now = time.time()
    rows = []
    online = 0
    for s in servers:
        la = s.get("last_active", "")
        try:
            ts = datetime.fromisoformat(la.replace("Z", "+00:00")).timestamp()
        except Exception:
            ts = 0
        on = bool(ts) and (now - ts) < OFFLINE_SECS
        if on:
            online += 1
        rows.append((on, s))
    # 离线优先置顶，其余按名字
    rows.sort(key=lambda r: (r[0], r[1].get("name", "")))
    lines = ["🟢%s" % label(s) if on else "🔴%s  离线" % label(s) for on, s in rows]
    txt = "📊 <b>状态概览</b>  在线 %d/%d\n" % (online, len(servers)) + "\n".join(lines)
    return (txt, kb([[btn("🔄 刷新", "status")], [btn("⬅️ 返回", "home")]]))


def list_sortkey(s):
    """快到期/已过期在前；未设置其次；永久最后"""
    kind, d = parse_expiry(s)
    if kind == "date":
        return (0, (d - datetime.now(CST).date()).days)
    if kind == "none":
        return (1, 0)
    return (2, 0)


def view_list(page):
    """返回 (text, markup, ordered_ids)。编号全局连续，用户回复编号选择，规模再大也不爆按钮。"""
    servers = get_servers()
    servers.sort(key=list_sortkey)
    ordered = [s["id"] for s in servers]
    pages = max(1, (len(servers) + PAGE_SIZE - 1) // PAGE_SIZE)
    page = max(0, min(page, pages - 1))
    start = page * PAGE_SIZE
    lines = ["📅 <b>设置到期日</b>（%d/%d）· 已按到期排序\n回复<b>编号</b>选择要设置的服务器：" % (page + 1, pages)]
    for i, s in enumerate(servers[start:start + PAGE_SIZE], start + 1):
        lines.append("%2d. %s  %s" % (i, label(s), expiry_text(s)))
    nav = [btn("⬅️ 返回", "home")]
    if page > 0:
        nav.insert(0, btn("◀ 上一页", "setdate:%d" % (page - 1)))
    if page < pages - 1:
        nav.append(btn("下一页 ▶", "setdate:%d" % (page + 1)))
    return ("\n".join(lines), kb([nav]), ordered)


# ---------- 编辑/发送 ----------
def edit(chat_id, mid, text, markup):
    tg("editMessageText", chat_id=chat_id, message_id=mid,
       text=text, parse_mode="HTML", reply_markup=markup)


def send(chat_id, text, markup=None):
    p = dict(chat_id=chat_id, text=text, parse_mode="HTML")
    if markup:
        p["reply_markup"] = markup
    tg("sendMessage", **p)


# ---------- 安全：last_used_ip 防泄漏 ----------
LOCAL_IPS = {"127.0.0.1", "::1", "::ffff:127.0.0.1", ""}


def leak_guard(state):
    """token 若被本机以外 IP 使用过，立即吊销 + 告警"""
    try:
        c = sqlite3.connect(DB_PATH, timeout=5)
        row = c.execute("SELECT last_used_ip FROM api_tokens WHERE name=?",
                        (TOKEN_NAME,)).fetchone()
        if row and row[0] and row[0].split(":")[0] not in ("127", "") and row[0] not in LOCAL_IPS:
            ip = row[0]
            c.execute("DELETE FROM api_tokens WHERE name=?", (TOKEN_NAME,))
            c.commit()
            owner = state.get("owner_id")
            if owner:
                send(owner, "🚨 <b>检测到 bot token 异地使用</b>\n来源 IP：<code>%s</code>\n已自动吊销该 token，bot 暂停。请重新生成。" % ip)
            print("LEAK: token used from %s, revoked, exiting" % ip)
            return False
    except Exception as e:
        print("leak_guard err:", e)
    return True


# ---------- 更新处理 ----------
def handle_message(msg, state):
    chat = msg["chat"]["id"]
    uid = msg.get("from", {}).get("id")
    text = (msg.get("text") or "").strip()

    # owner 认领：第一个 /start 的人成为 owner
    if state.get("owner_id") is None and text.startswith("/start"):
        state["owner_id"] = uid
        save_state(state)
    owner = state.get("owner_id")
    if owner is not None and uid != owner:
        return  # 非主人，静默忽略
    if owner is None:
        return

    if text.startswith("/start") or text.startswith("/menu"):
        state.get("pending", {}).pop(str(chat), None)
        t, m = view_main()
        send(chat, t, m)
        return

    pend = state.get("pending", {}).get(str(chat))
    # 待输入：列表回复编号选服务器
    if pend and pend.get("action") == "pick":
        if text.isdigit():
            n = int(text)
            order = state.get("list_order", {}).get(str(chat), [])
            if 1 <= n <= len(order):
                sid = order[n - 1]
                s = get_server(sid)
                state["pending"][str(chat)] = {"action": "setexp", "sid": sid}
                save_state(state)
                send(chat, "⏰ 给 <b>%s</b> 设到期日（当前：%s）\n回复新日期：<code>YYYY-MM-DD</code>（例 2026-08-01）" % (
                    label(s), expiry_text(s)))
                return
        send(chat, "⚠️ 请回复列表中的<b>编号</b>（数字）")
        return
    # 待输入：设到期日
    if pend and pend.get("action") == "setexp":
        try:
            d = datetime.strptime(text, "%Y-%m-%d").date()
        except ValueError:
            send(chat, "⚠️ 日期格式不对，请回复 YYYY-MM-DD（例 2026-08-01）")
            return
        sid = pend["sid"]
        s = get_server(sid)
        state["pending"].pop(str(chat), None)
        save_state(state)
        if not s:
            send(chat, "⚠️ 找不到该服务器")
            return
        send(chat, "⚠️ <b>确认修改</b>\n%s 到期：%s → <b>%s</b>" % (
            label(s), expiry_text(s), d.strftime("%Y-%m-%d")),
            kb([[btn("✅ 确认", "doexp:%d:%s" % (sid, d.strftime("%Y-%m-%d"))),
                 btn("❌ 取消", "cancel")]]))
        return


def handle_callback(cq, state):
    cid = cq["id"]
    uid = cq.get("from", {}).get("id")
    msg = cq.get("message") or {}
    chat = msg.get("chat", {}).get("id")
    mid = msg.get("message_id")
    data = cq.get("data") or ""

    owner = state.get("owner_id")
    if owner is None:
        tg("answerCallbackQuery", callback_query_id=cid, text="请先私聊 bot 发送 /start", show_alert=True)
        return
    if uid != owner:
        tg("answerCallbackQuery", callback_query_id=cid, text="⛔ 无权限", show_alert=True)
        return
    if not data.startswith("askdate:"):
        tg("answerCallbackQuery", callback_query_id=cid)

    try:
        if data == "home":
            edit(chat, mid, *view_main())
        elif data == "status":
            edit(chat, mid, *view_status())
        elif data.startswith("setdate:"):
            t, m, order = view_list(int(data.split(":")[1]))
            state.setdefault("list_order", {})[str(chat)] = order
            state.setdefault("pending", {})[str(chat)] = {"action": "pick"}
            save_state(state)
            edit(chat, mid, t, m)
        elif data == "cancel":
            edit(chat, mid, "❌ 已取消", kb([[btn("🏠 主菜单", "home")]]))
        elif data.startswith("doexp:"):
            _, sid, ds = data.split(":")
            sid = int(sid)
            set_expiry(sid, datetime.strptime(ds, "%Y-%m-%d").date())
            s2 = get_server(sid)
            edit(chat, mid, "✅ <b>设置成功</b>\n%s 到期：%s" % (label(s2), expiry_text(s2)),
                 kb([[btn("📅 再设一个", "setdate:0"), btn("🏠 主菜单", "home")]]))
        elif data.startswith("askdate:"):
            # 来自到期推送的续期按钮：不动频道原消息（保留其它服务器按钮），
            # 改为私聊 owner 引导手动输入日期，可连续点多台
            sid = int(data.split(":")[1])
            s = get_server(sid)
            if not s:
                tg("answerCallbackQuery", callback_query_id=cid, text="找不到该服务器", show_alert=True)
                return
            tg("answerCallbackQuery", callback_query_id=cid,
               text="已私聊你，请在私聊里回复日期", show_alert=True)
            state.setdefault("pending", {})[str(owner)] = {"action": "setexp", "sid": sid}
            save_state(state)
            send(owner, "⏰ 给 <b>%s</b> 设到期日（当前：%s）\n回复新日期：<code>YYYY-MM-DD</code>（例 2026-08-01）" % (
                label(s), expiry_text(s)))
        elif data == "update_now":
            open(UPGRADE_TRIGGER, "w").close()
            edit(chat, mid, "⚡ 收到，开始更新…", kb([]))
        elif data == "checkupd":
            cur, latest = check_versions()
            if not latest:
                edit(chat, mid, "⚠️ 获取最新版本失败，请稍后再试", kb([[btn("🏠 主菜单", "home")]]))
            elif cur == latest:
                edit(chat, mid, "✅ 已是最新版 <b>%s</b>" % cur, kb([[btn("🏠 主菜单", "home")]]))
            else:
                edit(chat, mid, "🆕 发现新版 <b>%s</b>（当前 %s）\n升级会重启面板约1分钟，失败自动回滚。" % (latest, cur or "未知"),
                     kb([[btn("⚡ 立即升级到 %s" % latest, "doupd:%s" % latest)], [btn("🏠 主菜单", "home")]]))
        elif data.startswith("doupd:"):
            tag = data.split(":", 1)[1]
            if not re.match(r"^v?[0-9][0-9A-Za-z.\-]*$", tag):
                edit(chat, mid, "⚠️ 版本号格式异常，已取消", kb([[btn("🏠 主菜单", "home")]]))
            else:
                edit(chat, mid, "⏳ 正在升级到 <b>%s</b>…（约1分钟，完成后单独推送结果）" % tag, kb([]))
                subprocess.Popen(["/bin/bash", "/opt/nezha/nezha_upgrade.sh", "apply", tag])
        elif data.startswith("rollback:"):
            tag = data.split(":", 1)[1]
            edit(chat, mid, "⚠️ <b>确认回退到 %s？</b>\n面板会重启约1分钟；该版本若起不来会自动恢复。跨大版本可能有数据库兼容风险。" % tag,
                 kb([[btn("✅ 确认回退", "dorb:%s" % tag)], [btn("❌ 取消", "cancel")]]))
        elif data.startswith("dorb:"):
            tag = data.split(":", 1)[1]
            if not re.match(r"^v?[0-9][0-9A-Za-z.\-]*$", tag):
                edit(chat, mid, "⚠️ 版本号格式异常，已取消", kb([[btn("🏠 主菜单", "home")]]))
            else:
                edit(chat, mid, "⏳ 正在回退到 <b>%s</b>…（约1分钟，完成后单独推送结果）" % tag, kb([]))
                subprocess.Popen(["/bin/bash", "/opt/nezha/nezha_upgrade.sh", "apply", tag])
    except Exception as e:
        print("callback err:", e)
        try:
            send(chat, "⚠️ 操作失败：%s" % e)
        except Exception:
            pass


def main():
    state = load_state()
    state.setdefault("pending", {})
    # 启动对齐到最新 update_id，避免处理重启前的旧消息
    if "offset" not in state:
        r = tg("getUpdates", timeout=0)
        ups = r.get("result", [])
        state["offset"] = (ups[-1]["update_id"] + 1) if ups else 0
        save_state(state)
    print("nezha-bot 启动 | offset=%s | owner=%s" % (state["offset"], state.get("owner_id")))
    while True:
        if not leak_guard(state):
            return
        # 每小时把面板设的到期日归一到当天中午12:00(避免面板白天掉天)
        if time.time() - state.get("last_normalize", 0) >= 3600:
            try:
                normalize_expiry()
            except Exception as e:
                print("normalize loop err:", e)
            # 顺手收一次 WAL，防其无限胀大(Nezha 自身 checkpoint 会被长读连接挡住)
            try:
                _con = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
                _con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                _con.close()
            except Exception as e:
                print("wal checkpoint err:", e)
            state["last_normalize"] = time.time()
            save_state(state)
        try:
            r = tg("getUpdates", offset=state["offset"], timeout=30)
            if not r.get("ok"):
                time.sleep(3)   # TG 失败/冲突，避免空转
                continue
            for up in r.get("result", []):
                state["offset"] = up["update_id"] + 1
                if "message" in up:
                    handle_message(up["message"], state)
                elif "callback_query" in up:
                    handle_callback(up["callback_query"], state)
                save_state(state)
        except Exception as e:
            print("loop err:", e)
            time.sleep(3)


if __name__ == "__main__":
    main()
PYEOF
}

# bot 读写 PAT（数据层），明文存 /opt/nezha/.nezha_bot_pat (600)
ensure_bot_pat() {
    local DB="${DATA_DIR}/sqlite.db"
    local PAT_FILE="${INSTALL_DIR}/.nezha_bot_pat"
    if [ -s "$PAT_FILE" ]; then
        echo -e "${GREEN}bot 读写 PAT 已存在，跳过生成${PLAIN}"; return 0
    fi
    local TOKEN
    TOKEN=$(python3 - "$DB" <<'PY'
import sqlite3, sys, time, hashlib, secrets
db = sys.argv[1]; c = sqlite3.connect(db, timeout=15)
for _ in range(15):
    try:
        c.execute("SELECT 1 FROM api_tokens LIMIT 1"); c.execute("SELECT 1 FROM users LIMIT 1"); break
    except sqlite3.OperationalError:
        time.sleep(2)
else:
    sys.exit(0)
row = c.execute("SELECT id FROM users ORDER BY id LIMIT 1").fetchone()
if not row: sys.exit(0)
uid = row[0]; secret = secrets.token_hex(32); token = "nzp_" + secret
th = hashlib.sha256(token.encode()).hexdigest()
c.execute("DELETE FROM api_tokens WHERE name=?", ("nezha-mgr-bot",))
c.execute("INSERT INTO api_tokens (user_id,name,token_hash,scopes_csv,servers_csv,created_at,updated_at) "
          "VALUES (?,?,?,?,?,datetime('now'),datetime('now'))",
          (uid, "nezha-mgr-bot", th, "nezha:inventory:read,nezha:server:write,nezha:service:write", ""))
c.commit(); print(token)
PY
)
    if [ -n "$TOKEN" ]; then
        echo "$TOKEN" > "$PAT_FILE"; chmod 600 "$PAT_FILE"
        echo -e "${GREEN}✅ 已生成 bot 读写 PAT（无 delete/exec）${PLAIN}"
    else
        echo -e "${YELLOW}⚠ bot PAT 生成失败，请确认面板已就绪${PLAIN}"
    fi
}

_bot_service_install() {
    cat > "$BOT_SERVICE" << EOF
[Unit]
Description=Nezha TG Manage Bot
After=network.target nezha-dashboard.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u ${BOT_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=append:/var/log/nezha_bot.log
StandardError=append:/var/log/nezha_bot.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nezha-bot >/dev/null 2>&1
    ensure_bot_pat
    systemctl restart nezha-bot
}

manage_bot() {
    while true; do
        clear
        local ST; ST=$(systemctl is-active nezha-bot 2>/dev/null)
        echo -e "${CYAN}=== TG 管理 Bot ===${PLAIN}  当前状态: ${ST}"
        echo "  1. 部署 / 重启 Bot"
        echo "  2. 停止 Bot"
        echo "  3. 查看日志"
        echo "  0. 返回"
        read -p " 选项: " b
        case "$b" in
            1)
                local TOKEN
                TOKEN=$(grep -m1 '^TG_BOT_TOKEN' "$NOTIFY_SCRIPT" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')
                { [ "$TOKEN" = "请填写" ] || [ -z "$TOKEN" ]; } && TOKEN=$(grep -m1 '^TG_BOT_TOKEN' "$HEALTH_SCRIPT" 2>/dev/null | sed -E 's/.*"([^"]*)".*/\1/')
                if [ "$TOKEN" = "请填写" ] || [ -z "$TOKEN" ]; then
                    read -p "请输入 TG Bot Token（与到期推送/健康告警共用同一个）: " TOKEN
                fi
                if [ -z "$TOKEN" ]; then echo -e "${RED}未提供 token${PLAIN}"; press_any_key; continue; fi
                deploy_bot_script
                sed -i "s|^TG_BOT_TOKEN    = .*|TG_BOT_TOKEN    = \"${TOKEN}\"|" "$BOT_SCRIPT"
                _bot_service_install
                sleep 3
                if systemctl is-active --quiet nezha-bot; then
                    echo -e "${GREEN}✅ Bot 已启动。用你的账号私聊该 bot 发送 /start（第一个发送者成为管理员）${PLAIN}"
                else
                    echo -e "${RED}启动失败，见 /var/log/nezha_bot.log${PLAIN}"
                fi
                press_any_key ;;
            2)
                systemctl stop nezha-bot; systemctl disable nezha-bot >/dev/null 2>&1
                echo -e "${YELLOW}Bot 已停止${PLAIN}"; press_any_key ;;
            3)
                tail -n 40 /var/log/nezha_bot.log 2>/dev/null; press_any_key ;;
            0) return ;;
            *) ;;
        esac
    done
}

deploy_upgrade_script() {
    cat > "$UPGRADE_SCRIPT" << 'SHEOF'
#!/bin/bash
# 哪吒面板 版本检测/自动更新/回退 - 复用健康告警的 TG 配置
# 用法: 无参=定时检查最新版(AUTO_UPDATE=true 则自动升级)；apply <tag>=直接安装指定版本(bot 回退/按需调用)
AUTO_UPDATE="false"
INSTALL_DIR="/opt/nezha"
DASHBOARD_PATH="${INSTALL_DIR}/dashboard"
VERSION_FILE="${INSTALL_DIR}/version"
STATE_FILE="${INSTALL_DIR}/upgrade_notified"
HEALTH_SCRIPT="${INSTALL_DIR}/nezha_health.py"
UPGRADE_TRIGGER="/opt/nezha/.upgrade_now"

TG_BOT_TOKEN=$(grep 'TG_BOT_TOKEN' "$HEALTH_SCRIPT" 2>/dev/null | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
TG_CHAT_ID=$(grep 'TG_CHAT_ID' "$HEALTH_SCRIPT" 2>/dev/null | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
if [ -z "$TG_BOT_TOKEN" ] || [ "$TG_BOT_TOKEN" = "请填写" ]; then
    echo "健康告警未配置 TG，跳过"; exit 0
fi

send_tg() {
    if [ -n "$2" ]; then
        curl -s --max-time 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$1" --data-urlencode "reply_markup=$2" >/dev/null
    else
        curl -s --max-time 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$1" >/dev/null
    fi
}

panel_healthy() {
    local port code i
    port=$(grep -E '^[[:space:]]*listen_?port:' "${INSTALL_DIR}/data/config.yaml" 2>/dev/null | head -1 | grep -o '[0-9]\+')
    port=${port:-8008}
    for i in 1 2 3 4 5 6; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null)
        [ -n "$code" ] && [ "$code" != "000" ] && return 0
        sleep 3
    done
    return 1
}

panel_url() {
    local d
    d=$(grep -A 20 'listen 443' /etc/nginx/nginx.conf 2>/dev/null | grep 'server_name' | head -1 | awk '{print $2}' | tr -d ';')
    [ -n "$d" ] && [ "$d" != "_" ] && echo "https://$d"
}
PANEL_URL=$(panel_url)
panel_btn() {
    [ -n "$PANEL_URL" ] && printf '{"inline_keyboard":[[{"text":"👉 进入面板","url":"%s"}]]}' "$PANEL_URL"
}

# 等待最多 600 秒；bot 收到「立即更新」回调后创建触发文件，这里检测到即提前返回
wait_or_trigger() {
    local deadline; deadline=$(( $(date +%s) + 600 )); rm -f "$UPGRADE_TRIGGER"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ -f "$UPGRADE_TRIGGER" ] && { rm -f "$UPGRADE_TRIGGER"; return 0; }
        sleep 3
    done
    return 1
}

ARCH=$(uname -m)
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    s390x)   ARCH="s390x" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# 回退按钮：①永远带一颗"回到升级前版本(prev)"专属键(不管多老一键回) ②再列当前版往前 3 个官方版供选。回调 rollback:<tag> 由 bot 处理
# $1=当前(新)版本 $2=升级前版本(prev)
rollback_markup() {
    local cur="$1" prev="$2" tags btns="" count=0 seen=0 rows="" t prevbtn=""
    tags=$(curl -s --max-time 20 "https://api.github.com/repos/nezhahq/nezha/releases?per_page=12" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -n "$prev" ] && [ "$prev" != "$cur" ] && [ "$prev" != "未知" ]; then
        prevbtn="{\"text\":\"⏮ 回到升级前 ${prev}\",\"callback_data\":\"rollback:${prev}\"}"
    fi
    while read -r t; do
        [ -z "$t" ] && continue
        if [ "$seen" = "1" ]; then
            [ "$t" = "$prev" ] && { count=$((count+1)); [ "$count" -ge 3 ] && break; continue; }  # prev 已有专属键, 去重不重复列
            btns="${btns}${btns:+,}{\"text\":\"⬅️ ${t}\",\"callback_data\":\"rollback:${t}\"}"
            count=$((count+1)); [ "$count" -ge 3 ] && break
        fi
        [ "$t" = "$cur" ] && seen=1
    done <<< "$tags"
    [ -n "$prevbtn" ] && rows="[${prevbtn}]"
    [ -n "$btns" ] && rows="${rows}${rows:+,}[${btns}]"
    [ -n "$PANEL_URL" ] && rows="${rows}${rows:+,}[{\"text\":\"👉 进入面板\",\"url\":\"${PANEL_URL}\"}]"
    [ -n "$rows" ] && printf '{"inline_keyboard":[%s]}' "$rows"
}

# 安装指定版本：下载→备份→替换→重启→HTTP校验，失败自动回滚到 .bak。$1=目标tag $2=来源版本(消息用)
install_version() {
    local TAG="$1" FROM="$2"
    local DL_URL="https://github.com/nezhahq/nezha/releases/download/${TAG}/dashboard-linux-${ARCH}.zip"
    local TMP_ZIP="${INSTALL_DIR}/dashboard_new.zip"
    if ! curl -L -s --max-time 120 -o "$TMP_ZIP" "$DL_URL"; then
        send_tg "❌ 下载 ${TAG} 失败，面板未改动。" "$(panel_btn)"; rm -f "$TMP_ZIP"; return 1
    fi
    if ! unzip -o "$TMP_ZIP" -d "$INSTALL_DIR" >/dev/null 2>&1; then
        send_tg "❌ 解压 ${TAG} 失败（文件可能损坏），面板未改动。" "$(panel_btn)"; rm -f "$TMP_ZIP" "${INSTALL_DIR}/dashboard-linux-${ARCH}"; return 1
    fi
    rm -f "$TMP_ZIP"
    local NEW_BIN="${INSTALL_DIR}/dashboard-linux-${ARCH}"
    [ -f "$NEW_BIN" ] || { send_tg "❌ 未找到 ${TAG} 二进制，面板未改动。" "$(panel_btn)"; return 1; }
    systemctl stop nezha-dashboard
    cp -f "$DASHBOARD_PATH" "${DASHBOARD_PATH}.bak" 2>/dev/null
    mv -f "$NEW_BIN" "$DASHBOARD_PATH"; chmod +x "$DASHBOARD_PATH"
    systemctl start nezha-dashboard; sleep 5
    if panel_healthy; then
        echo "$TAG" > "$VERSION_FILE"; rm -f "${DASHBOARD_PATH}.bak"
        send_tg "$(printf '✅ 哪吒面板已切换\n\n%s → %s\n面板可访问。如有异常可点下方回退（首键=回到升级前版本）。' "${FROM:-未知}" "$TAG")" "$(rollback_markup "$TAG" "$FROM")"
        echo "切换成功: $TAG"; return 0
    else
        if [ -f "${DASHBOARD_PATH}.bak" ]; then mv -f "${DASHBOARD_PATH}.bak" "$DASHBOARD_PATH"; chmod +x "$DASHBOARD_PATH"; systemctl start nezha-dashboard; fi
        send_tg "$(printf '❌ 切换到 %s 失败（面板起不来），已自动恢复到 %s 并重启，请手动检查。' "$TAG" "${FROM:-旧版本}")" "$(panel_btn)"
        echo "切换失败已回滚"; return 1
    fi
}

CURRENT=$(cat "$VERSION_FILE" 2>/dev/null)

# ===== 模式 apply <tag>：直接安装指定版本（bot 回退/按需调用）=====
if [ "$1" = "apply" ] && [ -n "$2" ]; then
    install_version "$2" "$CURRENT"
    exit $?
fi

# ===== 默认模式：定时检查最新版 =====
LATEST=$(curl -s --max-time 20 https://api.github.com/repos/nezhahq/nezha/releases/latest | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$LATEST" ] && { echo "获取最新版本失败"; exit 0; }
if [ "$CURRENT" = "$LATEST" ]; then rm -f "$STATE_FILE"; echo "已是最新版本 $CURRENT"; exit 0; fi
if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$LATEST" ]; then echo "新版本 $LATEST 已处理过，跳过"; exit 0; fi
echo "$LATEST" > "$STATE_FILE"

# 自动更新关闭：仅推送通知
if [ "$AUTO_UPDATE" != "true" ]; then
    send_tg "$(printf '🆕 哪吒面板有新版本\n\n当前版本: %s\n最新版本: %s\n\n可在管理脚本中选择「更新面板」升级。' "${CURRENT:-未知}" "$LATEST")" "$(panel_btn)"
    echo "已推送新版本通知: $LATEST"; exit 0
fi

# 自动更新开启：提前通知(带「立即更新」按钮) → 等待 → 安装
if [ -n "$PANEL_URL" ]; then
    PRE_MARKUP=$(printf '{"inline_keyboard":[[{"text":"⚡ 立即更新","callback_data":"update_now"}],[{"text":"👉 进入面板","url":"%s"}]]}' "$PANEL_URL")
else
    PRE_MARKUP='{"inline_keyboard":[[{"text":"⚡ 立即更新","callback_data":"update_now"}]]}'
fi
send_tg "$(printf '🆕 哪吒面板有新版本 %s（当前 %s）\n\n将在 10 分钟后自动更新，期间面板会短暂重启。\n点下方按钮可立即开始。' "$LATEST" "${CURRENT:-未知}")" "$PRE_MARKUP"
wait_or_trigger && echo "用户点击立即更新" || echo "等待结束，开始自动更新"
install_version "$LATEST" "$CURRENT"
exit $?
SHEOF
    chmod +x "$UPGRADE_SCRIPT"
}

# 部署 / 确保新版本检测的 systemd timer（每天 10:00 CST）
setup_upgrade_timer() {
    cat > /etc/systemd/system/nezha-upgrade.service << 'SVCEOF'
[Unit]
Description=Nezha Dashboard New Version Check / Auto Update

[Service]
Type=oneshot
TimeoutStartSec=0
ExecStart=/bin/bash /opt/nezha/nezha_upgrade.sh
StandardOutput=append:/var/log/nezha_upgrade.log
StandardError=append:/var/log/nezha_upgrade.log
SVCEOF
    cat > /etc/systemd/system/nezha-upgrade.timer << 'TMREOF'
[Unit]
Description=Nezha Dashboard New Version Check Timer

[Timer]
OnCalendar=*-*-* 10:00:00 Asia/Shanghai
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
TMREOF
    systemctl daemon-reload
    systemctl enable --now nezha-upgrade.timer
}

tg_configured() {
    local t
    t=$(grep 'TG_BOT_TOKEN' "$HEALTH_SCRIPT" 2>/dev/null | head -1 | sed "s/.*= *['\"]//;s/['\"].*//")
    [ -n "$t" ] && [ "$t" != "请填写" ]
}

manage_update() {
    [ ! -f "$UPGRADE_SCRIPT" ] && deploy_upgrade_script

    while true; do
    clear
    local cur_ver timer_status auto_raw auto_status
    cur_ver=$(cat /opt/nezha/version 2>/dev/null); cur_ver=${cur_ver:-未知}
    if systemctl is-active --quiet nezha-upgrade.timer 2>/dev/null; then
        timer_status="${GREEN}已启用${PLAIN}"
    else
        timer_status="${RED}未启用${PLAIN}"
    fi
    auto_raw=$(grep '^AUTO_UPDATE=' "$UPGRADE_SCRIPT" 2>/dev/null | head -1 | sed -E 's/.*"(.*)".*/\1/')
    if [ "$auto_raw" = "true" ]; then
        auto_status="${GREEN}已开启${PLAIN}"
    else
        auto_status="${RED}已关闭${PLAIN}"
    fi
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║${PLAIN}${BLUE}                   更新面板 / 自动更新                ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  当前版本  : ${cur_ver}"
    echo -e "${CYAN}║${PLAIN}  定时检测  : ${timer_status}"
    echo -e "${CYAN}║${PLAIN}  自动更新  : ${auto_status}   (新版本 10 分钟后自动升级)"
    echo -e "${CYAN}║${PLAIN}  TG 推送   : 复用健康告警 (菜单 3)"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   1.  立即更新到最新版 (手动)                        ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   2.  定时检测推送 : 开启 / 关闭                     ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   3.  自动更新     : 开启 / 关闭                     ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   4.  立即检测一次                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   0.  返回                                           ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}"
    read -p " 请输入选项: " opt
    case "$opt" in
        1)
            echo -e "${CYAN}正在检查最新版本...${PLAIN}"
            local latest
            latest=$(curl -s --max-time 20 https://api.github.com/repos/nezhahq/nezha/releases/latest | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
            if [ -z "$latest" ]; then
                echo -e "${RED}获取最新版本失败，请检查网络${PLAIN}"
                press_any_key; continue
            fi
            if [ "$cur_ver" = "$latest" ]; then
                echo -e "${GREEN}当前已是最新版本 ${latest}，无需更新${PLAIN}"
                read -p " 仍要强制重装一次？(y/N): " force
                if [ "$force" != "y" ] && [ "$force" != "Y" ]; then
                    continue
                fi
            else
                echo -e "${YELLOW}发现新版本：${cur_ver} → ${latest}，开始更新${PLAIN}"
            fi
            install_nezha
            press_any_key
            ;;
        2)
            if systemctl is-active --quiet nezha-upgrade.timer 2>/dev/null; then
                systemctl disable --now nezha-upgrade.timer 2>/dev/null
                echo -e "${YELLOW}定时检测已关闭 (自动更新也将不再触发)${PLAIN}"
            else
                if ! tg_configured; then
                    echo -e "${YELLOW}请先在菜单 3「健康告警」填好 TG Bot Token / Chat ID，推送会复用该配置${PLAIN}"
                    press_any_key; continue
                fi
                setup_upgrade_timer
                echo -e "${GREEN}定时检测已开启 (每天 10:00 北京时间)${PLAIN}"
            fi
            sleep 1
            continue
            ;;
        3)
            if [ "$auto_raw" = "true" ]; then
                sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE="false"/' "$UPGRADE_SCRIPT"
                echo -e "${YELLOW}自动更新已关闭 (仍会推送新版本通知)${PLAIN}"
            else
                if ! tg_configured; then
                    echo -e "${YELLOW}请先在菜单 3「健康告警」填好 TG Bot Token / Chat ID，推送会复用该配置${PLAIN}"
                    press_any_key; continue
                fi
                sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE="true"/' "$UPGRADE_SCRIPT"
                setup_upgrade_timer
                echo -e "${GREEN}自动更新已开启：检测到新版本将提前 10 分钟通知后自动升级${PLAIN}"
            fi
            sleep 1
            continue
            ;;
        4)
            echo -e "${CYAN}正在检测...${PLAIN}"
            bash "$UPGRADE_SCRIPT"
            press_any_key
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            sleep 1
            continue
            ;;
    esac
    done
}

# ==============================================================
# 菜单
# ==============================================================
menu() {
    clear
    get_service_status
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║${PLAIN}${BLUE}       哪吒监控面板管理脚本  v${SCRIPT_VERSION}  三S优化版        ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  服务状态                                            ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   Nginx           :  ${NGINX_STATUS}                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   Nezha Dashboard :  ${NEZHA_STATUS}   ${CYAN}(${NEZHA_VER})${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   到期推送        :  ${NOTIFY_STATUS}                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   健康告警        :  ${HEALTH_STATUS}                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   定时检测        :  ${DETECT_STATUS}                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   自动更新        :  ${AUTOUP_STATUS}                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   SSL 证书        :  ${CERT_STATUS}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  ${GREEN}安装与配置${PLAIN}                                          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   1.  安装面板 (Binary + Nginx + Cert)               ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   2.  配置到期推送                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   3.  配置健康告警 (CPU/内存/磁盘/离线)              ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   4.  更新面板 (手动 / 自动更新 / 检测推送)          ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   5.  配置 Nginx (v${SCRIPT_VERSION})                            ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   6.  申请/续签证书 (acme.sh)                        ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   7.  配置 GitHub OAuth                              ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${PLAIN}"
    echo -e "${CYAN}║${PLAIN}  ${GREEN}服务管理${PLAIN}                                            ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   8.  查看优化状态                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   9.  服务控制 (启动 / 重启 / 停止)                  ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   10. 查看实时日志                                   ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   11. 同步界面美化代码                               ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   12. 配置 TG 管理 Bot                               ${CYAN}║${PLAIN}"
    echo -e "${CYAN}║${PLAIN}   0.  退出                                           ${CYAN}║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${PLAIN}"
    read -p " 请输入选项: " num

    case "$num" in
        1)
            if install_base && install_nezha && configure_nginx; then
                cert_management
                configure_oauth
                sync_custom_code
                print_install_summary
            else
                echo -e "${RED}安装中断：核心步骤失败，请检查上方报错信息${PLAIN}"
            fi
            press_any_key
            ;;
        2)
            manage_notify
            ;;
        3)
            manage_health
            ;;
        4)
            manage_update
            ;;
        5)
            configure_nginx
            press_any_key
            ;;
        6)
            cert_management
            press_any_key
            ;;
        7)
            configure_oauth
            print_install_summary
            press_any_key
            ;;
        8)
            show_optimization_status
            press_any_key
            ;;
        9)
            service_control
            ;;
        10)
            show_logs
            ;;
        11)
            sync_custom_code
            press_any_key
            ;;
        12)
            manage_bot
            ;;
        0)
            echo -e "${GREEN}再见!${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确数字 [0-12]${PLAIN}"
            sleep 1
            ;;
    esac
}

# 执行入口
check_root
check_sys
while true; do
    menu
done
