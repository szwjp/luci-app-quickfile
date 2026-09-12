# luci-app-quickfile 审查报告

- 审查对象：`github.com/szwjp/luci-app-quickfile`，`main` @ `1464914`（2026-09-12 09:10 +0800），本地工作区与该 commit 一致、无未提交改动
- 上游对照：`github.com/sbwml/luci-app-quickfile` `main` @ `4baa2bd`
- 审查日期：2026-09-12
- 方法：读全部受控文件（含 CI 脚本、打包脚本、LuCI 视图、nginx 配置、i18n）＋ 下载 release 资产实际解包核对 ＋ 核对 OpenWrt / opkg / apk-tools / nginx / nginx-util 的一手源码与官方下载站数据。所有结论都标注了验证方式；未验证的推测单独标出。

---

## 0. 结论

代码组织、注释、LFS vendoring、ipk 打包细节都比一般 LuCI 应用仓库讲究，**但当前 Release 产物在真实设备上装不上，且 nginx 自动配置逻辑写错了开关**。四个高危问题里，H1 会让 aarch64/arm 用户拿不到任何可用包、apk 用户拿不到 LuCI 前端；H2/H3 让"装完即用"的 HTTP/证书/监听器配置要么完全不生效、要么把 nginx 配置写坏。建议在发布说明或修复前先把 README 的"三个架构 + 开箱即用 HTTPS"降级为"x86_64 / 手动安装"。

严重度统计：高危 4、中等 12、轻微 9。

---

## 1. 先确认没问题的部分（避免误判）

这些点看着可疑，但核对后是**正确**的，不用改：

| 项 | 核对依据 |
|---|---|
| `.ipk` 是"gzip 压缩的 tar（内含 debian-binary/data.tar.gz/control.tar.gz）"而不是 ar 归档 | OpenWrt 官方 `scripts/ipkg-build` 末段就是 `tar ... | gzip -n - > pkg_file`，我们的产物与其一致 |
| ipk 的 `Architecture: all` | opkg 在未配置 arch 时默认注入 `all:1 / noarch:1 / HOST_CPU:10`（opkg-lede `libopkg/opkg_conf.c:549-552`），`all` 合法 |
| `Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD` 占位符 | `ipkg-build` 会 sed 覆写该字段，实测产物为 `Installed-Size: 5580800` |
| apk 产物开头 `ADBd` 不是损坏文件 | 那是 apk-tools v3 的 ADB 块格式；本仓库固定使用 OpenWrt 同款 apk-tools commit `b5a31c0`，格式匹配 |
| `vendor/quickfile/*.tar.gz` 是真正的 git-lfs 对象 | `git cat-file -s` = 132B 指针，worktree 为 5MB 实体；`.gitattributes` 生效 |
| nginx `location /cgi-bin/luci/quickfile`（前缀）不会被 luci-nginx 的 `location /cgi-bin/luci`（同为前缀）抢走 | nginx 取最长前缀匹配；luci.locations 里唯一的正则 `~ /cgi-bin/cgi-(backup\|download\|upload\|exec)` 不匹配该路径 |
| ~~`uci add_list nginx._lan.listen="443 ssl"` 与默认的 `443 ssl default_server` 共存~~ | **【2026-09-12 更正：此条判断错误】** 真机验证：同一 server 块内 `listen 443 ssl default_server;` 与 `listen 443 ssl;` 会让 nginx 直接 `[emerg] a duplicate listen 0.0.0.0:443` 启动失败（`ngx_http_add_server()`，nginx 1.26.2 `src/http/ngx_http.c:1528`）。旧脚本这一步本身就是致命的 |

---

## 2. 高危 / 阻断

### H1　包架构元数据错误：apk 前端包装不上，arm/aarch64 全部装不上

**现象**
- 两个 noarch 包的 apk 用 `arch:all`（`.github/build-pkg.sh:291-294`）。
- `quickfile` 的 apk/ipk 直接用 `x86_64` / `aarch64` / `arm`（`:324-328`、`:327`）。

**证据**
1. apk 只接受"与系统 arch 完全相等"或"恰好 `noarch`"：apk-tools `src/database.c:558-563` `apk_db_arch_compatible()`（逐字比较 + `db->noarch == arch`），不兼容即 `pkg->uninstallable = 1`（`:585`），而 `src/solver.c:214` 中 `pkg_selectable = !pkg->uninstallable && …` → **永远不会被选中安装**。
2. OpenWrt 自己打包时显式把 `all` 映射成 `noarch`：`include/package-pack.mk:613` `$(if $(findstring all,$(PKGARCH)),--info "arch:noarch",…)`，反过来证明 `apk mkpkg` 不会自动纠正 `all`（`src/app_mkpkg.c` 无任何 arch 归一化）。
3. OpenWrt 的实际系统 arch = `ARCH_PACKAGES`，不是 CPU 家族名。实测下载官方 aarch64 snapshot rootfs：`/etc/apk/arch` 内容为 **`aarch64_generic`**（`downloads.openwrt.org/snapshots/targets/armsr/armv8/openwrt-armsr-armv8-rootfs.tar.gz`），`distfeeds.list` 也指向 `packages/aarch64_generic/`。`arm`/`aarch64` 从未出现在官方包架构列表中（`downloads.openwrt.org/releases/24.10.0/packages/`：`aarch64_cortex-a53`、`aarch64_generic`、`arm_cortex-a9`…）。
4. opkg 侧同理：目标 arch 通过 `-DHOST_CPU=$(PKGARCH)` 编译进 opkg（`package/system/opkg/Makefile`），未在 `/etc/opkg/*.conf` 声明时 arch 列表 = `all/noarch/HOST_CPU`；包 `Architecture` 不在列表中会被直接丢弃：`libopkg/pkg_hash.c:130` "Package %s version %s has no valid architecture, ignoring."，安装侧 `libopkg/opkg_install.c:1262` 走 unsupported architecture 分支。

**实际影响**
- apk 系统（OpenWrt main / 已切 apk 的固件）：`luci-app-quickfile-*.apk`、`luci-i18n-*.apk` 因 `arch:all` **任何设备都装不上**；`quickfile-*.apk` 仅在 `x86_64` 设备上 arch 恰好相等才可装。
- opkg 系统（24.10 / ImmortalWrt）：只有 `quickfile_*_x86_64.ipk` 可用；`aarch64` / `arm` 两个 ipk 会被 opkg 忽略。
- 即 README 第 5、9 行宣称的"三架构 apk + ipk"里，**aarch64/arm 全部不可用**；x86_64 也只能装后端不能装前端。

