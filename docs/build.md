# 构建、校验与跟版

本页是 [README](../README.md) 的展开，面向维护者：构建流程、产物校验链、以及上游版本探测。

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

### 上游版本探测与跟版

本仓库**不会自动跟随上游**：`PKG_VERSION` 是人工 pin 的，构建只编这个版本、只用 `vendor/quickfile/` 里的那个二进制，并强制与 r2 上的同名包比对（见上面的第 2、3 步）。

为了知道上游什么时候发了新版，`.github/workflows/check-upstream.yml` 每天（02:17 UTC / 10:17 Asia/Shanghai）跑一次 `.github/check-upstream.sh`：发现 r2 上有比 `PKG_VERSION` 新的版本时，开一个带 `upstream-update` 标签的 issue（正文含新包 sha256，可直接填 `PKG_HASH`，以及下面的跟版步骤）；同一版本不会重复开；跟版合并并发布后，下一次探测会自动关闭它。**只做检测，不改仓库、不发布**。也可手动触发（Actions → Check upstream quickfile），支持 `dry_run`（只打印计划）与 `pinned_override`（诊断用，假装 pin 在某个版本）。

跟版是人工步骤，缺任何一步都会在构建的校验阶段明确失败：

1. 下载上游 `quickfile-<新版本>.tar.gz`，取出其中的 `quickfile-<新版本>/quickfile.x86_64`，重新打包成 `vendor/quickfile/quickfile-<新版本>-x86_64.tar.gz`；
2. 刷新 `vendor/quickfile/SHA256SUMS`；
3. 两个 Makefile 的 `PKG_VERSION` 都改成新版本，`quickfile/Makefile` 的 `PKG_HASH` 改成新包的 sha256，`PKG_RELEASE` 重置为 1；
4. 提交后手动触发 Build workflow。

两个已知边界：r2 不提供目录列举，探测按"后续 patch、下一个 minor、下一个 major"逐个 HEAD，非常规版本号可能漏报（漏报的后果只是没有通知）；另外如果 pin 的版本被上游下架且没有更新的版本可报，探测任务会**失败**（提示发布构建也会失败），而不是静默通过。
