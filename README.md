# luci-app-quickfile

OpenWrt 上的轻量级网页端文件管理器。2.x 后端用 Rust(Axum) 构建，前端是 Vue 3 + Vite + Tailwind，随包安装。

> 本仓库 fork 自 [sbwml/luci-app-quickfile](https://github.com/sbwml/luci-app-quickfile)，自维护 **CI 构建与出包**。
>
> **上游不发布任何 apk/ipk**（仓库里没有 CI、没有 release），官方源（ImmortalWrt / OpenWrt）里也没有这个包。本仓库把上游源码编译成自己的 apk，只发 **x86_64**。

## 出包范围与架构

- **只发 x86_64**。apk 只接受与系统架构完全一致的架构名，或恰好是 `noarch`；`aarch64`、`arm` 这类写法在真机上不是合法架构，包会被 apk 判定为不可安装。
- **架构无关包**：`luci-app-quickfile`、`luci-i18n-quickfile-zh-cn` 在 apk 中用 `noarch`。
- 一次 release 固定 3 个 apk（后端 + 前端 + 可选中文包）。用同一版本再触发一次会重新构建并覆盖该 release 的同名资产。
- **只出 apk，不出 ipk**。需要 opkg 的旧系统请自行用上游源码在 OpenWrt 树里编译（见上游 README 的编译指南）。

## 构建来源与校验

后端二进制不是上游的预编译产物，而是**本仓库的 CI 从上游源码编译**的：

| 项 | 值 |
|---|---|
| 上游源码包 | `https://r2.cooluc.com/source/quickfile-src-<版本>.tar.xz` |
| 校验 | 包 sha256 钉在 `quickfile/Makefile` 的 `PKG_HASH`，编译前校验 |
| 编译器 | Rust 1.99.1（版本化 dist 包 + 官方 sha256，CI 里校验） |
| 目标 | `x86_64-unknown-linux-musl`，静态链接 |
| 依赖 | 只有一个补丁：把上游 `xz2` 的依赖改成 `features = ["static"]`，把 xz 解压器编进二进制（上游默认链系统 liblzma，在 musl 上跑不起来） |

release 说明里会附上上游源码 sha256、后端二进制 sha256 和编译器版本。详见 [构建与跟版](docs/build.md)。

## 文档

- [安装与访问方式](docs/install.md) —— apk 安装命令、菜单位置、nginx 集成、以及 https / http 访问的实际行为。
- [构建、校验与跟版](docs/build.md) —— CI 的两个 job、校验链、工具链钉死方式、上游版本探测与人工跟版步骤。

## 功能

- **文件浏览与管理。** 列表与网格两种视图，按名称/体积/修改时间排序，分页流式加载，框选与多选；目录树侧边栏懒加载；右键新建、重命名、chmod、属性、复制、剪切、粘贴、压缩与解压。
- **传输与上传。** 拖拽移动文件与文件夹（保留目录层级），`Ctrl+V` 剪贴板粘贴上传，上传管理面板（进度、速率、取消、覆盖/重命名策略），远程 URL 下载。
- **归档与压缩。** 支持 `zip`、`gz`、`tar`、`tar.gz`、`tar.xz`、`tar.zst`、`ipk`、`apk`、`img`、`ext4`、`squashfs`；ZIP 支持 WinZip AES-256 加解密。
- **多媒体与文档预览。** 图片浏览器（平移/缩放/翻页）、音视频播放器（倍速/画中画/全屏）、PDF 阅读器（滚动/旋转/分页/全文检索）。
- **终端与编辑器。** 内置 xterm.js 终端（WebSocket，自动定位当前目录）；CodeMirror 6 代码编辑器，40+ 语言高亮，内置 `uci`、`ucode` 语法；右键一键格式化（JS/TS/JSON/CSS/Less/SCSS/HTML/Vue/Markdown/YAML/shell/Lua）；`.md` 走 GitHub 风格渲染，`.html` 以沙箱 iframe 预览。
- **文件属性与校验。** 查看大小、目录内容、属主属组，计算 MD5/SHA-256。
- **多语言。** 界面文案由后端内置，按浏览器语言提供简体/繁体中文，其余语言回退英文。本仓库的 `luci-i18n-quickfile-zh-cn` 只翻译 LuCI 菜单项，不含界面文案。

## 鉴权模型

2.x 的后端**直接用本地 ubus 校验 LuCI 会话**（`ubus_rpc_session`），依次读取 `sysauth_http` / `sysauth_https` / `sysauth` 三种 cookie 名，因此：

- 不需要任何 cookie 改写，也不需要额外的回环监听端口；
- 会话是否有效由 rpcd/ubus 判定，DNS、证书、访问规则都不影响；
- 必须从已登录的 LuCI 会话访问，且依赖 nginx 反向代理。

## 升级与回滚

- 升级：新版本的 post-install 会确保 nginx 的 `_lan` server 仍 include `conf.d/*.locations`，并在 nginx 拒绝新配置时自动回滚。
- 手工回滚 nginx 配置：

```sh
uci import < /root/backup/nginx-uci-<时间戳>.txt
/etc/init.d/nginx reload
```

## 许可证

- 本仓库的 CI 脚本与文档：Apache License 2.0，见 [LICENSE](LICENSE)。
- 后端二进制由本仓库的 CI 从上游 Apache-2.0 源码工程（<https://git.cooluc.com/sbwml/quickfile>）编译；许可证与来源说明随包安装到 `/usr/share/licenses/quickfile/`，详见该目录的 `NOTICE`。

## 已知限制

- 未提供非 root 的 ACL，菜单只对 root 可见。
- 后端以 `-dir /` 运行且带命令终端，权限等同 root。请自行确认 `_lan` 仍然限制来源网段：stock 模板会在 `_lan` 的 include 里放 `restrict_locally`（只允许回环与私网地址），本包不会改动它，但如果你手工删过这个 include，`443` 上就是全放开。
- 验证状态：**apk 路径（x86_64）待实机验证**——CI 已能产出 3 个 apk，但本仓库的这套 2.x 包尚未在真机上做过全新安装实测（1.0.25 时代的包曾实测通过，2.x 的鉴权模型完全不同，需要重新验证）。