**建议**
1. apk：noarch 包必须传 `arch:noarch`（照抄 package-pack.mk 的写法）。
2. 架构输入不要用 `arm`/`aarch64`，改为真实 `ARCH_PACKAGES`（apk 与 ipk 都适用），例如 `arm_cortex-a9`、`arm_cortex-a7_neon-vfpv4`、`aarch64_cortex-a53`、`aarch64_generic`——按子架构列出，并把 CI input 从 3 项扩成实际要支持的列表。
3. 在 README/Release 里明确"每个包只对 exact 架构生效"，或干脆只发 x86_64 并在 README 里注明。
4. 至少补一条真机冒烟验证（在 ImmortalWrt / apk 快照上 `apk add --allow-untrusted ./x.apk`），CI 里没有这一步，所以这个错误一直没被发现。

### H2　nginx 自动配置的开关判断错误，整套"开箱即用"配置静默失效

**现象**：`configure_nginx.sh:51`

```sh
[ "$(uci -q get nginx.global.uci_enable 2>/dev/null)" = "1" ] || return 0
```

**证据**：OpenWrt 的 nginx-util 出厂 `/etc/config/nginx` 是 `option uci_enable 'true'`（`openwrt/packages net/nginx-util/files/nginx.config`，安装到 `/etc/config/nginx`，见该包 Makefile:66），而 nginx-util 自己判断是否启用时是"存在且非空即为真"（`src/nginx-util.cpp:178-199` `is_enabled()`，'true' 也算启用）。脚本却要求字面量 `1`。

**影响**（默认配置下）
- `generate_cert()` 不执行 → `/etc/ssl/quickfile/quickfile-ip.crt` 不会生成。
- 80/443 监听器、`include conf.d/*.locations` 都不会写入。
- `_redirect2ssl` 不会被删除，http→https 302 仍然存在。
- 结论：README 第 30、34 行"post-install 会自动生成自签证书并配置 nginx，`http://<lan-ip>/` 与 `https://<lan-ip>/` 均可访问""把 `/etc/ssl/quickfile/quickfile-ip.crt` 导入受信任根"**都不成立**。
- 应用本身仍可用，但那是"意外生效"：默认 `_lan` 本来就 `list include 'conf.d/*.locations'`（同一个 nginx.config），`quickfile.locations` 被装到 `/etc/nginx/conf.d/` 后由默认 443 服务器代理到 unix socket。

**建议**：改成与 nginx-util 一致的真值判断（例如 `case "$(uci -q get nginx.global.uci_enable)" in 1|true|on|yes) ;; *) return 0;; esac`），或者直接判断 `nginx._lan` 段是否存在即可。同时 README 要么写清"需要 `uci_enable=true`"，要么把脚本行为同步修正。

### H3　`uci add_list` 不是幂等的：重复 include 会让 nginx 起不来，且每次安装/升级都往配置里塞垃圾

**现象**：`configure-nginx.sh:71-76`

```sh
# Listeners (add_list is idempotent — duplicate entries are no-ops).
uci add_list nginx._lan.listen="80"
...
uci add_list nginx._lan.include="conf.d/*.locations"
```

注释"add_list is idempotent"是**错的**。

**证据**
1. `uci_add_list()` 无条件 `uci_list_add(&ptr->o->v.list, &e1->list)`，不去重（openwrt/uci `list.c:595-635`）。
2. nginx-util 把 uci 段逐条渲染：`for (opt) for (itm) conf += opt.name() + " " + itm.name() + ";\n"`，不去重（`src/nginx-util.cpp:117-135`）。所以重复的 list 项 = 重复的 nginx 指令。
3. 默认 `_lan` 段**本来就包含** `list include 'conf.d/*.locations'`（nginx.config），脚本再 add 一次 → 生成的 server 块里出现两行 `include conf.d/*.locations;`。
4. nginx 对重复的 location 是 EMERG 致命错误：`duplicate location "%V" in %s:%ui`（nginx 1.26.2 `src/http/ngx_http.c:1020`）。luci.locations / quickfile.locations 里的 `location /cgi-bin/luci` 等会被定义两次。

**影响**（当 `uci_enable` 恰好为 `1`，即 H2 的另一个分支时）
- `uci commit nginx` **先落盘**，随后 `/etc/init.d/nginx reload` 被 `|| true` 吞掉（`:83`）→ 安装时没有任何报错，但配置已经坏了。
- 当前 nginx 进程仍跑旧配置，**下次 nginx 重启/设备重启后 nginx 起不来**，LuCI 管理页面整体不可用（只能 SSH 修 `/etc/config/nginx`）。
- 另外每次重装/升级都会追加 4 条 `listen` + 1 条 `include`，`/etc/config/nginx` 无限膨胀。

**建议**
1. 用 `uci -q del_list nginx._lan.include='conf.d/*.locations'` 后再 add，或直接不添加（默认已有）。
2. `listen` 同理：先 `del_list` 再 `add_list`，且 `443 ssl` 本来就有了，不需要再加。
3. 提交前做 `nginx -t` 校验，失败就回滚 uci
   （`uci export` 备份已经在做：`:55-57`，但没有用在失败回滚上，只当"用户自己回滚"的文档）。
4. 不要吞掉 `nginx reload` 的错误，至少在 syslog 里留一条明确日志。

### H4　发布版本与 release tag 会不一致；自动同步的第三方二进制未经任何校验就被提交并发布

**现象 A：版本漂移**。build 脚本把"upstream 探测到的版本"当成构建版本：
- `.github/build-pkg.sh:79-89` 从 Makefile 版本开始按 **patch +1** 探测，`:120` `ACTIVE_VERSION="$LATEST_UPSTREAM"`，`:141` `PKGVER="${ACTIVE_VERSION}-r${RELEASE}"`。
- 而 release tag / release 名 / 附件所属 release 都用 **Makefile** 版本：`.github/workflows/build.yml:46-52`、`:73`、`:183`。

后果：若 upstream 发了 1.0.26 而 `luci-app-quickfile/Makefile` 仍是 1.0.25，则 release 是 `v1.0.25-r1`，里面挂的资产却是 `quickfile-1.0.26-r1.apk`、`luci-app-quickfile-1.0.26-r1.apk`（连前端包版本都被改写成 1.0.26）。tag 与内容不一致，且"同版本覆盖发布"会把不同 upstream 版本的内容混进同一 tag。

