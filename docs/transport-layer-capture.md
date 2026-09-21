# 传输层网络捕获改进方案

> 状态：方案 + 已完成的第一批仓库侧改造
> 适用仓库：`IOSDecryptHub`（越狱插件）/ 引擎 `decrypt_helper.dylib`
> 实测环境：iPhone9,1 / iOS 15.8.2 (19H384) / rootless / 目标 App Proton Mail 4.20.0

---

## 0. 结论先说

1. **「只能抓 HTTP 层」不是设计取舍，是版本漂移。** 本仓 `Makefile` 的
   `VERSION` 已经走到 1.27.5，但 `vendor/dylib/*/decrypt_helper.dylib` 仍停在
   **1.25.6** —— 而传输层捕获（TLS / socket / Network.framework / WebKit 探针）
   恰恰是 1.27.5 才有的。`make deb` 会打出「自称 1.27.5、实际 1.25.6 引擎」的包，
   全程没有任何一步报错。
2. 已修：vendor 引擎同步到 1.27.5、加 `manifest.txt` + 打包前强校验 + `make sync-engine`。
3. 但 1.27.5 仍不是终点：它的传输层覆盖有**明确盲区**（`get_capture_coverage`
   自报 `blind_spots`），且**缺 HTTP/2、gRPC、QUIC 明文解析**与**连接级关联**。
   本文第 4 节给出补齐设计，第 8 节给出实施顺序。
4. 排查时先避开两个坑（1.5 节实测）：`get_diag` 那行「hook 安装完成 (…)」
   在 1.25.6 与 1.27.5 里**逐字节相同且都没提网络**，拿它判断网络 hook 会得出
   错误结论；TLS hook 确实编进了 1.27.5（符号表可见），但 NSURLSession 流量上
   **只出 HTTP 事件、不出 TLS 事件**，层归属/抑制规则目前是隐式的，也改不了。

---

## 1. 现状实测（不是推测）

### 1.1 两版引擎的网络层能力对照

用 `strings` 对两个二进制做符号级比对，结果如下：

| 层次 | 代表符号 | 1.25.6（原 vendor / 原设备） | 1.27.5（现 vendor / 现设备） |
|------|----------|------------------------------|------------------------------|
| HTTP (ObjC) | `NSURLSession` / `NSURLConnection` / `-[NSMutableURLRequest setHTTPBody:]` / `-[NSURLSessionTask resume]` | ✅ `HTTP/1.1 %d %@` | ✅ 且事件带回 `inLen` |
| WebSocket (ObjC) | `NSURLSessionWebSocketTask`、`send` / `recv` / `ping` | ❌ | ✅ |
| TLS（BoringSSL） | `SSL_write` / `SSL_read` / `SSL_write_ex` / `SSL_read_ex` | ❌ | ✅ 有 hook 符号 |
| TLS（SecureTransport） | `SSLWrite` / `SSLRead` → 标签 `TLS-ST` | ❌ | ✅ |
| Socket | `socket` / `accept` / `connect` / `send` / `recv` / `sendto` / `recvfrom` / `sendmsg` / `recvmsg` | ❌ | ✅ 标签 `SOCKET` |
| DNS | `getaddrinfo` → 标签 `DNS` | ❌ | ✅ |
| Network.framework | `nw_connection_send` / `nw_connection_receive` → 标签 `TLS-NW` | ❌ | ✅ |
| WebKit 探针 | `WKUserScript` 注入 fetch/XHR/WS/SSE/beacon/storage/console/crypto.subtle | ❌ | ✅ 标签 `WEBKIT-PROBE`（默认关） |

### 1.2 1.25.6 的真实抓取结果（升级前，设备实测）

