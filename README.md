# luci-app-quickfile

OpenWrt 上的轻量级网页端文件管理器。鉴权复用 LuCI 会话（浏览器带着 `sysauth_http` cookie 向 LuCI 校验），需配合 `nginx` 使用。

> 本仓库 fork 自 [sbwml/luci-app-quickfile](https://github.com/sbwml/luci-app-quickfile)，自维护 **LuCI 视图 + nginx 集成层 + 构建脚本**；Go 后端二进制 vendored 到 `vendor/quickfile/`（git-lfs）。
>
> **出包范围只有 x86_64。** 本仓库不再提供 aarch64 / arm 的 apk 或 ipk。

## 出包范围与架构

- **只发 x86_64**。apk 只接受与系统架构完全一致的架构名，或恰好是 `noarch`；opkg 的架构列表也来自 `ARCH_PACKAGES`（`x86_64`、`aarch64_cortex-a53`、`arm_cortex-a9` …）。`aarch64`、`arm` 这类写法在真机上不是合法架构，包会被 apk 判定为不可安装、被 opkg 直接忽略，因此不再产出。
- **架构无关包**：`luci-app-quickfile`、`luci-i18n-quickfile-zh-cn` 在 apk 中用 `noarch`，在 ipk 中用 `all`。
- 一次 release 固定 3 个 apk + 3 个 ipk（后端 + 前端 + 可选中文包）。用同一版本再触发一次会重新构建并覆盖该 release 的同名资产。
- `vendor/quickfile/` 目前只保留 x86_64 的 vendored tarball。若要重新支持其他架构，需要重新下载上游对应二进制、更新 `SHA256SUMS`，并把 `.github/build-pkg.sh` 中硬编码的 `ARCH` 改回可选参数。

## 安装

从 [Releases](../../releases) 页面下载对应格式的软件包：同一个 release 同时提供 apk 与 ipk，按你的系统选其中一组，按顺序安装（先后端）。

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

## nginx 集成

quickfile 复用 luci-nginx 已有的 LAN 服务器（`nginx._lan`，HTTPS 443），不额外开端口：

- 唯一需要的前置条件是 `nginx._lan` 的 `include` 列表里有 `conf.d/*.locations`（`quickfile.locations` 安装在该目录）。stock 配置默认已包含，post-install 只在这个条目确实缺失时补上。
- **不会**改动 `ssl_certificate` / `uci_manage_ssl`。`_lan` 上已有的证书（包括 ACME 等正式证书）保持原样，不需要导入任何自签证书。
- **不会**改动 `listen`，也**不会**删除 `_redirect2ssl` 或 `conf.d/000-https-redirect.locations`。`http://` 仍按你现有的配置跳转到 `https://`（stock 模板的 `_redirect2ssl` 用 302，本仓库测试机上另有一层 `if ($scheme = http)` 规则返回 301），本包只保证不破坏它。
- 安装/升级时会清理旧版本（`1464914` 及更早）留下的痕迹：重复的 `listen` / `include` 列表项、旧版本追加到 `_lan` 的 `80` / `443 ssl` 监听、以及被旧版本删掉的 `_redirect2ssl`（自动恢复）。
- 改完配置后通过 `/etc/init.d/nginx reload` 重新加载；nginx 自己会先跑 `nginx -t`，若被拒绝则自动从备份恢复，不会留下坏配置。备份在 `/root/backup/nginx-uci-<时间戳>.txt`（只保留最近 10 个）。

上传大文件时请求体是直通后端的（`proxy_request_buffering off`），不会先缓冲到磁盘；`client_max_body_size 0` 只作用于 quickfile 自己的 location，Web 界面其余部分保持 `uci.conf.template` 里的 128M 限制。只有当你把 `proxy_request_buffering` 改回默认（`on`）时，才需要把 `client_body_temp_path` 指到大容量分区，否则 nginx 会缓冲到根文件系统上的 `/var/lib/nginx/body`（`quickfile.locations` 里有注释说明）。

## 构建与校验

CI 手动触发（Actions → Build → Run workflow），只产 x86_64。版本号唯一真相源是 `luci-app-quickfile/Makefile` 的 `PKG_VERSION` / `PKG_RELEASE`，`quickfile/Makefile` 必须与之相同（不一致直接失败）。

构建前会做三重校验，任一失败即中止，不存在静默降级：

1. `vendor/quickfile/SHA256SUMS` 与 vendored tarball 逐字节比对；
2. 下载上游 `quickfile-<version>.tar.gz`，与 `quickfile/Makefile` 的 `PKG_HASH` 比对；
3. 上游包内的 `quickfile.x86_64` 必须与 vendored 内的二进制完全一致。

即发布出去的二进制一定是 `PKG_HASH` 描述的那一个。离线开发时可用 `QUICKFILE_SKIP_UPSTREAM_VERIFY=1` 跳过第 2、3 步（会打印警告）。

时间戳也是可复现的：`SOURCE_DATE_EPOCH` 取**最后一次改动打包内容**的提交时间（打包内容 = `quickfile/`、`luci-app-quickfile/`、`vendor/quickfile/`、仓库根 `LICENSE`、`.github/build-pkg.sh`；workflow 本身不算，它只决定怎么发布）。所以只改 README/CI 的提交不会改变产物，同一打包内容重跑得到的 apk/ipk 逐字节相同，release 说明里的 sha256 可以用本地构建复现。

本地构建（需要 Linux 环境，与 CI 相同的工具链：`fakeroot`、GNU `find`/`sha256sum`、带 `mkpkg` 的 apk-tools v3、openwrt/luci 的 `po2lmo`、openwrt 的 `ipkg-build`；macOS 自带工具不满足）：

```sh
fakeroot bash .github/build-pkg.sh apk
fakeroot bash .github/build-pkg.sh ipk
```

产物在 `dist/`。所有对外部工具/脚本的依赖都在 workflow 里固定到 commit，`ipkg-build` 还额外固定 SHA-256。

## 升级与回滚

- 从旧版本升级：新版本的 post-install 会自动修复旧版本对 `/etc/config/nginx` 的改动，无需手工干预。
- 旧版本可能生成过 `/etc/ssl/quickfile/`（自签证书，新版本不再使用，也不会再创建），确认没有其他配置引用后可直接删除：`rm -rf /etc/ssl/quickfile`。
- 手工回滚 nginx 配置：

```sh
uci import < /root/backup/nginx-uci-<时间戳>.txt
/etc/init.d/nginx reload
```

## 许可证

- 本仓库的 LuCI 集成代码与构建脚本：Apache License 2.0，见 [LICENSE](LICENSE)。
- 后端二进制 `/usr/bin/quickfile` 来自上游 Go 项目（Apache-2.0，<https://git.cooluc.com/sbwml/quickfile>），原样再分发；许可证与来源说明随包安装到 `/usr/share/licenses/quickfile/`，源码地址见该目录的 `NOTICE`。

## 已知限制

- 未提供非 root 的 ACL，菜单只对 root 可见。
- 后端以 `-dir /` 运行且带命令终端，权限等同 root。请自行确认 `_lan` 仍然限制来源网段：stock 模板会在 `_lan` 的 include 里放 `restrict_locally`（只允许回环与私网地址），本包不会改动它，但如果你手工删过这个 include，`443` 上就是全放开。
- 验证状态：apk 路径（x86_64）已在 ImmortalWrt 25.12.1 上实测；ipk/opkg 路径由同一个打包脚本产出、CI 只校验其 control 字段，未在 opkg 真机上实测。