**现象 B：供应链**。`:98-120` 一旦发现 upstream 新版本，就 `curl` 下载 `r2.cooluc.com/source/quickfile-<v>.tar.gz`、按架构重新打包、**直接覆盖** `vendor/quickfile/`，再由 `build.yml:158-169` 自动 `commit + push origin main`，然后发布给用户。整个过程：
- 没有对"新版本"做任何 hash/签名校验（`:134-138` 的校验条件 `ACTIVE_VERSION = QUICKFILE_VERSION` 在此分支必然为假，即该校验对新版本永远不生效）；
- `PKG_HASH`（`quickfile/Makefile:23`）在稳态（vendored == Makefile == upstream，不下载）下同样永不校验，因为 `UPSTREAM_TARBALL` 只在 `:100` 被创建；
- 变量 `USE_UPSTREAM`（`:74`）赋值后从未使用，属死代码。

后果：上游对象存储一旦被投毒/被劫持，本仓库会自动把恶意二进制提交进 main 并发布成安装包，用户在路由器上以 root 运行。这与仓库自己"保证可复现构建"的目标也矛盾。

**现象 C：探测逻辑脆弱**。`:81-89` 只递增 patch 位，upstream 若跳到 1.1.0（1.0.26 不存在），第一次探测（当前版本，存在）成功、第二次（1.0.26）失败即 break，`LATEST_UPSTREAM` 仍是当前版本 → 被当成"已是最新"，新版静默漏掉。

**建议**
1. 版本唯一真相源：探测到 upstream 新版本时，把 `PKG_VERSION` 一起改掉（或直接把 `PKG_VERSION` 作为 tag 来源），绝不让 tag 与包内版本分叉；两者不一致时直接 fail。
2. 对 upstream 新版本强制人工介入：CI 只做"发现新版本 → 开 issue/PR 更新 Makefile + PKG_HASH"，不要自动 commit+push 二进制。
3. 若坚持自动同步，至少要求 upstream 提供校验和或签名，并在 README/Release 里给出上游源码地址（同时解 H4/合规问题）。
4. 探测改成"读取 upstream 目录列表 / 用 semver 全量递增"，不要只 +patch。

---

## 3. 中等问题

### M1　apk 文件名不含 arch，多架构会互相覆盖，README 描述与实现矛盾
`build_apk` 输出固定为 `${name}-${version}.apk`（`build-pkg.sh:233`），apk v3 规范如此；但 `softprops/action-gh-release` 对同名资产是覆盖上传。所以 README:15 的"一次 release 只产选定架构的 apk；其他架构的 apk 需再 trigger 一次"**做不到**：第二次 trigger aarch64 会把已有的 `quickfile-1.0.25-r1.apk`（x86_64）覆盖掉，一个 release 永远只能留一个架构的 apk。ipk 因为文件名嵌入 `_x86_64` 反而可以共存——这个不对称要在 README 里写清楚。当前 release 实际只有 6 个资产，其中 aarch64/arm 一个都没有，也印证了这一点。

### M2　构建不可复现，"同版本覆盖发布"因此不可审计
`build-pkg.sh:47-48` `SOURCE_DATE_EPOCH=$(date +%s)`。ipk 用它写 tar mtime 和 `SourceDateEpoch` 字段；apk 包也带 build_time 字段。每次触发同一版本都会产出字节不同的包（H4 的"覆盖同名资产"于是变成静默换包）。OpenWrt 官方对 apk 是固定 `SOURCE_DATE_EPOCH=0 apk mkpkg`（`include/package-pack.mk:606`）。建议固定为最后一次相关 commit 的时间（`git log -1 --format=%ct`）或 0。

### M3　构建期依赖未固定
- `.github/workflows/build.yml:138` 直接从 `openwrt/openwrt master` 下载 `scripts/ipkg-build` 并以 root 安装执行：上游一次改动（该脚本确实在演进，`-m` 语义、Installed-Size 覆写都依赖它）就能静默改变产物或破坏构建。应固定到某个 commit 并校验 sha256。
- 第三方 action 未按 commit SHA 固定：`actions/checkout@v4`、`softprops/action-gh-release@v2`（`:34/71/88/94/102/181`）。与之形成对比的是 apk-tools 被精确固定到了 `b5a31c0`（`:99`）——标准应统一。

### M4　GPL-3.0 二进制再分发的合规缺口
`quickfile/Makefile:25-28` 注释称"The Go binary's own license ships inside the tarball"。实测不成立：`tar -tzf vendor/quickfile/quickfile-1.0.25-{x86_64,aarch64,arm}.tar.gz` 各自只有一个 `quickfile.<arch>` 可执行文件，**既无 LICENSE 也无源码**。仓库根只有 Apache-2.0 的 `LICENSE`（覆盖的是本仓库 LuCI 集成代码），README 也没有指向 quickfile 的 GPL-3.0 源码。upstream 仓库确实有源码分支（`upstream/v1.0.24-src`，含 `main.go`、`internal/`），但本仓库的包和文档都没引用它，且源码分支停在 1.0.24 而二进制是 1.0.25。
建议：README + Release 说明里给出上游对应版本源码地址与 GPL-3.0 声明，并在 vendored tarball 里带上 LICENSE；`PKG_LICENSE_FILES:=LICENSE` 目前指向的是不存在的包内路径。

### M5　按标准 feed 方式构建走不通
`quickfile/Makefile` 有 `PKG_SOURCE/PKG_HASH/Package/quickfile`，但**没有** `Package/quickfile/install`、`Build/Compile`，也**没有** `$(eval $(call BuildPackage,quickfile))`（注释说构建只走 `.github/build-pkg.sh`）。后果：把本仓库作为 feed 加进 buildroot 时，`luci-app-quickfile` 的 `LUCI_DEPENDS:=+luci-nginx +quickfile`（`luci-app-quickfile/Makefile:15`）解析不到 quickfile 包，构建直接失败；即便手动 `make package/quickfile/compile` 也什么都不会产出。要么补齐 `install`/`BuildPackage` 使 feed 路径可用，要么在 README 顶部明确"本仓库不支持 feed 构建，只发 release 包"，并把 Makefile 里的误导性字段清理掉（upstream 的 Makefile 是有 install/BuildPackage 的，这次改动是行为退化）。

### M6　卸载不回收对全局 nginx 配置的修改
`build-pkg.sh:198-205`（apk pre-deinstall）/`:275-281`（ipk prerm）只调 `default_prerm`。卸载后：`/etc/config/nginx` 里被追加的 `listen` / `include` 仍在（含 H3 的重复项）、`ssl_certificate` 仍指向 `/etc/ssl/quickfile/*`（脚本创建的证书不在包文件清单里，opkg/apk 不会删）、`/root/backup/nginx-uci-*.txt` 每次安装都会新增一个。README 只给了手动回滚命令，属于把复杂度转嫁给用户。建议 prerm 里做对称清理（或至少 `del_list` 掉自己加的项并在证书路径缺失时回退 ssl 配置）。