```
categoryNames: [digest, hmac, sym, asym, file, sys, net, keychain, other]
byCategory:    [20, 0, 0, 0, 129, 277, 431, 48, 0]      ← net = 431
net 事件的 algorithm 只有一种： "HTTP"
单条事件: { operation:"GET", algorithm:"HTTP",
           detail:"GET https://mail-api.proton.me/... \nAuthorization: Bearer ...",
           inLen:0, outLen:0, preview:"", outputHexPreview:"" }
```

两个硬伤：**只有请求头**，`inLen/outLen` 恒为 0（连 body 长度都没有）；`net` 分类里
没有任何 TLS/socket/DNS 事件。

### 1.3 1.27.5 的层级矩阵（升级后，设备实测）

`get_capture_coverage` 是 1.27.5 新增的工具，引擎**自报**每层是否可 hook：

```jsonc
{ "images_scanned": 919,
  "blind_spots": ["OpenSSL RSA", "OpenSSL/BoringSSL TLS"],
  "layers": [
    { "layer":"NSURLSession (ObjC)",  "symbol":"(runtime swizzle)", "available":true },
    { "layer":"Apple SecureTransport","symbol":"SSLWrite", "images_importing":3, "available":true,
      "hint":"Apple 命名无下划线: SSLWrite/SSLRead" },
    { "layer":"BSD socket", "symbol":"connect", "images_importing":3, "available":true,
      "hint":"自研网络栈入口(可拿 ip:port)" },
    { "layer":"BSD socket", "symbol":"send",    "images_importing":3, "available":true,
      "hint":"TLS 密文; 仅能解 ClientHello SNI" },
    { "layer":"BSD socket", "symbol":"getaddrinfo", "available":true, "hint":"域名解析" },
    { "layer":"Network.framework", "symbol":"nw_connection_send",    "available":true,
      "hint":"NW 栈的明文入口" },
    { "layer":"Network.framework", "symbol":"nw_connection_receive", "available":true,
      "hint":"NW 栈的明文接收" },
    { "layer":"OpenSSL/BoringSSL TLS", "symbol":"SSL_write", "images_importing":0, "available":false },
    { "layer":"WebKit (ObjC)", "available":true } ] }
```

引擎自己的 `hint` 已经把**最关键的一条语义**说清楚了：

> `send` → **TLS 密文**；仅能解 ClientHello SNI
> `nw_connection_send` → **NW 栈的明文入口**

也就是说：**socket 层拿不到明文，TLS 层才拿得到。** 这决定了本方案的全部取舍。

升级后同机实测：`net` 分类出现了 `DNS` / `resolve` 事件（socket 层 `getaddrinfo`
真的在产出），HTTP 事件的 `inLen` 也从恒 0 变成真实长度（如 POST `inLen=482`）。
`get_diag.unhooked` 为空，无失败 hook。

### 1.4 目标进程里真实存在的传输层实现（实测导入表）
用引擎自己的 `list_loaded_images` + `list_imports` 查（925 个镜像）：

| 镜像 | dyld idx | 与捕获有关的导入 |
|------|----------|------------------|
| `CFNetwork` | 63 | `SSLRead`/`SSLWrite`/`SSLHandshake`/`SSLCreateContext`…（**SecureTransport 家族**）、`CFReadStreamRead`/`CFWriteStreamWrite`（**流层，未被 1.27.5 hook**） |
| `libnetwork.dylib` | 73 | `connect`、`connectx`、`getaddrinfo`、`dnssd_getaddrinfo_*`（含 `..._get_doh_uri`、`..._get_ech_config`） |
| `libboringssl.dylib` | 571 | 369 个导入；`SSL_*` 是它**导出**的，不在自己导入表里 |
| `libswiftNetwork.dylib` | 717 | `nw_connection_*`（Network.framework 路径） |
| `libquic.dylib` | 829 | `nw_protocol_copy_quic_stream_definition`、`nw_quic_connection_*`（**QUIC/HTTP3**） |

这里有两个必须写进设计的事实：

