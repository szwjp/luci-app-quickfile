# 安装与访问方式

本页是 [README](../README.md) 的展开：安装命令、nginx 集成细节、以及访问方式。

## 安装

从 [Releases](../../releases) 页面下载 apk（同一个 release 提供 3 个包），按顺序安装（先后端）：

- `quickfile-<version>.apk` —— 后端二进制、init 启动脚本、nginx 配置（`conf.d/quickfile.locations`）。
- `luci-app-quickfile-<version>.apk` —— LuCI 页面，并在 post-install 里做 nginx 集成。
- `luci-i18n-quickfile-zh-cn-<version>.apk` —— 可选，只翻译 LuCI 菜单项。

包未签名，apk 需要 `--allow-untrusted`：

```sh
apk add --allow-untrusted quickfile-<version>.apk
apk add --allow-untrusted luci-app-quickfile-<version>.apk
apk add --allow-untrusted luci-i18n-quickfile-zh-cn-<version>.apk   # 可选
```

安装后进入 **系统 → Quick File Manager**。后端服务由 `quickfile` 包的 post-install
自动 enable 并启动（`/etc/init.d/quickfile`），不需要再手动敲 `start`；`luci-app-quickfile`
的 post-install 会 reload nginx，让 `conf.d/quickfile.locations` 立刻生效。两条安装命令
执行完即可直接打开页面，无需任何后续手动操作。依赖 `luci-nginx` 与 `quickfile`，即 LuCI 由
nginx + uwsgi 提供服务。本仓库只提供 apk；仍使用 opkg 的旧系统请按上游 README 的编译
指南，在自己的 OpenWrt 树里编译上游包。

## nginx 集成

quickfile 复用 luci-nginx 已有的 LAN 服务器（`nginx._lan`，HTTPS 443），不额外开端口：

- 需要的前置条件是 `nginx._lan` 的 `include` 列表里有 `conf.d/*.locations`
  （`quickfile.locations` 安装在该目录）。stock 配置默认已包含，post-install 只在这个
  条目确实缺失时补上。
- **不会**改动 `listen`，**不会**删除 `_redirect2ssl`，**不会**创建或替换任何证书。
  `http://` 仍按你现有的配置跳转到 `https://`。
- 安装/升级后会恢复被旧版本删掉的 `_redirect2ssl`（如果确实缺失），并去掉重复的
  `include` 列表项。
- 改完配置后通过 `/etc/init.d/nginx reload` 重新加载；nginx 自己会先跑 `nginx -t`，
  若被拒绝则自动从备份恢复，不会留下坏配置。备份在
  `/root/backup/nginx-uci-<时间戳>.txt`（只保留最近 5 个）。
  **即使 UCI 配置本来就已经正确，post-install 也会 reload 一次**：包刚装上的
  `conf.d/quickfile.locations` 只有 reload 才会被运行中的 nginx 读到，不 reload 的话
  所有请求都会得到 404。
- 卸载时会把指向本包证书目录的配置交还给 nginx-util（如果有），并删除 1.x 时代遗留的
  `conf.d/quickfile-auth.conf` 与 `/etc/ssl/quickfile/`。
- 转发头里带上了 `X-Forwarded-Proto`/`X-Forwarded-Port`/`X-Forwarded-Host`：后端据此
  判断当前是不是 https（决定它自己的 cookie 要不要加 `Secure`），默认的 LuCI 会话
  模式下用不到，但启用后端自带账号时需要。
- `assets/` 目录（前端构建产物，文件名带内容哈希）单独设了 30 天长缓存，二次进入页面
  不用重新下载整个前端。

## 鉴权：后端直接用 ubus 校验会话

2.x 的后端不再回环请求 `/cgi-bin/luci`，而是**直接调用本机的 `ubus`**
（`ubus_rpc_session`）校验 LuCI 会话：

- 后端依次读取 `sysauth_http`、`sysauth_https`、`sysauth` 三种 cookie 名，所以
  http 与 https 下 LuCI 发的会话 cookie 都能被认出来，**不需要任何 cookie 改写**，
  也不需要额外的回环监听端口。
- 会话是否有效由 rpcd/ubus 判定：DNS、服务器证书、访问规则都不参与，因此不存在
  "证书不覆盖 LAN IP 导致会话校验失败"这类问题。
- 前提是**必须从已登录的 LuCI 会话访问**（浏览器里先登录 LuCI），否则后端会返回
  `invalid session` / `missing_session`。
- 后端会调用本机的 `ubus` 命令行程序（基础系统自带），无需额外安装。

## 实际能怎么访问

| 访问方式 | 结果 |
|---|---|
| `https://<lan-ip>/cgi-bin/luci/quickfile` | **完整可用**（证书告警取决于你自己的证书，见下） |
| 通过 `_lan` 证书覆盖的域名（如 ACME 域名）访问 | **完整可用**（需该域名在内网能解析到路由器） |
| `http://<lan-ip>/cgi-bin/luci/quickfile` | 取决于你的 http→https 策略，本包不改：`_redirect2ssl` 带 `return` 规则时 301/302 跳到 https；该 server 没配 `return`（实测机就是这种）时，http 直接可用 |

`http` 与 `https` **两种登录方式都支持**：后端读 `sysauth_http` / `sysauth_https` / `sysauth`
三种会话 cookie，与 LuCI 自己的 dispatcher 接受的名单一致，从哪个协议登录 LuCI 拿到的
会话后端都认。

证书由你现有的 nginx 配置决定，本包**完全不碰**：用 nginx-util 自签证书时按 IP 访问会
有证书告警（自签证书没有 IP SAN），用自己的 ACME 证书时按域名访问不会有告警，按 IP 访问
仍会告警（域名证书不覆盖 IP）。这不影响功能本身。

## 大文件上传

上传大文件时请求体是直通后端的（`proxy_request_buffering off`），不会先缓冲到磁盘；
`client_max_body_size 0` 只作用于 quickfile 自己的 location，Web 界面其余部分保持
`uci.conf.template` 里的 128M 限制。只有当你把 `proxy_request_buffering` 改回默认
（`on`）时，才需要把 `client_body_temp_path` 指到大容量分区，否则 nginx 会缓冲到根文件
系统上的 `/var/lib/nginx/body`（`quickfile.locations` 里有注释说明）。

## 卸载

```sh
apk del luci-app-quickfile luci-i18n-quickfile-zh-cn quickfile
```

卸载会清理 nginx 配置（见上），但不会自动删除你在文件管理器里改动过的任何文件。
