#!/bin/bash
# Hysteria 2 Debian V3.6 - NAT/Podman/LXC 兼容版
# 原版 Alpine by jake712 -> Debian 移植版

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; PLAIN='\033[0m'

while getopts "p:w:i:h" opt; do
  case $opt in
    p) CUSTOM_PORT=$OPTARG ;;
    w) CUSTOM_PASSWORD=$OPTARG ;;
    i) CUSTOM_IP=$OPTARG ;;
    h) echo "用法: $0 [-p 端口] [-w 密码] [-i 公网IP]"; exit 0 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}=== Hysteria2 Debian V3.6 Podman兼容版 ===${PLAIN}"
echo -e "容器ID: $(cat /etc/hostname 2>/dev/null || hostname) | 时间: $(date)"

# ===== [1/6] 基础依赖 - Debian 版 =====
echo -e "${YELLOW}[1/6] 检查依赖 (Debian模式)...${PLAIN}"

echo -e "当前 resolv.conf:"
cat /etc/resolv.conf | head -n 5
echo -e "内存:"
cat /proc/meminfo | grep -E "MemTotal|MemAvailable" || free -m 2>/dev/null || true

if grep -q "dns.podman" /etc/resolv.conf 2>/dev/null; then
  echo -e "${YELLOW}检测到 Podman 容器 (dns.podman)，保留原有 DNS，不覆盖${PLAIN}"
else
  if [ ! -s /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "${YELLOW}修复 DNS...${PLAIN}"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
  fi
fi

# Debian 专用安装函数
APT_UPDATED=0
ensure_cmd() {
  CMD=$1
  PKG=$2
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo -e "${YELLOW}安装缺失: $CMD ($PKG)...${PLAIN}"
    if [ "$APT_UPDATED" = "0" ]; then
      apt-get update -qq || apt-get update || true
      APT_UPDATED=1
    fi
    apt-get install -y --no-install-recommends "$PKG" 2>&1 || \
    echo -e "${RED}安装 $PKG 失败，尝试继续...${PLAIN}"
  else
    echo -e "已存在: $CMD"
  fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo -e "${YELLOW}curl 和 wget 都不存在，必须安装一个...${PLAIN}"
  apt-get update -qq || true
  APT_UPDATED=1
  apt-get install -y --no-install-recommends curl || apt-get install -y --no-install-recommends wget || true
fi

ensure_cmd openssl openssl
# Debian 下 dig 在 bind9-dnsutils 或 dnsutils
if ! command -v dig >/dev/null 2>&1; then
  echo -e "${YELLOW}安装 dig...${PLAIN}"
  if [ "$APT_UPDATED" = "0" ]; then apt-get update -qq || true; APT_UPDATED=1; fi
  apt-get install -y --no-install-recommends bind9-dnsutils 2>&1 || apt-get install -y --no-install-recommends dnsutils 2>&1 || true
fi
if ! command -v ss >/dev/null 2>&1; then
  echo -e "${YELLOW}ss 不存在，安装 iproute2...${PLAIN}"
  ensure_cmd ss iproute2
fi
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  ensure_cmd update-ca-certificates ca-certificates
  update-ca-certificates 2>/dev/null || true
fi

# ===== [2/6] 参数和路径 =====
echo -e "${YELLOW}[2/6] 初始化参数...${PLAIN}"
HY_PORT=${CUSTOM_PORT:-26169}
if [ -n "$CUSTOM_PASSWORD" ]; then
  HY_PASS=$CUSTOM_PASSWORD
else
  if command -v openssl >/dev/null 2>&1; then
    HY_PASS=$(openssl rand -base64 12 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
  else
    HY_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
  fi
fi
[ -z "$HY_PASS" ] && HY_PASS="Hy2$(date +%s | tail -c 8)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) HY_ARCH="amd64" ;;
  aarch64|arm64) HY_ARCH="arm64" ;;
  armv7l|arm) HY_ARCH="arm" ;;
  *) HY_ARCH="amd64" ;;
esac

mkdir -p /etc/hysteria /usr/local/bin /run/hysteria /var/log
chmod 700 /etc/hysteria 2>/dev/null || true

# ===== [3/6] 下载 Hysteria2 =====
echo -e "${YELLOW}[3/6] 下载 Hysteria2 ($HY_ARCH)...${PLAIN}"
HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"
rm -f /tmp/hysteria
download_ok=0
for i in 1 2 3; do
  echo "尝试下载 $HY_URL (第 $i 次)"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL --max-time 30 -o /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q --timeout=30 -O /tmp/hysteria "$HY_URL"; then download_ok=1; break; fi
  fi
  sleep 1
done

if [ "$download_ok" != "1" ] || [ ! -s /tmp/hysteria ]; then
  echo -e "${RED}下载失败，尝试备用镜像...${PLAIN}"
  for mirror in "https://ghfast.top/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}" "https://ghproxy.net/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY_ARCH}"; do
    echo "尝试镜像 $mirror"
    curl -fsSL --max-time 30 -o /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
    wget -qO- --timeout=30 -O /tmp/hysteria "$mirror" 2>/dev/null && download_ok=1 && break
  done