* **CFNetwork 走的是 SecureTransport（`SSLWrite`/`SSLRead`），不是 BoringSSL。**
  所以「hook BoringSSL 的 `SSL_write`」对标准 NSURLSession 流量毫无作用 —— 它本来
  就不经过那条路。反过来，`available:false` 的 BoringSSL 层，只有当 App
  **自带 TLS 库**时才有意义。
* **`SSL_*` 是 libboringssl 的导出符号，不在任何镜像的导入表里。** fishhook 靠
  改 GOT 生效（引擎 `hook_import` 的说明就是 "via fishhook (GOT rebind)"），
  所以对「静态链接进 App 的 BoringSSL/OpenSSL/mbedTLS」它天然抓不到 —— 这正是
  `blind_spots` 的成因，也是 `capture_memory`（在「指针 + 长度」导入处抓）存在的理由。

---

### 1.5 两个必须知道的坑：陈旧日志串 + TLS 事件缺失

**(a) `get_diag` 里那行「hook 安装完成 (…)」是陈旧串，不能用它判断网络 hook 有没有装上。**

1.25.6 与 1.27.5 的这行日志**逐字节相同**：

```
hook 安装完成 (Digest/HMAC/对称/非对称/KDF/EVP/文件/系统)
```

两个二进制里都只有这一份，都没有提「网络」。也就是说：1.27.5 明明新增了
TLS/socket/Networking 捕获，安装日志却完全没变。拿它当覆盖度证据会得出错误结论。
判断网络层是否可用，只能看 `get_capture_coverage`（它按镜像导入表实算）
和实际产出的事件。**这条日志应当补上网络层，否则会持续误导排查。**

**(b) TLS/socket hook 确实编进了 1.27.5，但 NSURLSession 流量上看不到 TLS 事件。**

1.27.5 的符号表里有真实的 hook 实现（不是工具描述里的示例字符串）：

```
_hooked_SSL_write   _hooked_SSL_read   _hooked_SSL_write_ex   _hooked_SSL_read_ex
_hooked_dh_SSLWrite _hooked_dh_SSLRead _hooked_dh_socket
```

同机实测的行为是：

| 观测 | 结果 |
|------|------|
| socket 层 `getaddrinfo` | ✅ 产出 `DNS` / `resolve` 事件（71 条）——**socket 层确认在跑** |
| HTTP 层 | ✅ 产出 `HTTP` / `GET` / `POST` 事件；带 body 的请求 `inLen` 非 0 |
| TLS 层（`TLS-ST`） | ❌ 该 App 的 NSURLSession 流量一条都没有，`net`/`sys`/`file`/`other` 四个分类里都查过 |

socket 层在产出、TLS 层不产出，说明这不是「hook 没装上」，更像是**同一条连接上
高层已覆盖时低层被隐式抑制**（NSURLSession 流量由 `http` 层「认领」，`tls-st`
就不再单独出一条）。这个语义目前：

* 没有任何工具描述写出来；
* 没有开关可以让用户强制看 TLS 层；
* 也就无法区分「这条连接确实没走 TLS」和「走了但被抑制了」。

→ 这是 M1 必须解决的问题：**把「层归属/抑制规则」变成显式、可查询、可覆盖的**。

---

## 2. 问题定义：「仅 HTTP 层」到底丢了什么

| 场景 | 1.25.6 | 1.27.5 | 仍缺 |
|------|--------|--------|------|
| NSURLSession 请求头 + URL | ✅ | ✅ | — |
| NSURLSession 请求/响应 **body** | ❌（len 恒 0） | ✅（有 len；需确认是否落 payload） | 大 body 截断策略 |
| App 自带 TLS（BoringSSL 等）的明文 | ❌ | ❌ | **整条链路** |
| 静态链接 TLS 的明文 | ❌ | 仅 `capture_memory` 手工兜底 | 自动识别 |
| Network.framework / QUIC 明文 | ❌ | ✅ 入口符号 | QUIC 流层语义 |
| 自研 TCP 栈（裸 socket） | ❌ | ✅ 五元组 + 密文 | 明文（无 TLS 时就是明文，需标记） |
| 域名解析 | ❌ | ✅ `getaddrinfo` | DoH / 加密 DNS |
| WKWebView 内请求 | ❌ | ✅ JS 探针（默认关） | — |
| 把「谁连了谁」和「加解密事件」串起来 | 部分（`correlate_request` 靠时间窗） | 时间窗 | **连接级关联** |
| HTTP/2、gRPC 语义还原 | ❌ | ❌（只有 `HTTP/1.1`） | **帧解析** |