### M7　`client_max_body_size 0` + 默认 body 临时目录在 rootfs，大文件上传会写爆 flash
`quickfile/files/quickfile.locations:5` 关闭了全局请求体上限；该文件被 include 进 `_lan` 服务器块，因此**对整个 LuCI 生效**，不只是 quickfile。OpenWrt nginx 编译参数为 `--http-client-body-temp-path=/var/lib/nginx/body`（`openwrt/packages net/nginx/Makefile:446`），在 rootfs/overlay 上而非 tmpfs；请求体超过 `client_body_buffer_size 128k` 后会整份落盘再转发。上传一个数 GB 的文件就可能占满 overlay。文件里的注释只是"提示用户自己改"，但在 `client_max_body_size 0` 的前提下这是默认路径上的必踩问题。建议 `proxy_request_buffering off;` 直通后端，或给一个受控的 `client_body_temp_path` 并限定该 location 而非 server 级。

### M8　删掉 http→https 跳转 = 整个管理面降级为明文
`configure-nginx.sh:79-80` 删除 `nginx._redirect2ssl` 段和 `/etc/nginx/conf.d/000-https-redirect.locations`。影响面是**整个 Web 管理界面**（LuCI 本身也在 `_lan` 上），root 口令与会话 cookie 会在局域网里明文传输；而 quickfile 后端带"命令终端"能力，风险更高。README 又把"HTTP 和 HTTPS 都可访问"当卖点，并建议导入自签根证书——两者互相矛盾。建议保留跳转，或只给 quickfile 加一个显式的 `http://<ip>/cgi-bin/luci/quickfile` 例外（且前提是该后端自身有认证）。

### M9　`$http_host` 与 rewrite 的 query 处理
`quickfile/files/quickfile.locations:26` 相对 upstream 把 `$host` 改成了 `$http_host`（`:34` 同），并把两个 location 合并。`$http_host` 直接来自 Host 头、未规范化（可能带端口/异常字符），会原样进入后端 `host=` 参数；upstream 用 `$host` 更稳，建议改回。
**【2026-09-12 更正】** 原文说"rewrite 目标串带 `?` 会丢掉原 query string"是**错的**：nginx 的语义是——replacement 里带新参数时，原请求参数会**追加**在新参数之后（不想要才需要在结尾补一个 `?`；见 nginx rewrite 模块文档）。所以 `/api/x?a=1` → `/api/x?host=...&a=1`，参数不会丢。此条只剩 `$http_host` 一个点。

### M10　包未签名，README 未提示 apk 需要 `--allow-untrusted`
apk 侧 `apk mkpkg` 未加 `--sign`（`build-pkg.sh:222-233`），OpenWrt 官方镜像带 `/etc/apk/keys/openwrt-snapshots.pem` 且默认校验签名，因此本地安装未签名 apk 需要 `apk add --allow-untrusted ./x.apk`（apk-tools 中 `--allow-untrusted` 存在并置 `APK_ALLOW_UNTRUSTED`，`src/apk.c:43/93`）。README 的安装章节完全没提，用户会撞 "UNTRUSTED signature"。ipk 侧 opkg 默认不校验（`CONFIG_SIGNATURE_CHECK` 关闭），暂不受影响。建议 README 补命令，并在 release body 里也写一次（当前 release body 只有一行 shields badge，没有任何安装说明）。

### M11　`PKG_HASH` 基本处于"永不生效"状态
见 H4-B：稳态不下载 → 无对象可校验；自动同步分支版本不等 → 条件为假。也就是说 `quickfile/Makefile:23` 记的 sha256 目前没有任何校验路径，`USE_UPSTREAM` 也是死变量。要么让 vendored 文件参与校验（例如 CI 里对 `vendor/quickfile/*.tar.gz` 单独记一份 hash 并 `sha256sum -c`），要么删掉这块"看起来很安全"的元数据，避免误导。

### M12　其余 CI 逻辑问题
- `has_update` 恒为 `true`（`build.yml:66`），所以 `if: steps.parse.outputs.has_update == 'true'`（`:70`）、`needs.check.outputs.has_update == 'true'`（`:83`）都是死条件；`LATEST`（`:55`）只用于打印 notice。
- `version_ipk` 输出（`:30`、`:52`）声明后从未被使用，ipk 版本号实际由 build 脚本自己算（`build-pkg.sh:141`）。
- `check` job 先建空 release（`:69-78`），build 失败就留下一个只有 badge、没有资产的 release；同时 build job 里 `ref: main`（`:90`）与 check job 的默认 checkout（触发分支）不一致——从非 main 分支手动触发时，tag 按分支算、包按 main 打。
- 无任何产物校验步骤（没有 `apk manifest` / `apk verify`、没有装进 rootfs 的冒烟测试、没有 shellcheck / `make check-package`）。H1 这类错误本可以在 CI 拦住。

---

## 4. 轻微问题

