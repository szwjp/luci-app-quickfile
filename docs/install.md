# 安装与访问方式

本页是 [README](../README.md) 的展开：安装命令、nginx 集成细节、以及三种访问方式。

## 安装

从 [Releases](../../../releases) 页面下载对应格式的软件包：同一个 release 同时提供 apk 与 ipk，按你的系统选其中一组，按顺序安装（先后端）。

- `quickfile-<version>.apk` / `quickfile_<version>_x86_64.ipk` —— 后端二进制、init 启动脚本、nginx 配置（`conf.d/quickfile.locations` 与 `conf.d/quickfile-auth.conf`）。
- `luci-app-quickfile-<version>.apk` / `luci-app-quickfile_<version>_all.ipk` —— LuCI 页面，并在 post-install 里做 nginx 集成（include、必要时的证书）。

apk（OpenWrt main、ImmortalWrt 25.x 等使用 apk 的系统）。包未签名，必须带 `--allow-untrusted`：

```sh
apk add --allow-untrusted quickfile-<version>.apk
apk add --allow-untrusted luci-app-quickfile-<version>.apk
apk add --allow-untrusted luci-i18n-quickfile-zh-cn-<version>.apk   # 可选
```

opkg（仍使用 opkg 的系统）：

```sh
opkg install quickfile_<version>_x86_64.ipk
opkg install luci-app-quickfile_<version>_all.ipk
opkg install luci-i18n-quickfile-zh-cn_<version>_all.ipk           # 可选
```

安装后进入 **系统 → Quick File Manager**。依赖 `luci-nginx`（`+luci-nginx +quickfile`），即 LuCI 由 nginx + uwsgi 提供服务。

## 功能

- **文件管理。** 浏览、创建、重命名、移动、删除文件和文件夹。支持拖拽上传、URL 下载。`zip`、`tar.gz`、`tar.xz` 压缩/解压。查看文件大小、目录内容，计算 MD5/SHA256 校验值。
- **命令终端。** 在当前目录执行系统命令。`Ctrl + Shift + C` 复制，`Ctrl + Shift + V` 粘贴。
- **软件包安装。** 直接安装上传的 `.apk` 或 `.ipk` 文件。后端分别调用 `/usr/bin/apk add --allow-untrusted` 和 `/bin/opkg install --force-downgrade`，因此只会对系统里实际存在的包管理器生效（apk 系统上的 `opkg` 分支必然失败）。
- **媒体预览。** 浏览器内预览常见图片和视频格式。
- **文本编辑器。** Monaco 编辑器，支持多种配置文件和脚本语言的语法高亮。
- **多语言。** 界面文案由后端内置，按浏览器语言提供简体/繁体中文，其余语言回退英文。本仓库的 `luci-i18n-quickfile-zh-cn` 只翻译 LuCI 菜单项，不含界面文案。

## nginx 集成与访问方式

quickfile 复用 luci-nginx 已有的 LAN 服务器（`nginx._lan`，HTTPS 443），不额外开端口：

- 需要的前置条件是 `nginx._lan` 的 `include` 列表里有 `conf.d/*.locations`（`quickfile.locations` 安装在该目录）。stock 配置默认已包含，post-install 只在这个条目确实缺失时补上。
- **不会**改动 `listen`，也**不会**删除 `_redirect2ssl` 或 `conf.d/000-https-redirect.locations`。`http://` 仍按你现有的配置跳转到 `https://`（stock 模板的 `_redirect2ssl` 用 302，部分机器上另有一层 `if ($scheme = http)` 规则返回 301），本包只保证不破坏它。
- 安装/升级时会清理旧版本（`1464914` 及更早）留下的痕迹：重复的 `listen` / `include` 列表项、旧版本追加到 `_lan` 的 `80` / `443 ssl` 监听、以及被旧版本删掉的 `_redirect2ssl`（自动恢复）。
- 改完配置后通过 `/etc/init.d/nginx reload` 重新加载；nginx 自己会先跑 `nginx -t`，若被拒绝则自动从备份恢复，不会留下坏配置。备份在 `/root/backup/nginx-uci-<时间戳>.txt`（只保留最近 10 个）。

### 会话校验为什么走环回