一句话：**当前（含 1.27.5）能在「HTTP 语义层」和「TLS 明文边界」看到东西，但
（a）TLS 明文只覆盖 Apple 自己的栈，（b）拿到明文之后没有 HTTP/2/gRPC 解析，
（c）各层事件之间没有连接级关联。**

---

## 3. 目标与非目标

**目标**

* G1 传输层**明文**可见：任何 App 的请求/响应，无论走 NSURLSession、
  Network.framework/QUIC、还是自带 TLS 库，都能拿到明文字节。
* G2 传输层**元数据**可见：五元组、SNI、ALPN、DNS 解析结果，且能与明文事件关联。
* G3 层与层之间可关联：一次请求能把 `DNS → connect → TLS → HTTP` 串成一条链。
* G4 覆盖度可自查：任何一层没抓到，工具要能直接回答「为什么没抓到」。
* G5 噪声可控：TLS/socket 是高频层，默认不能把 4096 条内存环和 8MB 日志冲爆。

**非目标**

* 不做密码学破解：没有密钥就不解 TLS 密文；socket 层只给密文摘要，不假装能解。
* 不改注入架构：`AGENTS.md` 明确 loader 不含任何 hook、不加常驻 daemon。
  所有 hook 仍在闭源引擎里，本仓只做打包、校验、验收与文档。
* 不做流量回放/中间人：不引入代理、不改设备网络配置。

---

## 4. 设计

### 4.1 分层捕获模型（引擎侧 hook 矩阵）

「传输层」要区分两个边界，这是整个设计的基石：

* **TLS 明文边界**（加密前 / 解密后）→ 拿得到明文，是主战场。
* **socket 字节流边界**（TLS 之下）→ 只有密文 + 五元组 + SNI，是兜底与关联用。

| # | 层标识 | hook 点 | 数据性质 | 优先级 |
|---|--------|---------|----------|--------|
| 1 | `http` | `NSURLSession` / `NSURLConnection` / `setHTTPBody:` / `resume` / 下载完成回调 | 明文（HTTP 语义） | 已 ✅ |
| 2 | `ws` | `NSURLSessionWebSocketTask` send/recv/ping | 明文 | 已 ✅ |
| 3 | `webkit` | `WKUserScript` document-start JS 探针 | 明文（JS 层） | 已 ✅（默认关） |
| 4 | `tls-st` | `SSLWrite` / `SSLRead`（SecureTransport） | **明文** | 已 ✅ |
| 5 | `tls-nw` | `nw_connection_send` / `nw_connection_receive` | **明文**（NW 栈边界） | 已 ✅ |
| 6 | `tls-ossl` | `SSL_write` / `SSL_read` / `SSL_write_ex` / `SSL_read_ex` | **明文** | 待补（G1 核心） |
| 7 | `stream` | `CFReadStreamRead` / `CFWriteStreamWrite` | **明文**（CFNetwork 流层） | 待补（低成本） |
| 8 | `quic` | `nw_quic_connection_copy_stream_metadata` / `nw_protocol_copy_quic_stream_definition` + `nw_connection_send` 结果解析 | **明文**（流层重组后） | 待补 |
| 9 | `socket` | `socket`/`accept`/`connect`/`send`/`recv`/`sendto`/`recvfrom`/`sendmsg`/`recvmsg`/`read`/`write` | 密文（或明文，若无 TLS） | 已 ✅（需补关联） |
| 10 | `dns` | `getaddrinfo` + `dnssd_getaddrinfo_create` / `..._result_get_hostname` | 明文 | 部分（缺 dnssd） |