1. `quickfile/files/quickfile.init:17` `limits core="unlimited"`：给 root 进程放开 core dump，会往磁盘写巨型 core，建议去掉或设为 0。
2. `configure-nginx.sh:63-67` 在缺 openssl 时 `exit 1`，会让 apk/opkg 的事务报失败（文件已解包），用户在路由器上看到一个 GitHub Actions 才认识的 `::error::` 前缀（`:64-65`）。建议改为"告警 + 跳过 HTTPS 配置"，或把 openssl 放进 `DEPENDS`；同理 `:57` 的 `::error::` 写法也应去掉。
3. `configure-nginx.sh:44-47` 证书 825 天、仅 CN/SAN 记当前 LAN IP，IP 变化后不重签；`generate_cert` 只要文件存在就返回（`:41`）。另外 `_lan` 的 `uci_manage_ssl 'self-signed'` 会让 nginx-util 的 cron 校验/重建这个自定义路径证书，重建后 CN 变成 `_lan`，与 README 描述的证书不一致，建议 README 别承诺具体 CN。
4. apk 与 ipk 的 postinst 不一致：ipk 版 source 前有 `[ -f /usr/lib/quickfile/configure-nginx.sh ] &&`（`build-pkg.sh:263`），apk 版直接 `. /usr/lib/quickfile/configure-nginx.sh`（`:165`、`:186`），在非 chroot 的 `--root` 构建场景会因点命令失败而中断（POSIX 下非交互 shell 找不到被点文件会中止）。
5. `quickfile/Makefile` 丢了 upstream 的 `SUBMENU:=Web Servers/Proxies` 和 `DEPENDS:=@(arm||aarch64||x86_64)` 架构约束，只留 `+libc`；`PKG_LICENSE_FILES:=LICENSE` 指向包目录内不存在的文件。
6. `luci-app-quickfile/po/zh_Hans/quickfile.po` 头是非规范写法（`msgstr "Content-Type: ..."` 而非多行 `msgstr ""`，缺 `Language:`），且只翻译了菜单标题一条；LuCI 视图是 iframe，界面文案全在 Go 后端自带的 i18n 里，这个 i18n 包的信息量很低。建议按 luci 的 po 头规范重生成（或直接说明它只覆盖菜单项）。
7. 无 `acl.d` 文件，`admin/system/quickfile` 只对 root 可见；若想支持非 root 账号，需要补 `luci-app-quickfile.json` ACL。
8. `README` 第 17 行说自动同步 commit 带 `[skip ci]` "避免循环"：用 `GITHUB_TOKEN` 推的 commit 本身就不会触发 workflow，这句解释是多余的（无害）。
9. `build-pkg.sh:72` 把临时目录建在 `.github/` 内（`mktemp -d -p "$BASE_DIR"`），失败时会在仓库目录留残留；`vendor` 的版本探测用 `ls ... | head -1`（`:94`），若目录里同时存在多版本会取到不确定的一个（当前会被后面的清理覆盖，但逻辑脆弱）。建议改为按 Makefile 版本精确拼路径 + `trap` 清理。

---

## 5. 建议修复顺序

| 优先级 | 动作 |
|---|---|
| P0 | 修 H1：apk noarch 用 `arch:noarch`；架构输入换成真实 `ARCH_PACKAGES`（或明确只发 x86_64 并改 README）；补一次真机安装验证 |
| P0 | 修 H2 + H3：`uci_enable` 判断与 nginx-util 对齐；所有 `add_list` 前先 `del_list`（`conf.d/*.locations` 直接不加）；提交前 `nginx -t`，失败回滚 uci 备份；把 `nginx reload` 的错误暴露出来 |
| P1 | 修 H4：tag 与包版本强一致校验；停止"自动提交并发布未校验二进制"；上游版本探测支持完整 semver |
| P1 | 修 M1/M10 的文档：README 与 release body 写清每架构、覆盖行为、`--allow-untrusted`、安装顺序 |
| P2 | M2/M3（可复现 + 固定 ipkg-build/action）、M4（GPL 合规）、M5（feed 路径或明确声明不支持）、M6（prerm 清理）、M7（请求体直通）、M8（保留 https 跳转）、M11/M12（清理死逻辑 + 加 CI 校验） |
| P3 | 第 4 节的轻微项 |

---

## 附：关键证据来源

- 本仓库：`luci-app-quickfile/root/usr/lib/quickfile/configure-nginx.sh`、`.github/build-pkg.sh`、`.github/workflows/build.yml`、`quickfile/files/quickfile.locations`、`quickfile/Makefile`、`README.md`
- nginx 重复 location 为致命错误：nginx 1.26.2 `src/http/ngx_http.c:1020`（`duplicate location`），`src/http/ngx_http_core_module.c:4148+`、`src/http/ngx_http.c:1291+`（listen 选项冲突规则）
- uci `add_list` 不去重：openwrt/uci `list.c:595-635`
- nginx-util 默认 uci 配置与渲染方式：openwrt/packages `net/nginx-util/files/nginx.config`、`src/nginx-util.cpp:117-135`、`:178-199`
- apk arch 兼容性：apk-tools `b5a31c0` `src/database.c:558-563,585`、`src/solver.c:214`、`src/apk_arch.h`、`src/apk.c:43`
- OpenWrt apk 打包把 `all` 映射成 `noarch`：openwrt/openwrt `include/package-pack.mk:613`；apk 系统 arch 实测为 `aarch64_generic`（官方 snapshot rootfs `/etc/apk/arch`）
- opkg arch 行为：openwrt/opkg-lede `libopkg/pkg_hash.c:130`、`libopkg/opkg_install.c:1262`、`libopkg/opkg_conf.c:549-552`；`package/system/opkg/Makefile` 的 `-DHOST_CPU=$(PKGARCH)`
- ipk 格式：openwrt/openwrt `scripts/ipkg-build`（外层为 gzip 的 tar，`Installed-Size` 会被 sed 覆写）
- 官方架构列表：`https://downloads.openwrt.org/releases/24.10.0/packages/`
- release 资产实测：`gh release view v1.0.25-r1 -R szwjp/luci-app-quickfile`（仅 6 个资产，无 aarch64/arm；`quickfile-1.0.25-r1.apk` 无架构后缀）

---

# 附录 A：修复记录（2026-09-12）

- 起点：`main` @ `1464914`；终点：本次修复提交（即本文件所在 commit），已推送 `origin/main`
- 出包范围按决定收窄为 **x86_64 only**
- 验证手段：本地集成测试（fake `uci` / `apk` / `ipkg-build` / `po2lmo` / `find` / `curl`）、真机（ImmortalWrt 25.12.1，x86/64，apk 系统，192.168.1.1）、静态检查（shellcheck 0.10.0、actionlint 1.7.7、msgfmt、ruby YAML）

## A.1 逐条处置

