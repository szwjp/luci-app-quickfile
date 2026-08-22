# luci-app-quickfile

`luci-app-quickfile` 是一款专为 OpenWrt 设计的轻量级网页端文件管理器。由于 quickfile 直接使用 OpenWrt 令牌进行登录验证，它需要依赖 `nginx` 配合使用，这可能会让你的 LuCI 失去工作。

## 相关设置

 - **禁用不可信的 SSL 证书（程序拒绝通过不可信的证书获取 Session ID）**

```nginx
# nginx
uci set nginx.global.uci_enable='true'
uci del nginx._lan
uci del nginx._redirect2ssl
uci add nginx server
uci rename nginx.@server[0]='_lan'
uci set nginx._lan.server_name='_lan'
uci add_list nginx._lan.listen='80 default_server'
uci add_list nginx._lan.listen='[::]:80 default_server'
uci add_list nginx._lan.include='conf.d/*.locations'
uci set nginx._lan.access_log='off; # logd openwrt'
uci commit nginx
service nginx restart
```

 - **HTTPS 兼容（LuCI 保持 HTTPS）**

`quickfile` 会反向请求 `{host}/cgi-bin/luci` 校验 LuCI 会话，`{host}` 来自 `quickfile.locations` 里的 rewrite：`host=$scheme://$http_host`。因此 https 下能否工作，取决于这个回环请求所用的地址/证书：

1. **用你证书所覆盖的域名访问**（例如证书是 `wjp-family.top`，就用 `https://wjp-family.top`）。回环请求 `POST https://wjp-family.top/cgi-bin/luci` 的证书会通过校验——这是推荐姿势。注意该域名需能被路由器自身解析回本机（DNS 回环 / hairpin NAT），否则回环请求到不了 LuCI。
2. **用 IP（如 `https://192.168.1.1`）访问时**，必须让证书同时覆盖该 IP（把 IP 加进证书 SAN）。Let's Encrypt 通常不签发 IP SAN，此时需用自签/私有 CA 证书同时覆盖域名与 IP 并在浏览器中信任；否则 quickfile 内部回环校验会因证书与 IP 不匹配而失败，报 `Session verification failed: tls: ... no alternative certificate subject name`，与上游 issue #4 相同。
3. **`-insecure` 参数在 quickfile v1.0.25 中不存在**（已实测当前最新版二进制与仓库打包的二进制均无此 flag），因此无法用跳过 TLS 校验的方式兜底；IP 访问需靠上述证书覆盖来解决。
4. 若 LuCI 走的是**非标 HTTPS 端口**，本仓库已把 rewrite 的 `$host` 改为 `$http_host` 以保留端口，避免回环校验打到默认 443。

<details>
<summary>提醒：反代/CDN 场景</summary>

- 若域名套了 Cloudflare/CDN 等反代，quickfile 的内部回环校验请求（到 `{host}/cgi-bin/luci`）可能到达的是反代而非路由器，此时需让该请求绕过反代，或改用其它方案。
</details>

 - **文件上传大小受限**

通过编辑 `/etc/nginx/conf.d/quickfile.locations` 文件并修改 `client_body_temp_path` 临时目录为大容量目录可避免文件上传大小受限而失败。

https://github.com/sbwml/luci-app-quickfile/blob/5d863b91bc1d555dea65ecce6e30786c7d12273e/quickfile/files/quickfile.locations#L1-L8

---

## 功能简介

### 界面
- 支持简繁英语言切换。
- 更多的互交操作在使用中发现...

### 文件管理
- 基础操作：支持目录浏览、文件/文件夹的创建、重命名、移动和删除。
- 便捷传输：提供标准的文件上传与下载功能，并支持通过浏览器拖拽直接上传文件，同时支持在线下载文件。
- 解压缩：支持 `zip`、`tar.gz`、`tar.xz` 文件的压缩/解压。
- 属性：支持查看/统计文件或文件夹大小、数量，支持计算文件 MD5/SHA256。

### 命令终端
- 实时命令行：内置网页终端功能，支持直接在管理界面中执行当前目录系统命令，便于用户进行快速批量操作文件、调试与系统维护。
- 快捷键：  复制：`Crtl + Shift + C`.      粘贴：`Crtl + Shift + V`

### 软件包安装 (IPK / APK)
- 直接安装：支持在网页端直接执行本地上传的 `.ipk` 或 `.apk` 软件包安装。
- 依赖解析：当出现安装失败或缺少依赖时，支持同步刷新软件源并尝试自动补齐依赖。
- 状态反馈：内置安装日志捕获，清晰输出安装成功或失败的反馈信息，便于故障排查。

### 媒体预览
- 多媒体支持：支持主流格式的图片和视频预览，无需下载至本地即可直接在浏览器中查看。

### 文本编辑器
- Monaco 核心：集成轻量化 Monaco Editor 文本编辑器。
- 代码高亮：支持多种配置文件及脚本语言的语法高亮显示，方便用户直接在线编辑和调整路由器配置。