### 4.2 明文获取的正确姿势（关键设计决策）

**决策 D1：`tls-ossl` 不能只靠 fishhook。**
`SSL_*` 是 `libboringssl.dylib` 的导出符号；App 动态链接时它出现在 App 的导入表，
fishhook 有效；App **静态链接**（很多大厂 App 会把 BoringSSL 编进去）时导入表里
什么都没有，GOT 重绑无从下手。所以需要两条腿：

* `libboringssl.dylib` **在镜像内** → 对该镜像的 `SSL_write`/`SSL_read` 做
  **inline hook（函数入口改写）**，而不是 GOT 重绑。这是 `blind_spots` 里
  `OpenSSL/BoringSSL TLS: available=false` 的直接解法。
* **静态链接**（符号不在任何导入表）→ 保留 `capture_memory` 路径，但把它从
  「手工工具」升级为**引导式流程**：识别「指针 + 长度」导入（如 `memcpy`、
  `CCCrypt`、自研 `aes_gcm_encrypt`），在调用点抓缓冲区。已有 skill
  `static-linked-crypto` 就是这个方法的雏形，需要在 `get_capture_coverage`
  的 `hint` 里把它显式指出来。

**决策 D2：socket 层默认不存密文 body。**
TLS 流量下 socket 层拿到的密文对分析几乎无用，却会以极高频率冲爆内存环与日志。
socket 层默认只记**元数据**：五元组、方向、字节数、SNI（从 ClientHello 里解）、
以及 `fd` 生命周期。密文摘要（前 N 字节 hex）作为可选开关。

**决策 D3：明文只在最靠近应用的一层取一份。**
同一条连接上 `tls-st` 和 `socket` 都会看到数据；`tls-st` 看到明文、`socket` 看到
密文。若两层都完整记录，事件量翻倍且语义重复。规则：**同一 `connection_id` 上，
若已有明文层记录，socket 层只记元数据。** 这条规则要显式实现并在
`get_capture_coverage` 的说明里写清楚 —— 现在引擎的行为是「NSURLSession 流量只出
`HTTP` 事件、不出 `TLS-ST` 事件」，但这是隐式的，没人能从工具描述里读出来。

### 4.3 事件模型（`net` 分类扩展）

现有 `net` 事件字段：`detail` / `operation` / `algorithm` / `inLen` / `outLen` /
`preview` / `outputHexPreview`。建议在保持向后兼容的前提下扩展：

```jsonc
{
  "seq": 1207, "ts_ms": 1789971452136, "thread_id": 385737,
  "category": "net",

  // 新增：显式层次与方向，替代现在靠 algorithm 字符串猜
  "layer": "tls-st",              // http | ws | webkit | tls-st | tls-nw | tls-ossl | stream | quic | socket | dns
  "direction": "send",            // send | recv | meta
  "operation": "POST",
  "payload_kind": "plaintext",    // plaintext | ciphertext | http-head | metadata

  // 新增：连接身份（把同一连接的所有事件串起来）
  "connection": {
    "id": "c-0007",               // 稳定 id：fd 复用要能区分
    "fd": 23,
    "proto": "tcp",               // tcp | udp | quic
    "local": "192.168.0.100:51432",
    "remote": "185.70.42.1:443",
    "host": "mail-api.proton.me", // 来自 DNS 关联或 SNI
    "sni": "mail-api.proton.me",
    "alpn": "h2",
    "tls": "securetransport"      // securetransport | boringssl | network | none
  },

  // 新增：父子关系，支撑「一条请求 → 多层事件」的链式视图
  "parent_seq": 1201,

  "detail": "POST https://mail-api.proton.me/data/v1/metrics\n...",
  "in_len": 482, "out_len": 0
}
```