| 编号 | 处置 | 主要改动 |
|---|---|---|
| H1 | 已修 | 架构输入固定为 `x86_64`；apk 的架构无关包改用 `arch:noarch`（ipk 仍为 `all`）；`.github/build-pkg.sh` 删除 aarch64/arm 分支；两个 Makefile 加 `@TARGET_x86_64` |
| H2 | 已修 | `configure-nginx.sh` 改为「`uci_enable` 非空即视为启用」，与 nginx-util 的 `is_enabled()` 语义一致（stock 值是 `'true'`） |
| H3 | 已修 | 安装/升级时先做幂等修复：`include`/`listen` 去重（`uci add_list` 不去重）、删除旧版本追加的 `80`/`[::]:80`/`443 ssl`/`[::]:443 ssl`、恢复被旧版本删掉的 `_redirect2ssl`；仅在确实有改动时才 commit + reload，reload 前自带 `nginx -t`（由 init 脚本执行），失败则 `uci import` 回滚备份 |
| H4 | 已修 | 删除构建期自动同步（不再下载/覆盖/自动提交二进制）；版本唯一来源是 Makefile，并与 release tag 强一致；改为「vendored `SHA256SUMS` + 上游 `PKG_HASH` + 上游二进制与 vendored 二进制逐字节一致」三重校验，任一步失败即中止 |
| M1 | 随 H1 消失 | 单一架构，不再有多架构互相覆盖；README 明确「同版本重跑覆盖同名资产」 |
| M2 | 已修 | `SOURCE_DATE_EPOCH` 不再是构建时刻，改为取**最后一次改动打包内容**的提交时间（`git log -1 --format=%ct -- .github/build-pkg.sh LICENSE quickfile luci-app-quickfile vendor/quickfile`）；apk/ipk 都继承该值。只改 README/CI 的提交不会改变产物，同一打包内容重跑逐字节相同（已用两次 workflow 运行对比验证） |
| M3 | 已修 | `actions/checkout`、`softprops/action-gh-release`、apk-tools、po2lmo 全部固定到 commit SHA；`ipkg-build` 固定到 `openwrt@f0d3e33` 并校验 sha256 后才以 root 安装 |
| M4 | 已修（并更正事实） | 上游源码 LICENSE 实为 **Apache-2.0**（与仓库根 LICENSE、上游 main 的 LICENSE 逐字节相同），原文的 GPL-3.0 说法有误；`quickfile/Makefile` 改为 `Apache-2.0`，新增 `quickfile/LICENSE`、`quickfile/NOTICE`（含上游源码地址）并随包安装到 `/usr/share/licenses/quickfile/` |
| M5 | 已修 | `quickfile/Makefile` 补回 `Build/Compile`、`Package/quickfile/install`、`$(eval $(call BuildPackage,quickfile))`、`SUBMENU`，feed 路径可用；`PKG_HASH` 实测与上游 tarball 一致 |
| M6 | 已修（简化） | 包不再创建证书、不再改 listen，只确保 `conf.d/*.locations` 被 include（stock 默认已有）；卸载后没有需要回收的残留；旧版本留下的痕迹由安装时的修复逻辑清理 |
| M7 | 已修 | `client_max_body_size 0` 移入 quickfile 的 location（http 级 128M 保留），并加 `proxy_request_buffering off`，大文件不再落盘到 overlay |
| M8 | 已修 | 不再删除 `_redirect2ssl`、不再删除 `000-https-redirect.locations`、不再给 `_lan` 加 80 监听；http→https 跳转保持 |
| M9 | 部分已修 + 更正 | `$http_host` → `$host`（两处 rewrite）；原文"query 会丢失"的说法已更正（nginx 会追加原参数） |
| M10 | 已修 | README 与 release 说明都补上 `apk add --allow-untrusted`（包未签名） |
| M11 | 已修 | `PKG_HASH` 现在真的会被校验（每次构建都下载上游 tarball 比对），并新增 `vendor/quickfile/SHA256SUMS` 作为构建输入的独立校验 |
| M12 | 已修 | 单 job 流程，删掉 `has_update`/`version_ipk`/`LATEST` 死逻辑；构建成功后才建 release（不再留空 release）；新增产物元数据校验步骤 |
| 轻微 1（core dump） | 已修，且发现更深的问题 | 见 A.2：原脚本两次 `procd_set_param limits` 导致 `core` 从未生效；现合并为一次调用 |
| 轻微 2（postinst `exit 1`、`::error::`） | 已修 | 去掉 `::error::`；配置失败改为回滚 + 告警，且 `configure_nginx_quickfile \|\| true`，不再让包事务失败；apk/ipk 两侧都加了 `[ -f ... ]` 保护 |
| 轻微 3（证书 825 天/SAN 漂移/CN 漂移） | 随设计删除 | 不再生成自签证书，改为复用 `_lan` 现有证书（真机上是 ACME 正式证书，原设计会把它覆盖掉） |
| 轻微 4（apk/ipk postinst 不一致） | 已修 | 两侧都改为 `[ -f /usr/lib/quickfile/configure-nginx.sh ] && . …` |
| 轻微 5（Makefile 元数据） | 已修 | 许可证字段、`SUBMENU`、架构约束、`PKG_LICENSE_FILES` 都对齐实际文件 |
| 轻微 6（po 头非规范） | 已修 | po/pot 头改为规范多行 header 并带 `Language: zh_Hans`；`msgfmt -c` 通过 |
| 轻微 7（无 acl.d） | 文档化 | README「已知限制」写明仅 root 可见 |
| 轻微 8（`[skip ci]` 说明） | 随功能删除 | 不再有 CI 自动提交 |
| 轻微 9（临时目录在仓库内、版本探测脆弱） | 已修 | 临时目录改到系统 temp + `trap` 清理；输出改到 `dist/`（已 gitignore）；版本探测改为精确读 Makefile |

## A.2 实施过程中新发现 / 更正的问题

1. **`procd_set_param limits` 不能连调两次**（轻微 1 的背后）：`procd_set_param limits core=…` 与 `procd_set_param limits nofile=…` 是两次表构建，第二次会替换第一次。真机 `ubus call service list` 显示 `limits` 里原本**只有 `nofile`**，即旧脚本的 `core="unlimited"` 从未生效。现改为一次调用 `procd_set_param limits core="0 0" nofile="200000 200000"`，真机 `/proc/<pid>/limits` 已确认 `Max core file size 0 0`、`Max open files 200000 200000`。
2. **`443 ssl` 与 `443 ssl default_server` 同 server 共存是致命的**（更正第 1 节表格）：nginx 报 `[emerg] a duplicate listen 0.0.0.0:443`（`ngx_http_add_server()`，`src/http/ngx_http.c:1528`）。旧脚本这一行本身就能让 nginx 起不来。
3. **`uci show <pkg>.<sec>.<opt>` 对 list 选项是「一行内输出全部值」**（`a='x' 'y'`），不是一行一个值。我的第一版解析按一行一个值写，本地 fake uci 也照着错格式模拟，导致本地全绿、真机不修复。真机测试暴露后已修正解析（`tr "'" '\n'` 后过滤空行），并同步修正了 fake uci 使其与真机一致。
4. 真机上原有的 `/etc/nginx/conf.d/quickfile.locations` 是手工改过的版本（把 `$host` 硬编码成了具体域名）——与本仓库文件无关，已备份到 `/root/quickfile.locations.before`。

## A.3 验证结果

