#!/bin/sh
# 为 quickfile 增加「IP + SAN 自签证书」访问（方案B）：
#   保留域名 Let's Encrypt（_lan 走 SNI），新增 443 default_server 用自签 IP 证书。
# 用法：
#   sh setup-https-ip.sh                 # dry-run：只打印将执行的命令（默认）
#   sh setup-https-ip.sh --apply         # 真正执行（备份 uci nginx + 生成证书 + 改 nginx）
#   sh setup-https-ip.sh --apply 192.168.1.1 wjp-family.top
# 本脚本绝不修改 /etc/nginx/conf.d/quickfile.locations 与 /etc/init.d/quickfile。

set -u

APPLY=0
LAN_IP=""
DOMAIN=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1;;
    *)
      if [ -z "$LAN_IP" ]; then LAN_IP="$a"; else DOMAIN="$a"; fi;;
  esac
done

LAN_IP="${LAN_IP:-192.168.1.1}"
DOMAIN="${DOMAIN:-wjp-family.top}"
CERTS_DIR=/etc/ssl/quickfile
CRT="$CERTS_DIR/quickfile-ip.crt"
KEY="$CERTS_DIR/quickfile-ip.key"
QF_LOC=/etc/nginx/conf.d/quickfile.locations
QF_INIT=/etc/init.d/quickfile

run() {
  if [ "$APPLY" = "1" ]; then
    echo "  + $*"
    "$@"
  else
    echo "  # $*"
  fi
}

echo "==== 配置 ===="
echo "  LAN_IP=$LAN_IP  DOMAIN=$DOMAIN  APPLY=$APPLY"

if [ "$APPLY" = "1" ]; then
  echo "==== 1. 备份 uci nginx + 记录 quickfile 配置指纹 ===="
  mkdir -p /root/backup
  BK="/root/backup/nginx-uci-$(date +%Y%m%d-%H%M%S).txt"
  uci export nginx > "$BK" && echo "  备份: $BK"
  echo "  quickfile 指纹(前): $(md5sum "$QF_LOC" "$QF_INIT" 2>/dev/null)"
fi

echo "==== 2. 生成自签证书（SAN=IP:$LAN_IP, IP:127.0.0.1）===="
mkdir -p "$CERTS_DIR"
run openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$CRT" -days 825 \
  -subj "/CN=$LAN_IP" \
  -addext "subjectAltName=IP:$LAN_IP,IP:127.0.0.1"

echo "==== 3a. _lan 只负责域名(SNI)，保留 LE，去掉 default_server ===="
ADD_1000=0
uci -q get nginx._lan.listen 2>/dev/null | grep -q "1000" && ADD_1000=1
run uci set nginx._lan.server_name="$DOMAIN"
run uci delete nginx._lan.listen
run uci add_list nginx._lan.listen="443 ssl"
run uci add_list nginx._lan.listen="[::]:443 ssl"
[ "$ADD_1000" = "1" ] && run uci add_list nginx._lan.listen="1000 ssl"
echo "  # _lan 的 ssl_certificate / ssl_certificate_key 保持指向 /etc/ssl/acme/... 不动"

echo "==== 3b. 新增 default_server(_lan_ip, 自签 IP 证书) ===="
if [ "$APPLY" = "1" ]; then
  if ! uci -q get nginx._lan_ip >/dev/null 2>&1; then
    echo "  + uci add nginx server"
    NEWSEC=$(uci add nginx server)
    echo "  + uci rename nginx.${NEWSEC} _lan_ip"
    uci rename "nginx.${NEWSEC}" _lan_ip
  fi
else
  echo "  # uci add nginx server   ; 然后 uci rename nginx.<newname> _lan_ip"
fi
run uci set nginx._lan_ip.listen="443 ssl default_server"
run uci add_list nginx._lan_ip.listen="[::]:443 ssl default_server"
run uci set nginx._lan_ip.server_name="_"
run uci set nginx._lan_ip.include="conf.d/*.locations"
run uci set nginx._lan_ip.ssl_certificate="$CRT"
run uci set nginx._lan_ip.ssl_certificate_key="$KEY"
run uci set nginx._lan_ip.access_log="off; # logd openwrt"
run uci set nginx._lan_ip.uci_manage_ssl="none"

if [ "$APPLY" = "1" ]; then
  echo "==== 4. 提交 + 重载 nginx ===="
  run uci commit nginx
  run /etc/init.d/nginx restart

  echo "==== 5. 验证 ===="
  echo "  -- 域名(应 CN=$DOMAIN, LE) --"
  echo | openssl s_client -connect "$LAN_IP":443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "  (域名 SNI 校验失败)"
  echo "  -- IP(自签, SAN 含 IP) --"
  echo | openssl s_client -connect "$LAN_IP":443 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null
  echo "  -- quickfile 服务(应 running) --"
  /etc/init.d/quickfile status 2>&1 | head -3
  echo "  -- quickfile 配置指纹(后) --"
  md5sum "$QF_LOC" "$QF_INIT" 2>/dev/null
else
  echo
  echo "==== 未做改动（dry-run）。用 --apply 才真正写入。 ===="
fi