要点：

* `layer` + `direction` + `payload_kind` 让「这到底是明文还是密文」不再需要人猜。
* `connection.id` 是 G3 的基础；`fd` 会被系统复用，**不能拿 fd 当 id**。
* `parent_seq` 让 `correlate_request` 从「时间窗内瞎捞」升级为「沿连接链精确取」。

### 4.4 连接关联（G3 的具体做法）

引擎已有关联的零件但没串起来（`get_capture_coverage` 的 hint 里能看到
`SSL=%p`、`conn=%p`、`fd=%d`、`fd 生命周期跟踪`）。完整链条：

```
getaddrinfo(host) ──► dns 事件（host → ip）
        │
socket()/connect(fd, ip:port) ──► 建立 connection{id, fd, remote}
        │
SSL_set_fd / SSLSetConnection(fd) ──► 绑定 connection ↔ SSL*（TLS 会话身份）
        │
SSL_write(ssl, buf, len) / nw_connection_send ──► 明文事件挂到该 connection
        │
send(fd, ...) / recv(fd, ...) ──► 密文元数据挂到同一 connection
        │
close(fd) ──► 关闭 connection，fd 归还池
```

实现约束：

* `fd` 复用：`close` 时把 `connection` 标记结束，新 `socket` 分配新 `id`。
* 关联不上时（例如 App 绕过 libc 直接 syscall）要**显式标注
  `connection.id = null` 并给 `hint`**，而不是静默丢弃或瞎猜。

### 4.5 盲区兜底清单

| 盲区 | 现象 | 兜底 |
|------|------|------|
| 静态链接 TLS | `SSL_*` 不在任何导入表 | `capture_memory` 引导式流程（见 D1） |
| 加密 DNS / DoH | `getaddrinfo` 不被调用；`libnetwork` 走 `dnssd_getaddrinfo_*` | 补 hook `dnssd_getaddrinfo_create` + `..._result_get_hostname`；有 `doh_uri` 时单独标注 |
| ECH | SNI 加密，`ClientHello` 里读不到域名 | 上报 `ech_config` 存在；域名改用 DNS 事件关联，拿不到就标 `sni: null` |
| QUIC / HTTP3 | `nw_connection_send` 看到的是 QUIC 包而非明文 | 在 QUIC 流层取明文；把 `alpn=h3` 的连接的 `payload_kind` 标对 |
| 裸 syscall | 不走 libc 包装 | 明确列为已知盲区，`get_capture_coverage` 里单列一行，不假装覆盖 |
| 证书固定/双向认证 | 与捕获无关，但会让人误判「没抓到 = 没请求」 | `get_diag` 里关联 `SSLHandshake` 失败事件 |

### 4.6 噪声与容量（实测约束）

从 `get_diag.pipeline` 实测到的容量：

```
hardLimit: 4096 条/分类   softLimit: 1024   journalMaxBytes: 8 MB
```

TLS 的每一次 `SSLRead` 都会触发一次 read（一次响应可能几十次），socket 层同理。
按「每次都记」的朴素做法，4096 条内存环会在**秒级**被冲掉，真正的请求头反而被挤出去。
所以：

* 默认规则：`tls-*` / `stream` 层**只在能组装出完整应用层消息时**产出事件
  （HTTP/1.1 头 + body 结束、HTTP/2 一个完整 HEADERS+DATA 流、WS 一个完整帧）。
* 无法组装时降级为**周期性摘要事件**（每连接每 N 秒一条：方向、字节数、样本）。
* 沿用现有 noise board 机制，给 TLS/socket 各建一个 board，默认可关。
* `preview` / `outputHexPreview` 的截断长度要进 `get_config`，可调。

---

## 5. 仓库侧落地（已完成部分）

这一批改动都在本仓内，不需要引擎改动：