**本地**
- `bash -n` / `sh -n` / `dash -n`：全部脚本与生成的维护者脚本通过
- `configure-nginx.sh` 集成测试（fake uci + fake nginx init）：**26/26 通过**，覆盖 stock 无操作、旧版本残留修复、幂等、缺失 include 补一次、`uci_enable` 未设置时不动、reload 被拒后回滚
- `build-pkg.sh` 集成测试（fake apk/ipkg-build/po2lmo/find/curl + 真实上游 tarball）：**47/47 通过**，覆盖 noarch/x86_64 元数据、离线模式不联网、完整性校验链路、上游 tarball 被篡改时中止、`SHA256SUMS` 被篡改时中止、生成脚本语法与包内文件清单
- `actionlint -shellcheck` 对 workflow：干净；`shellcheck` 对两个脚本：干净（`local`/`ls -1t` 属 OpenWrt ash 下的已知可接受项，已就地注明）
- `msgfmt -c` 通过；YAML 解析通过

**真机（ImmortalWrt 25.12.1 / x86/64 / apk）**
- H1 现场证实：旧 release 的 `luci-app-quickfile-1.0.25-r1.apk`（`arch: all`）→ `apk add --simulate --allow-untrusted` 报 `error: uninstallable / arch: all`；设备上已安装的 `luci-app-quickfile-1.0.0-r99` 为 `noarch`，`quickfile-1.0.25-r99` 为 `x86_64`
- `configure-nginx.sh`：当前状态运行 → 零改动、零 reload（配置 sha 不变）；构造旧版本残留（重复 include + 4 条多余 listen + 删除 `_redirect2ssl`，均以未提交 delta 形式）→ 一次运行后 listen 回到原 3 条、include 去重为 1 条、`_redirect2ssl` 恢复，`nginx -t` 成功、reload OK；再跑一次 → 零改动（幂等）
- 新的 `quickfile.locations`：reload OK / `nginx -t` 成功；渲染配置中 `client_max_body_size` 为 http 级 `128M` + location 级 `0`，`proxy_request_buffering off` 生效，`$http_host` 已无残留；`/`→200、`/cgi-bin/luci/quickfile`→200、`/api/version`→401（到达后端要求鉴权）、`http://`→301 `https://`（跳转未被破坏）
- 新 `quickfile.init`：restart OK、socket 正常、`/proc/<pid>/limits` 的 core 与 nofile 均按预期生效、HTTP 200
- 测试后已把 `/etc/config/nginx` 用测试前的导出**逐字节还原**并 reload OK；设备上保留的改动只有两个「修复后」的配置文件（`/etc/init.d/quickfile`、`/etc/nginx/conf.d/quickfile.locations`），旧文件备份在 `/root/quickfile.init.before`、`/root/quickfile.locations.before`
- 公网侧实测 `restrict_locally`：从 VPS（199.168.136.128）访问 DNAT 暴露的 `https://14.127.212.108:1000/` → **403**，路由器日志 `access forbidden by rule, client: 199.168.136.128, server: _lan`；内网 200 不受影响

**CI（GitHub Actions）**
- `425aeae` 首次运行暴露了 ipk 校验写错（外层成员名带 `./`、且对所有 ipk 断言 `all`），修正后 `90efdca` 起全绿
- action 升到 node24 版本后（`7271eec`）日志里 `Node.js 20` 出现次数为 0，annotations 只剩自定义 notice
- 产物可复现性对比：`92ef565`（改了 `build-pkg.sh`）跑一次记录 6 个产物的 sha256，随后提交一个**只改文档**的 commit 再跑一次，两次 sha256 完全一致 → 证明 epoch 口径生效，CI/文档提交不再影响产物
- 每次运行都会重新下载上游 tarball 校验 `PKG_HASH` 并与 vendored 二进制逐字节比对，未出现偏差

## A.4 遗留 / 需要你决定

1. `vendor/quickfile/quickfile-1.0.25-{aarch64,arm}.tar.gz` 已 `git rm`（x86_64 only）。这两个文件可从上游 `r2.cooluc.com/source` 重新下载，若要恢复多架构支持需一并重做架构命名。
2. 本次修复已提交并推送；README 中「出包范围/安装/nginx 集成/构建与校验/升级与回滚/许可证/已知限制」已按新行为重写并逐句核对过。
3. workflow 只能在 GitHub runner 上真跑一次才能确认 `apk adbdump` 的文本里确实逐个出现 `x86_64`/`noarch`（本机无法执行 apk-tools v3）。若该断言在 runner 上不成立，会以明确错误中止构建，不会产错包。
4. 本报告第 1 节表格与 M9 两处已就地标注更正，未删改其他结论。

## A.5 历史重开（2026-09-12）

仓库历史被**有意压平为单个根提交**，旧历史（截至重置前共 104 个提交）不再存在于本仓库，目的与结果：

- 以一个干净的原点继续开发；`main` 只剩一个提交，`PKG_RELEASE` 从 1 提到 2，发布重新生成为 `v1.0.25-r2`。
- 旧历史（含 LFS 对象缓存）已完整备份到仓库之外的 `luci-app-quickfile-history-<ts>.bundle` 与 `luci-app-quickfile-dotgit-<ts>.tar.gz`，不随仓库分发；如需追溯可从那两个文件恢复。
- **因此本附录 A.1–A.4 中出现的 SHA（`425aeae`、`90efdca`、`7271eec`、`92ef565`、`5942afe` 等）与 Actions 运行编号都属于旧历史，在本仓库中已不存在**；那些提交所做的文件改动已经全部包含在当前这个根提交里。
- 重置前的远端仓库（含 tag/release `v1.0.25-r1`、46 条 Actions 运行记录）整体删除后按同名新建，故旧的 release 资产与运行日志也不再可用。


## A.6 补充修复：全新安装下 HTTPS + LAN IP 无法使用（2026-09-12，P1）

A.1 里"轻微 3（证书）"我当时的处理是**删掉自签证书生成、完全不碰证书**，理由是测试机上用的是 ACME 正式证书、不能覆盖。事后发现这个决定留下一个更严重的后果：**全新安装（stock luci-nginx）时该应用根本用不了**。启动本轮修复的原始问题：

**症状与成因（真机实测）**

1. 后端校验会话的方式是 `POST <host>/cgi-bin/luci`（带 `sysauth_http` cookie），`<host>` 由 nginx 传给它，且它用 `&http.Client{}` **默认校验 TLS**（源码 `internal/api/auth.go`）。
2. stock nginx-util 生成的自签证书 **subject 只有 `CN=OpenWrt`、连 SAN 扩展都没有**（实测 `subjectAltName` 0 条）；Go 1.15+ 只认 SAN、不再回退 CN → 按 IP 访问时必然 `x509: cannot validate certificate for <ip> because it doesn't contain any IP SANs` → 所有 API 500。
3. 80 端口是 stock `_redirect2ssl` 的 302 跳转，本包有意不动 → `http://` 也不会直接服务应用。
   ⇒ 结论：**全新安装后 http 和 https+LAN IP 都不能正常使用**，这是上游"回连校验"设计与 stock 证书的必然组合，上游原包没有 postinst，同样如此。

