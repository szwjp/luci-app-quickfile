# 构建、校验与跟版

本页是 [README](../README.md) 的展开，面向维护者：CI 构建流程、产物校验链、以及上游版本探测。

## CI 结构

`.github/workflows/build.yml`（手动触发：Actions → Build → Run workflow）分两个 job：

1. **backend** —— 编译后端。
   - 从 `quickfile/Makefile` 读出 `PKG_VERSION` / `PKG_SOURCE` / `PKG_SOURCE_URL` / `PKG_HASH`；
   - 下载上游源码包并按 `PKG_HASH` 校验；
   - 装 Rust 工具链：**不用 rustup**，直接取 `static.rust-lang.org` 上的版本化 dist 包
     （`rust-<版本>-x86_64-unknown-linux-gnu.tar.xz` 与
     `rust-std-<版本>-x86_64-unknown-linux-musl.tar.xz`），两者都是不可变文件并附带官方
     SHA-256，CI 里逐个校验。版本钉在 workflow 的 `RUST_VERSION`；
   - 打一个补丁：上游 `Cargo.toml` 里 `xz2 = { version = "0.1", default-features = false }`
     改成 `xz2 = { version = "0.1", features = ["static"] }`。上游这么写等于没关掉任何东西
     （xz2 没有默认 feature），于是 lzma-sys 不带 `static` feature 去链系统 liblzma；
     在 musl 目标上这个库不存在，编出来的二进制在 OpenWrt 上跑不起来。补丁把 xz 解压器
     编进二进制，顺便让产物完全静态。补丁前后的内容都会被 grep 校验，上游改了写法就
     直接报错，不会静默跳过；
   - `cargo build --release --locked --target x86_64-unknown-linux-musl`。`--locked` 保证
     `Cargo.lock` 不被改动（依赖版本因此固定）；前端产物已经打包在上游源码的 `public/`
     里，不需要 Node/Vite；
   - 校验产物是静态 x86-64 ELF（`readelf -d` 不能有 `NEEDED`），算出 sha256，作为
     artifact 传给下一个 job。
2. **package** —— 出包并发布。
   - 拉取后端 artifact，按导出的 sha256 复核（artifact 被替换或损坏会中止构建）；
   - 跑 `.github/build-pkg.sh` 打 3 个 apk；
   - 校验包元数据（数量、架构名）；
   - 生成 release 说明（附上游源码 sha256、后端二进制 sha256、编译器版本）并发布
     release 资产。

版本号唯一真相源是 `luci-app-quickfile/Makefile` 的 `PKG_VERSION` / `PKG_RELEASE`，
`quickfile/Makefile` 的 `PKG_VERSION` 必须与之相同（不一致直接失败）。

### 为什么后端要专门编译

上游 2.x 只发源码包（`quickfile-src-<版本>.tar.xz`），仓库里没有 CI、没有 release，
官方源里也没有这个包。想要能直接 `apk add` 的二进制，只能自己编译——这就是本仓库
存在的理由。

### 可复现性

- **包**是时间戳可复现的：`SOURCE_DATE_EPOCH` 取**最后一次改动打包内容**的提交时间
  （打包内容 = `quickfile/`、`luci-app-quickfile/`、仓库根 `LICENSE`、`.github/build-pkg.sh`；
  workflow 本身不算，它只决定怎么发布）。所以只改 README/CI 的提交不会改变产物，同一
  打包内容重跑得到的 apk 逐字节相同。
- **后端二进制不是逐字节可复现的**：Rust 默认不保证 bit-reproducible，每次编译出的
  二进制可能不同。因此 release 说明里必须写清二进制 sha256；同一版本的 release 重新
  构建会换掉这个 sha256。

本地构建需要 Linux 环境与 CI 相同的工具链（`fakeroot`、apk-tools v3、带 `mkpkg`、
openwrt/luci 的 `po2lmo`）；macOS 自带工具不满足。CI 里没有做这一步的本地等价物：
编译、打包、依赖安装全部在远端完成。

## 上游版本探测与跟版

本仓库**不会自动跟随上游**：`PKG_VERSION` 是人工 pin 的，构建只编这个版本。

为了知道上游什么时候发了新版，`.github/workflows/check-upstream.yml` 每天
（02:17 UTC / 10:17 Asia/Shanghai）跑一次 `.github/check-upstream.sh`：发现 r2 上有比
`PKG_VERSION` 新的源码包时，开一个带 `upstream-update` 标签的 issue（正文含新包
sha256，可直接填 `PKG_HASH`，以及跟版步骤）；同一版本不会重复开；跟版合并并发布后，
下一次探测会自动关闭它。**只做检测，不改仓库、不发布**。也可手动触发
（Actions → Check upstream quickfile），支持 `dry_run`（只打印计划）与 `pinned_override`
（诊断用，假装 pin 在某个版本）。

探测按多轮展开——同一 minor 的后续 patch、同一 major 的后续 minor、下一个 major 的全部
minor × patch 组合、以及再往后每个 major 的首个版本，逐个 HEAD（默认每个维度 10 个，
合计 149 个请求，一次约 3 分钟）。这个布局能覆盖"新 major 从 .0.1 起版"这类跳变
（1.0.25 → 2.0.1 就是这么漏掉的），但仍可能漏报超出窗口范围的版本号（漏报的后果只是
没有通知）；另外如果 pin 的版本被上游下架且没有更新的版本可报，探测任务会**失败**
（提示发布构建也会失败），而不是静默通过。

跟版是人工步骤，缺任何一步都会在构建的校验阶段明确失败：

1. `quickfile/Makefile` 的 `PKG_VERSION` 改成新版本、`PKG_HASH` 改成新源码包的 sha256；
2. `luci-app-quickfile/Makefile` 的 `PKG_VERSION` 改成新版本，`PKG_RELEASE` 重置为 1；
3. 提交后手动触发 Build workflow：CI 重新编译后端并出包。

如果上游改了 `Cargo.toml` 里 `xz2` 那一行，第 1 步之后 CI 会在打补丁时报错
（`upstream Cargo.toml no longer contains the expected xz2 dependency line`）——这时要
人去看新的依赖声明再改补丁，不要把校验去掉。