| 改动 | 文件 | 作用 |
|------|------|------|
| 引擎同步 1.25.6 → 1.27.5 | `vendor/dylib/{rootless,roothide}/decrypt_helper.dylib` | 让仓库自带传输层捕获，而不是只有 HTTP 层 |
| 引擎清单 | `vendor/dylib/manifest.txt` | 记录 variant / 版本 / 架构 / 字节数 / SHA-256 / 来源工件 |
| 漂移守卫 | `tools/verify_vendor.sh`（新增）、`build_deb.sh` | 打包前校验「包版本 == 引擎版本」且哈希匹配，对不上直接失败 |
| 一键同步 | `tools/sync_engine.sh`（新增） | `make sync-engine TAG=v1.28.0` 拉 release、更新 dylib 与 manifest、回写 VERSION、跑校验 |
| Make 目标 | `Makefile` | `make verify-vendor`（不需要 Xcode）、`make sync-engine` |
| 说明 | `vendor/dylib/README.md` | 换引擎流程、manifest 语义、引擎自述工具（`get_capture_coverage` 等） |

为什么把校验做成**独立脚本**而不是塞进 `build_deb.sh`：打包需要 macOS + Xcode +
dpkg + ldid，而「引擎是不是旧的」这件事在**任何一台机器上**都该能查。本机实测
macOS 只有 Command Line Tools（`xcrun --sdk iphoneos` 失败、无 `dpkg-deb`、无
`ldid`），`make deb` 根本跑不起来；但 `make verify-vendor` 可以。

---

## 6. 验收标准（可执行）

### 6.1 仓库侧（无需真机）

```bash
make verify-vendor          # 必须通过；把 manifest 的 sha256 改一位应立刻失败
```

回归断言（建议进 CI，纯 bash）：

1. `VERSION` 与 manifest 的 version 不一致 → `verify_vendor.sh` 退出码 1。
2. dylib 字节数与 manifest 不符 → 退出码 1。
3. dylib SHA-256 与 manifest 不符 → 退出码 1。
4. `DH_ALLOW_ENGINE_DRIFT=1` → 跳过校验但打印警告。
5. manifest 里新增/删除 variant → 校验按 manifest 实际内容遍历，不写死两个。

### 6.2 真机侧（用 idh MCP 断言）

```bash
idh call <target_id> get_capture_coverage --json   # 目标层 available 必须为 true
idh call <target_id> get_diag --json               # unhooked 必须为空
idh call <target_id> get_stats --json              # 看 byCategory[net] 是否在预算内
idh export <target_id> --category net -o net.json  # 离线核查事件字段
```

逐层验收矩阵：

| 验收点 | 做法 | 通过标准 |
|--------|------|----------|
| HTTP 层回归 | 触发一次 App 内请求 | 出现 `layer=http` 且 `in_len>0` |
| TLS 明文（Apple 栈） | 同上，看同一连接 | 出现 `layer=tls-st`，`payload_kind=plaintext`，且 `connection.id` 与 http 事件一致 |
| TLS 明文（自带栈） | 找一个自带 BoringSSL 的 App | `get_capture_coverage` 中 `OpenSSL/BoringSSL TLS` 不再进 `blind_spots` |
| DNS | 冷启动 App | 出现 `layer=dns` 事件，host 与后续 connect 的 ip 对得上 |
| socket 元数据 | 任意网络活动 | 出现 `layer=socket` 且 `payload_kind != plaintext` |
| QUIC | 访问 h3 站点 | `connection.alpn=h3`，且能拿到明文（非 QUIC 包） |
| 关联完整性 | `correlate_request(net_seq)` | 返回同 `connection.id` 的完整链，而不是仅时间窗 | 
| 噪声预算 | 连续跑 5 分钟 | net 分类不因 TLS 高频事件溢出；HTTP 请求头不被挤掉 |

### 6.3 设备验证的已知坑（沿用 `docs/device_verification.md`）