**修复（两步，第二歩才是关键）**

1. 恢复"带 IP SAN 的自签证书"并加守卫：仅当 `_lan` 用的是 nginx-util 自签证书（`uci_manage_ssl=self-signed`，或证书 subject 为 `CN=OpenWrt`）时接管；管理员自己的证书（ACME 等）**完全不碰**，只打印提示。证书 SAN 覆盖 `IP:<lan-ip>`、`IP:127.0.0.1`、`DNS:<主机名>`，用 nginx-util 官方机制 `uci_manage_ssl=quickfile` 指向它，3650 天，LAN IP 变化重签；卸载时交还给 nginx-util 并删除自家证书。
2. **把回连固定到环回明文**：`quickfile.locations` 改为传 `host=http://127.0.0.1:8199`，新增 `quickfile-auth.conf`（仅 `listen 127.0.0.1:8199` / `[::1]:8199`）只服务 `POST /cgi-bin/luci`，其余路径 301；uwsgi 参数内联以避免依赖 `/etc/nginx/uwsgi_params`。这样会话校验不再依赖证书、DNS 与访问规则，cookie 不出本机，也不再受 Host 头影响。

**真机验证（ImmortalWrt 25.12.1 / x86_64，生产配置为 ACME 证书 + `restrict_locally`）**

- 修复前：按 IP 调 API 返回 `Session verification failed: ... x509 ...`；按域名则因回连源地址是公网 IP 被 `restrict_locally` 拒（403）。
- 修复后：按 IP 与按域名调 API 都返回 `{"error":"Invalid or expired session token."}`——即回连已经到达 LuCI，只剩"测试会话没有 ACL"这一层（我用 `ubus session create` 造的是无 ACL 会话；有效浏览器会话时应为 200）。
- 环回 vhost：`POST http://127.0.0.1:8199/cgi-bin/luci` 返回 403（到达 LuCI，非 301/000）；从 LAN IP 访问 8199 返回连接失败（仅环回）✓。
- 未受影响：`http://` 仍 301、`https://…/quickfile` 与静态资源 200、`nginx -t` successful、`restrict_locally` 与 ACME 证书逐字节保持。
- 过程中发现并修掉两个真 bug：`detect_lan_ip` 直接使用 `network.lan.ipaddr`，而真机该值是 CIDR 写法 `192.168.1.1/24` → SAN 变成 `IP:192.168.1.1/24` 被 openssl 拒绝（现已去掉前缀并校验 IPv4 形态）；`generate_cert` 原先吞掉 openssl 的 stderr，现已保留为可诊断输出。

**尚未完成的一步**：无法在没有 root 密码的前提下产生"有效浏览器会话"，因此"回连返回 200 → 应用完全可用"的最后一步需要管理员在浏览器里登录确认。设备上已装好本仓库工作区版本的 `quickfile.locations` + `quickfile-auth.conf`。

**回归**：新增 `quickfile-auth.conf` 后，`build-pkg.sh` 的包内文件清单断言、证书用例（34 条）与原有 nginx 用例（26 条）共 108 条断言全部通过。

### A.6.1 第三堵墙：HTTPS 下会话 cookie 叫 `sysauth_https`（2026-09-12）

管理员在浏览器实测后报 `invalid session`（而非之前的 x509/401）。该字符串对应 `auth.go` 里 **`r.Cookie("sysauth_http")` 取不到 cookie** 的分支。设备上确认了原因：

```
/usr/share/ucode/luci/dispatcher.uc:963
let cookie_name = (http.getenv('HTTPS') == 'on') ? 'sysauth_https' : 'sysauth_http'
http.header('Set-Cookie', `${cookie_name}=${session.sid}; path=...; SameSite=strict; HttpOnly${cookie_secure}`);
```

即 ucode 版 LuCI 在 HTTPS 下把会话 cookie 命名为 `sysauth_https`，而 quickfile 后端只查找 `sysauth_http`。**这也解释了原作者为什么要把应用放到 http 上（只有 http 下 cookie 才叫 `sysauth_http`）**；我之前把它改回 https-only，等于同时抽掉了这一环。

修法：在 `quickfile-auth.conf`（http 上下文）里加 `map $http_cookie $quickfile_cookie`，只在这一个代理跳把 `sysauth_https=`（以及 `sysauth=`）改写成 `sysauth_http=`，其余 cookie 原样保留；`quickfile.locations` 的 API location 用 `proxy_set_header Cookie $quickfile_cookie`。LuCI 侧（浏览器 → uwsgi）不受影响。注意 `map` 的取值不支持位置捕获，必须用命名捕获（否则 `nginx -t` 报 `unknown "1" variable`）。

真机验证（同上设备，ACME 证书、`restrict_locally` 不变）：

| 请求携带的 cookie | 后端返回 |
|---|---|
| 无 | `{"error":"invalid session"}`（= 管理员看到的症状） |
| `sysauth_https=<sid>` | `{"error":"Invalid or expired session token."}` → cookie 已被识别，回连到达 LuCI |
| `sysauth_http=<sid>` | 同上（向后兼容） |
| `foo=1; sysauth_https=<sid>; bar=2` | 同上（不破坏其他 cookie） |

`nginx -t` successful。此后仍待管理员在浏览器里最终确认（有效会话应为 200 → 界面可用）。

**A.6.2 最终确认（2026-09-12，管理员浏览器实测）**

按 `v1.0.25-r3` 的 release 包在主路由上**全新安装**（`apk del` 掉本地构建的 r99 → `apk add --allow-untrusted` 三个 r3 apk）后，管理员确认：

- `https://<lan-ip>/` 访问 quickfile：正常（`_lan` 用的是 ACME 域名证书，按 IP 访问仍有证书告警，但功能正常）
- `https://<域名>/` 访问 quickfile：正常（证书匹配，无告警）
- `http://<lan-ip>/`：自动 301 跳转到 https（stock 行为，本包不改）

至此 P1 的目标达成：**全新安装后 https + LAN IP 与 https + 域名都可用，http 仍按 stock 行为跳转**。安装过程中 post-install 正确拒绝接管管理员的 ACME 证书并打印提示，`uci export nginx` 在卸载+安装前后逐字节一致；环回鉴权 vhost 与 cookie 名重写是让这套组合成立的两个关键点。设备上保留的是 release 产物（`1.0.25-r3`），不再有手工拷贝的文件。
