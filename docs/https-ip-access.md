# HTTPS / IP 访问兼容（IP + SAN 自签证书，保留域名 Let's Encrypt）

## 为什么需要

quickfile 内在用 **Go** 的 http.Client 反向请求 `{host}/cgi-bin/luci` 校验 LuCI 会话。当用 **IP**（如 `https://192.168.1.1`）访问时，443 那个 default_server（`_lan`）默认用的证书只覆盖域名（如 `wjp-family.top`）而**没有 IP SAN**，于是：

- 浏览器弹「证书名不匹配」；
- 若回环校验地址也取自 IP，quickfile 内部会话校验会报 `Session verification failed: tls: ...`。

> 本仓库提供的 `quickfile.locations` 会把 `host` 改写为 `$scheme://$http_host`。若你已手动把 `host` 硬编码成域名（如 `host=$scheme://wjp-family.top`），则内部校验会自动走「域名+Let's Encrypt 证书」，后端已通——剩下的就只有浏览器对 IP 的证书名不匹配警告。
>
> **方案 B 的思路**：给 IP 访问单独准备一张「覆盖 LAN IP」的证书，作为 443 的 default_server；域名继续走 SNI + Let's Encrypt 证书。两者互不干扰，且**不需要改系统 CA 池**（quickfile 内部校验走域名/LE，路由器本就信任）。

## 前置确认

- nginx 由 luci-nginx 的 uci 配置驱动（`nginx-util` 生成 `/etc/nginx/uci.conf`），改动通过 `uci` 完成。
- 本方案**只改 nginx 服务器块与证书**，**绝不修改**：
  - `/etc/nginx/conf.d/quickfile.locations`
  - `/etc/init.d/quickfile`

## 步骤 1：生成自签证书（覆盖 LAN IP）

```sh
LAN_IP=192.168.1.1
mkdir -p /etc/ssl/quickfile
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/ssl/quickfile/quickfile-ip.key \
  -out    /etc/ssl/quickfile/quickfile-ip.crt \
  -days 825 \
  -subj "/CN=$LAN_IP" \
  -addext "subjectAltName=IP:$LAN_IP,IP:127.0.0.1"

# 校验 SAN 是否包含 IP
openssl x509 -in /etc/ssl/quickfile/quickfile-ip.crt -noout -text | grep -A1 "Subject Alternative Name"
```

> 说明：`openssl x509 -checkhost 192.168.1.1` 是 openssl 工具的限制（只认 DNS 名不认 IP），浏览器与 Go 都**按 SAN 里的 IP 校验**，所以 SAN 里出现 `IP:192.168.1.1` 即正确。

## 步骤 2：调整 nginx（方案 B 落地）

**2a. 让 `_lan` 只负责域名（SNI），保留 Let's Encrypt 证书，去掉 default_server：**

```sh
DOMAIN=wjp-family.top
# 记录原 listen 是否含 '1000 ssl'，避免丢失
ADD_1000=0
uci -q get nginx._lan.listen 2>/dev/null | grep -q "1000" && ADD_1000=1

uci set nginx._lan.server_name="$DOMAIN"
uci delete nginx._lan.listen
uci add_list nginx._lan.listen="443 ssl"
uci add_list nginx._lan.listen="[::]:443 ssl"
[ "$ADD_1000" = "1" ] && uci add_list nginx._lan.listen="1000 ssl"
# _lan 的 ssl_certificate / ssl_certificate_key 保持指向 /etc/ssl/acme/... 不动
```

**2b. 新增 default_server（IP 自签证书），处理 IP 访问：**

```sh
# 新增一个 server 节并给个易记的名字 _lan_ip
if ! uci -q get nginx._lan_ip >/dev/null 2>&1; then
  NEWSEC=$(uci add nginx server)
  uci rename nginx.$NEWSEC=_lan_ip
fi
uci set nginx._lan_ip.listen="443 ssl default_server"
uci add_list nginx._lan_ip.listen="[::]:443 ssl default_server"
uci set nginx._lan_ip.server_name="_"
uci set nginx._lan_ip.include="conf.d/*.locations"
uci set nginx._lan_ip.ssl_certificate="/etc/ssl/quickfile/quickfile-ip.crt"
uci set nginx._lan_ip.ssl_certificate_key="/etc/ssl/quickfile/quickfile-ip.key"
uci set nginx._lan_ip.access_log="off; # logd openwrt"
uci set nginx._lan_ip.uci_manage_ssl="none"
```

**2c. 提交并重载：**

```sh
uci commit nginx
/etc/init.d/nginx restart
```

## 步骤 3：验证

```sh
# 域名仍走 LE 证书（SNI 匹配 _lan）
echo | openssl s_client -connect 192.168.1.1:443 -servername wjp-family.top 2>/dev/null \
  | openssl x509 -noout -subject

# IP 访问走自签证书（SAN 含 IP）
echo | openssl s_client -connect 192.168.1.1:443 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName

# quickfile 服务与配置未被动过
/etc/init.d/quickfile status
md5sum /etc/nginx/conf.d/quickfile.locations /etc/init.d/quickfile
```

## 步骤 4：让浏览器信任自签证书（重要）

自签证书默认不被浏览器信任，需要**一次性导入**（否则访问 `https://192.168.1.1` 仍会有警告）：

- 下载 `/etc/ssl/quickfile/quickfile-ip.crt`，双击导入；
- 选择「受信任的根证书颁发机构 / Trusted Root Certification Authorities」；
- 重启浏览器。

导入后 `https://192.168.1.1` 不再有证书名不匹配。

## 回滚

```sh
# 若出现问题，恢复备份
uci import < /root/backup/nginx-uci-<时间戳>.txt
uci commit nginx
/etc/init.d/nginx restart
```

## 备注 / 局限

- 只覆盖了 `192.168.1.1` 与 `127.0.0.1`；若你还用其它 IP / 公网地址访问，需把对应 IP 加进 SAN（重新生成即可）。
- 若 `wjp-family.top` 需要保持对公网/别人的 Let's Encrypt 信任，方案 B 是最合适的；若只要内网用、也接受域名自签，可用「方案 A」（一份自签证书同时覆盖域名+IP，但需把证书追加进 `/etc/ssl/certs/ca-certificates.crt` 才能让 quickfile 信任域名的回环校验）。
- 浏览器导入自签证书是客户端行为，需在每台使用的设备上做一次。
