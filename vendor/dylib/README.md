# vendor/dylib

闭源引擎成品（不是本仓编译产物）。**所有 hook 都在这里**，本仓的 loader 只负责
`dlopen`。改引擎 = 改这个目录 + 同步 `manifest.txt`。

| 路径 | 架构 | 版本 |
|------|------|------|
| `rootless/decrypt_helper.dylib` | arm64 | 1.27.5 |
| `roothide/decrypt_helper.dylib` | arm64 + arm64e | 1.27.5 |

## manifest.txt 与漂移防护

`manifest.txt` 记录每个 variant 的版本、架构、字节数、SHA-256 和来源工件。
`build_deb.sh` 打包前会校验，对不上直接失败：

```bash
make verify-vendor     # 单独跑，不需要 Xcode
```

这道校验是补出来的 —— 曾经出现过 `Makefile` 的 `VERSION` 已经到 1.27.5，
而 vendor 里的引擎还停在 1.25.6：包自称新版、装进去是旧引擎，而且没有任何一步
会报错。旧引擎的网络捕获只到 HTTP 层（传输层 TLS/socket 完全没有），所以这种
漂移的表现就是「升级了但看不到想要的层」。

## 换引擎

```bash
make sync-engine TAG=v1.28.0        # 拉取 release、更新 dylib 与 manifest、跑校验
```

脚本做四件事：核对 release 资产、覆盖两个 dylib、重写 `manifest.txt` 数据行、
把 `Makefile` 的 `VERSION` 改成新版本。rootless 取公开发布的未签名成品
（`decrypt_helper-<ver>.dylib`，与历史约定一致）；roothide 要胖切片，只能从
roothide deb 里取。两者 SHA-256 都写进 manifest，可复核、可回滚。

`manifest.txt` 必须和 dylib 在同一个 commit 里。

## 引擎自带的能力自述

引擎通过 MCP 暴露自己的能力与**盲区**，换引擎后先用它们确认新能力真的在：

| 工具 | 用途 |
|------|------|
| `get_capabilities` | 插件版本、变体、架构、hook 能力位 |
| `get_capture_coverage` | 逐层列出「符号是否出现在某镜像导入表」+ `blind_spots`。`available=YES` 只代表候选可 hook，不代表当前流量一定经过该层 |
| `get_stats` | 各分类计数与 `capture` 开关位 |
| `get_diag` | hook 健康度、未 hook 成功的符号清单（`unhooked`） |

例：

```bash
idh call <target_id> get_capture_coverage --json
idh call <target_id> get_diag --json
```

## 从源码构建（私有仓）

本仓的 loader / 管理器 App / updater daemon 用 `make deb` 编译；引擎是外来成品，
`build_deb.sh` 只做架构断言、`ldid -S` 签名和落位：

```
vendor/dylib/<variant>/decrypt_helper.dylib
  → xcrun lipo -archs 断言架构
  → tools/verify_vendor.sh 断言版本与 SHA-256
  → ldid -S 签名
  → <prefix>/usr/lib/IOSDecryptHub/decrypt_helper.dylib
```
