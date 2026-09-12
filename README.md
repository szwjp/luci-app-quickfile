# luci-app-quickfile

OpenWrt 上的轻量级网页端文件管理器。鉴权复用 LuCI 的会话 cookie，需配合 `nginx` 使用。

> 本仓库 fork 自 [sbwml/luci-app-quickfile](https://github.com/sbwml/luci-app-quickfile)，自维护 **LuCI 视图 + nginx 集成层 + 构建脚本**；Go 后端二进制 vendored 到 `vendor/quickfile/`（git-lfs）。
>
> **出包范围只有 x86_64。** 本仓库不再提供 aarch64 / arm 的 apk 或 ipk。

## 出包范围与架构

- **只发 x86_64**。apk 只接受与系统架构完全一致的架构名，或恰好是 `noarch`；opkg 的架构列表也来自 `ARCH_PACKAGES`（`x86_64`、`aarch64_cortex-a53`、`arm_cortex-a9` …）。`aarch64`、`arm` 这类写法在真机上不是合法架构，包会被 apk 判定为不可安装、被 opkg 直接忽略，因此不再产出。
- **架构无关包**：`luci-app-quickfile`、`luci-i18n-quickfile-zh-cn` 在 apk 中用 `noarch`，在 ipk 中用 `all`。
- 一次 release 固定 3 个 apk + 3 个 ipk（后端 + 前端 + 可选中文包）。用同一版本再触发一次会重新构建并覆盖该 release 的同名资产。
- `vendor/quickfile/` 目前只保留 x86_64 的 vendored tarball。若要重新支持其他架构，需要重新下载上游对应二进制、更新 `SHA256SUMS`，并把 `.github/build-pkg.sh` 中硬编码的 `ARCH` 改回可选参数。

## 文档

- [安装与访问方式](docs/install.md) —— apk/opkg 安装命令、菜单位置、nginx 集成、以及 https/域名/http 三种访问方式的实际行为。
- [构建、校验与跟版](docs/build.md) —— 三重校验链、可复现时间戳、本地构建工具链、上游版本探测与人工跟版步骤。

## 功能

- **文件管理。** 浏览、创建、重命名、移动、删除文件和文件夹。支持拖拽上传、URL 下载。`zip`、`tar.gz`、`tar.xz` 压缩/解压。查看文件大小、目录内容，计算 MD5/SHA256 校验值。
- **命令终端。** 在当前目录执行系统命令。`Ctrl + Shift + C` 复制，`Ctrl + Shift + V` 粘贴。
- **软件包安装。** 直接安装上传的 `.apk` 或 `.ipk` 文件。后端分别调用 `/usr/bin/apk add --allow-untrusted` 和 `/bin/opkg install --force-downgrade`，因此只会对系统里实际存在的包管理器生效（apk 系统上的 `opkg` 分支必然失败）。
- **媒体预览。** 浏览器内预览常见图片和视频格式。
- **文本编辑器。** Monaco 编辑器，支持多种配置文件和脚本语言的语法高亮。
- **多语言。** 界面文案由后端内置，按浏览器语言提供简体/繁体中文，其余语言回退英文。本仓库的 `luci-i18n-quickfile-zh-cn` 只翻译 LuCI 菜单项，不含界面文案。

## 升级与回滚

- 从旧版本升级：新版本的 post-install 会自动修复旧版本对 `/etc/config/nginx` 的改动，无需手工干预。
- `/etc/ssl/quickfile/` 是自签证书目录：仅当 `_lan` 用的是 nginx-util 自签证书时本包才会创建/接管它；若你用自己的证书，本包不会创建。确认没有其他配置引用后可直接删除：`rm -rf /etc/ssl/quickfile`。
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
- 验证状态：apk 路径（x86_64）已在 ImmortalWrt 25.12.1 上**全新安装**实测通过——`https://<lan-ip>/`（管理员自己的 ACME 证书场景）、`https://<域名>/`、以及 `http://<lan-ip>/` 自动 301 到 https 均正常；ipk/opkg 路径由同一个打包脚本产出、CI 只校验其 control 字段，未在 opkg 真机上实测。
- `_lan` 使用管理员自己的证书（ACME 等）时，按 IP 访问仍会看到证书告警（域名证书不覆盖 IP），这是证书本身的性质，功能不受影响。