后端校验浏览器会话的方式是：带 `sysauth_http` cookie 去请求 `<host>/cgi-bin/luci`，其中 `<host>` 由 nginx 传给它，且它**默认校验 TLS**。如果传的是浏览器用的地址，就会连带依赖三件容易出问题的事：服务器证书必须覆盖该地址（nginx-util 自带的自签证书连 SAN 都没有，域名证书又不覆盖 LAN IP）、该地址必须能从路由器自身解析并访问、以及不能被访问规则拦住。

所以 `quickfile.locations` 把回连固定为 `http://127.0.0.1:8199`，由 `quickfile-auth.conf` 提供一个**只监听环回口**的明文 vhost，仅服务 `POST /cgi-bin/luci`，其余路径照旧 301 到 https：

- 校验不再依赖证书、DNS、访问规则；`sysauth_http` cookie 只在本机内部传递，不出网卡，也不受 Host 头影响。
- LAN 侧 80 端口（`nginx._redirect2ssl`）完全没有改动；8199 只在环回可达（实测从 LAN IP 访问是连不上）。
- 该 vhost 内联了 uwsgi 参数，因此即使 `/etc/nginx/uwsgi_params` 不存在也不会让 `nginx -t` 失败；`include conf.d/*.conf` 是 stock `uci.conf.template` 自带的，本包不需要再改 include 列表。
- 如果 8199 与你机器上的其他服务冲突，改 `quickfile-auth.conf` 的 `listen` 与 `quickfile.locations` 里两处 `host=` 即可（两处必须一致）。
- `quickfile-auth.conf` 与 `quickfile.locations` 由同一个包安装、必须同时存在：前者提供 `map $quickfile_cookie`，后者引用它。

### 会话 cookie 的名字

ucode 版 LuCI 按协议给会话 cookie 命名（`/usr/share/ucode/luci/dispatcher.uc`：`cookie_name = HTTPS == 'on' ? 'sysauth_https' : 'sysauth_http'`），而 quickfile 后端只查找 `sysauth_http`。所以 HTTPS 下浏览器带的是 `sysauth_https`，后端会直接返回 `invalid session`（这也是旧版本"只能在 http 下才可用"的原因）。`quickfile-auth.conf` 里的 `map` 只在这一个代理跳上把 `sysauth_https=` 改写成 `sysauth_http=`（其余 cookie 原样保留），LuCI 自己收到的仍是原名，因此两边都不受影响。

### 实际能怎么访问

| 访问方式 | 结果 |
|---|---|
| `https://<lan-ip>/cgi-bin/luci/quickfile` | **完整可用**（证书告警见下） |
| 通过 `_lan` 证书覆盖的域名（如 ACME 域名）访问 | **完整可用**（需该域名在内网能解析到路由器） |
| `http://<lan-ip>/cgi-bin/luci/quickfile` | 301 跳转到 https，不直接提供服务（这是 stock 行为，本包不改） |

路由器的证书处理（有则更好，但不是应用可用的前提）：

- 若 `_lan` 用的是 **nginx-util 自签证书**（subject `CN=OpenWrt`、没有任何 SAN），post-install 会生成一张 SAN 覆盖 `IP:<lan-ip>`、`IP:127.0.0.1`、`DNS:<主机名>` 的自签证书并接管（`uci_manage_ssl=quickfile`），这样浏览器访问 `https://<lan-ip>/` 时告警针对的是匹配的地址，导入该证书即可消除；证书有效期 3650 天，LAN IP 变化会自动重签（依赖 `openssl-util`，已加入依赖）。
- 若你已经配置了**自己的证书**（ACME 等，`uci_manage_ssl` 不是 `self-signed`、证书 subject 不是 `CN=OpenWrt`），本包**完全不碰**，只在日志里提示"按 IP 访问需要 IP SAN"。此时按 IP 访问仍会有证书告警（因为域名证书不覆盖 IP），但 quickfile 本身照常工作。

上传大文件时请求体是直通后端的（`proxy_request_buffering off`），不会先缓冲到磁盘；`client_max_body_size 0` 只作用于 quickfile 自己的 location，Web 界面其余部分保持 `uci.conf.template` 里的 128M 限制。只有当你把 `proxy_request_buffering` 改回默认（`on`）时，才需要把 `client_body_temp_path` 指到大容量分区，否则 nginx 会缓冲到根文件系统上的 `/var/lib/nginx/body`（`quickfile.locations` 里有注释说明）。