* loader dylib 未变时**不需要 respring**：本次实测 1.25.6 → 1.27.5 的
  `IOSDecryptHubLoader.dylib` SHA-256 完全一致，引擎是 `dlopen` 的，
  重启目标 App 即生效。
* 引擎目录权限：`root:wheel`、`decrypt_helper.dylib` 0755、`version.plist` 0644。
* 装完确认 `dpkg -l com.iosdecrypthub`、`version.plist`、以及引擎文件 SHA-256
  三者一致（本次实测三者均为 1.27.5 / `77eb45b4…`）。

---

## 7. 风险与取舍

| 风险 | 影响 | 取舍 |
|------|------|------|
| inline hook 在 libboringssl 上引入崩溃 | 目标 App 崩 | 只在 `get_capture_coverage` 判定「App 自带 TLS」时才装；失败即回退到 `capture_memory` 引导 |
| TLS 层事件量爆炸 | 冲掉真正有用的 HTPP 事件 | 4.6 的「能组装才产出 + 降级摘要 + noise board」 |
| 明文落盘带来敏感数据合规风险 | 导出文件含 token/密码 | 沿用 1.27.5 已有的 `redact`（`cookie`/`authorization`/`token`/`password`/`secret`/`x-token`/`x-sign`），并在 `export_events` 文档里保持「敏感材料」警告 |
| 连接关联在 fd 复用时错配 | 串错链 | `close` 即结束 connection、新 `socket` 新 id；关联失败显式置 null |
| 引擎是闭源成品，本仓改不动 | 方案落不了地 | 本文按「给引擎侧的需求 + 本仓可独立完成的部分」划分；第 5 节已完成的都是本仓能独立交付的 |

---

## 8. 实施顺序

| 里程碑 | 内容 | 归属 | 依赖 |
|--------|------|------|------|
| M0 ✅ 已完成 | vendor 引擎同步 1.27.5、manifest、漂移守卫、sync 工具 | 本仓 | — |
| M1 | `net` 事件补 `layer` / `direction` / `payload_kind` / `connection` 字段（向后兼容，旧字段保留）；`get_capture_coverage` 的 `hint` 里写清「明文层 vs 密文层」与 D3 去重规则；**修掉 `get_diag` 那行没提网络的陈旧安装日志**（见 1.5a） | 引擎 | M0 |
| M2 | 补 `CFReadStream*` 流层（低成本、CFNetwork 已证实导入）；补 `dnssd_getaddrinfo_*` 覆盖 DoH 路径 | 引擎 | M1 |
| M3 | `tls-ossl` 用 inline hook 覆盖镜像内 BoringSSL；静态链接场景的 `capture_memory` 引导式流程 | 引擎 | M1 |
| M4 | HTTP/2 帧解析（HEADERS/DATA → `:method`/`:path`/headers），gRPC 基本识别 | 引擎 | M1 |
| M5 | QUIC 流层明文 + `alpn=h3` 标注 | 引擎 | M4 |
| M6 | 连接级 `correlate_request`（沿 `connection.id` 取链，替代时间窗） | 引擎 | M1 |
| M7 | 验收矩阵进 `docs/device_verification.md`；`make verify-vendor` 进发布前检查 | 本仓 | M1 |

M1 是分水岭：**在 M1 之前，即使抓到了传输层，使用者也分不清手里这条到底是明文还是
密文、属于哪条连接。** 建议 M1 + M2 一起发。

---

## 附：本文数据的复现命令

```bash
# 引擎层次对照（本地，无需设备）
strings -a vendor/dylib/rootless/decrypt_helper.dylib | grep -xE \
  'TLS-NW|TLS-ST|SOCKET|WEBKIT-PROBE|SSL_write|SSLWrite|nw_connection_send|getaddrinfo'

# 仓库侧校验
make verify-vendor

# 设备侧层级矩阵 / 盲区
idh call <target_id> get_capture_coverage --json
idh call <target_id> get_diag --json
idh call <target_id> get_stats --json
```