fi

if [ ! -s /tmp/hysteria ] || head -c 200 /tmp/hysteria 2>/dev/null | grep -qi "<html"; then
  echo -e "${RED}下载失败${PLAIN}"
  ls -lh /tmp/hysteria 2>/dev/null || true
  head -c 500 /tmp/hysteria 2>/dev/null || true
  exit 1
fi

mv /tmp/hysteria /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria
ls -lh /usr/local/bin/hysteria
/usr/local/bin/hysteria version 2>&1 || /usr/local/bin/hysteria -v 2>&1 || echo "二进制已就绪"

# ===== [4/6] 生成证书和配置 =====
echo -e "${YELLOW}[4/6] 生成配置...${PLAIN}"
if [ ! -f /etc/hysteria/cert.crt ] || [ ! -f /etc/hysteria/key.key ]; then
  echo -e "生成自签名证书..."
  rm -f /etc/hysteria/key.key /etc/hysteria/cert.crt
  openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genpkey -algorithm EC -pkeyopt ec_param_enc:named_curve -pkeyopt ec_paramgen_curve:P-256 -out /etc/hysteria/key.key 2>/dev/null || \
  openssl genrsa -out /etc/hysteria/key.key 2048 2>/dev/null
  
  openssl req -new -x509 -key /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650 2>/dev/null || \
  openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/key.key -out /etc/hysteria/cert.crt -subj "/CN=bing.com" -days 3650
  
  chmod 600 /etc/hysteria/key.key
  ls -lh /etc/hysteria/
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: :${HY_PORT}

auth:
  type: password
  password: ${HY_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/key.key
EOF

cat /etc/hysteria/config.yaml

# ===== [5/6] 服务 - Debian systemd 兼容 Podman =====
echo -e "${YELLOW}[5/6] 配置服务...${PLAIN}"

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  echo -e "检测到 systemd，使用 systemd 服务..."
  cat > /etc/systemd/system/hysteria.service <<EOS
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable hysteria >/dev/null 2>&1 || true
  systemctl restart hysteria || systemctl start hysteria || true
  sleep 2
  systemctl status hysteria --no-pager -l 2>&1 | head -n 30 || journalctl -u hysteria -n 20 --no-pager || cat /var/log/hysteria.log 2>&1 | tail -n 20
else
  echo -e "${YELLOW}未检测到 systemd (容器环境)，使用 nohup 后台运行...${PLAIN}"
  pkill -f "hysteria.*config.yaml" 2>/dev/null || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
  sleep 2
  ps aux | grep hysteria | grep -v grep || cat /var/log/hysteria.log
  cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
pkill -f "hysteria.*config.yaml" || true
sleep 1
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart hysteria
else
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
echo "已重启，日志: tail -f /var/log/hysteria.log"
RESTART
  chmod +x /usr/local/bin/hy2-restart.sh
  echo -e "${GREEN}已创建重启脚本: /usr/local/bin/hy2-restart.sh${PLAIN}"
fi

# 如果是 systemd，也创建一个统一的重启脚本
if [ ! -f /usr/local/bin/hy2-restart.sh ]; then
cat > /usr/local/bin/hy2-restart.sh <<'RESTART'
#!/bin/bash
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart hysteria
  systemctl status hysteria --no-pager -l | head -n 20
else
  pkill -f "hysteria.*config.yaml" || true
  sleep 1
  nohup /usr/local/bin/hysteria server -c /etc/hysteria/config.yaml > /var/log/hysteria.log 2>&1 &
fi
RESTART
chmod +x /usr/local/bin/hy2-restart.sh
fi

sleep 1
if command -v ss >/dev/null 2>&1; then
  ss -tulpn | grep -E "$HY_PORT|hysteria" || echo "ss 未看到端口，检查日志..."
fi
echo -e "日志最后20行:"
tail -n 20 /var/log/hysteria.log 2>/dev/null || journalctl -u hysteria -n 20 --no-pager 2>/dev/null || true

# ===== [6/6] IP检测 =====
echo -e "${YELLOW}[6/6] IP检测...${PLAIN}"

is_private_ip() {
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    127.*) return 0 ;;
    169.254.*) return 0 ;;
    172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
    100.64.*|100.65.*|100.66.*|100.67.*|100.68.*|100.69.*|100.70.*|100.71.*|100.72.*|100.73.*|100.74.*|100.75.*|100.76.*|100.77.*|100.78.*|100.79.*|100.80.*|100.81.*|100.82.*|100.83.*|100.84.*|100.85.*|100.86.*|100.87.*|100.88.*|100.89.*|100.90.*|100.91.*|100.92.*|100.93.*|100.94.*|100.95.*|100.96.*|100.97.*|100.98.*|100.99.*|100.100.*|100.101.*|100.102.*|100.103.*|100.104.*|100.105.*|100.106.*|100.107.*|100.108.*|100.109.*|100.110.*|100.111.*|100.112.*|100.113.*|100.114.*|100.115.*|100.116.*|100.117.*|100.118.*|100.119.*|100.