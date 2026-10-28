# FlClash 圈X兼容 MITM 功能实现方案

> 目标：让 FlClash 完整支持圈X(Quantumult X)式 MITM，补齐三块能力：
> ① 证书生成 + MITM 解密（已有基础）
> ② 圈X JS 脚本执行（**核心缺口，需新建**）
> ③ 远端重写规则拉取（**缺口，需新建**）
>
> 本文档基于已核实的 FlClash 源码现状，非推测。

---

## 0. 现状盘点（已逐文件核实）

FlClash 是 **Go 内核 + Flutter UI** 的架构，代理核心是**自定义 mihomo fork**（`core/Clash.Meta`，`replace github.com/metacubex/mihomo => ./Clash.Meta`），Go 版本 1.27。

### 已经实现的部分（MITM 框架 70% 已就绪）

| 能力 | 位置 | 状态 |
|---|---|---|
| CA 生成/加载/持久化 | `core/certificate.go`、`core/Clash.Meta/component/mitm/ca.go` | ✅ |
| TLS 终止 + 动态签发站点证书 | `component/mitm/interceptor.go`（`Hijack` + `leafFor(host)`） | ✅ |
| 圈X式重写规则解析 | `component/mitm/rule.go`（`ParseRules`） | ✅ |
| 固定动作重写 | `apply.go`：`reject`/`reject-200`/`reject-img`/`reject-dict`/`reject-array`/`302`/`request-header`/`response-header` | ✅ |
| IPC 接口 | `core/mitm.go`：`handleSetMitm`/`handleGetMitmCertificate`/`handleUpdateMitmRules` | ✅ |
| 设置 UI | `lib/views/mitm.dart`（`MitmView`） | ✅ |

### 缺口（本次要做的）

| 缺口 | 说明 |
|---|---|
| **JS 脚本引擎** | `go.mod` 无 goja/otto/quickjs；`rule.go` 只支持固定 action，**不支持 `script-request` / `script-response-body`** |
| **远端规则拉取** | 规则目前是 UI 里本地文本编辑，无 URL 拉取、无定时刷新 |
| **iOS 支持** | 无 `ios/` 目录；Go 核心已有 darwin/ios 分支（`ownership_unix.go`、`listener/config/tun.go`）但 App 层未接 |

---

## 1. 圈X脚本兼容的实现方案（核心）

### 1.1 技术选型：Go 侧嵌入 JS 引擎

圈X脚本本质是 JS，且依赖一套全局 API（`$request`/`$response`/`$done` 等）。在 Go 内核里执行 JS，业界成熟方案是 **goja**（纯 Go 实现的 ECMAScript 5.1 引擎，无 cgo，跨平台含 iOS 无额外依赖）。

- **选 goja 而非 otto/quickjs 的理由**：goja 活跃维护、纯 Go（iOS 交叉编译零障碍）、有 `Registry` 支持 require、性能够用。
- 依赖：`core/go.mod` 增加 `github.com/dop251/goja`。

### 1.2 架构：在现有 interceptor 里挂脚本执行器

现有 `interceptor.go` 已经有清晰的 seam（接缝）：

```go
type Handler interface {
    ServeMITM(req *http.Request) *http.Response      // 请求侧拦截
    OnResponse(resp *http.Response) *http.Response   // 响应侧拦截
}
```

**方案**：新增一个 `ScriptHandler`，实现上述接口，在固定规则之外执行圈X脚本。

```
请求进入
  ├─ 固定规则(reject/302/header) —— 已有，保留
  └─ script-request 脚本 —— 新增：
       1. 命中匹配 URL → 构建 $request 对象(JSON 序列化)
       2. goja 执行脚本
       3. 脚本 $done(...) 返回 → 应用改写(改 header/body/url/直接返回)
响应返回
  └─ script-response 脚本 —— 新增：
       1. 命中 → 构建 $response 对象
       2. goja 执行
       3. 应用 body 替换/header 改写/$done 返回
```

### 1.3 圈X全局 API 桥接（goja 侧注入）

在 goja runtime 里注入以下全局对象，桥接到 Go：

| 圈X API | Go 侧实现 |
|---|---|
| `$request` / `$response` | 把 `http.Request`/`http.Response` 序列化成 `{url, method, headers, body}` 传给 JS；JS 修改后反序列化应用 |
| `$done(obj)` | 把 JS 的返回对象回传 Go，应用到流量 |
| `$notification.post(t,s,b)` | 桥接 IPC 到 Flutter 层发本地通知 |
| `$persistentStore.read/write` | 桥接本地 KV 文件（或 SQLite，FlClash 已有 database 层） |
| `$prefs` | 桥接设置 |
| `$httpClient`（可选，放二期） | goja 里实现异步 HTTP 客户端 |
| `console.log` | 桥接 `github.com/metacubex/mihomo/log` |

### 1.4 规则语法扩展

在 `rule.go` 的 `ParseRule` 里新增两类 action，兼容圈X：

```
# 请求侧脚本
^https://example\.com/api url script-request-header https://cdn/x.js
^https://example\.com/api url script-request-body https://cdn/y.js

# 响应侧脚本
^https://example\.com/api url script-response-body https://cdn/z.js
```

对应新增 `Action` 枚举：`ActionScriptRequest`、`ActionScriptResponse`，`Arg` 存脚本 URL 或本地路径。

---

## 2. 远端规则拉取方案

### 2.1 规则源模型

复用 FlClash 已有的「订阅/配置」管理思路（`lib/providers/`），新增 MITM 规则源：

- 拉取圈X `.conf`/`.snippet` 里的 `[mitm]`、`[rewrite_local]`、`[rewrite_remote]` 段。
- 统一解析成内部 `MitmRule` 列表（含脚本 URL 的会连带拉取脚本并缓存）。

### 2.2 Go 侧新增 handler

在 `core/mitm.go` 旁新增：

```go
handleUpdateMitmRulesFromURL(params) // 拉取 URL → 解析 → 装规则 + 拉取脚本
handleRefreshMitmRules()             // 定时刷新入口
```

### 2.3 Flutter 侧

- `lib/views/mitm.dart` 增加「规则源」管理：URL 列表、手动刷新、更新间隔设置。
- 脚本与规则本地缓存，断网可用最后一份。

---

## 3. iOS 支持补齐（针对"仅 iOS 版本"这个原始诉求）

FlClash 目前无 iOS 目录。若最终要出 iOS 包，需：

1. **新增 `ios/` 平台目录**（`flutter create --platforms=ios .`）。
2. **NetworkExtension 隧道**：仿照 clashmi 的 `PacketTunnelProvider` + `ExtensionProvider` 模式，用 FlClash 的 Go core 编译 `.xcframework` 供 Swift 调用。
3. **证书信任**：iOS 上 CA 信任仍需「描述文件 + 手动信任」流程（`lib/views/mitm.dart` 的证书导出已具备基础，需加 iOS 描述文件生成）。
4. **编译**：iOS 包仍需 macOS + Xcode（或 GitHub Actions macos runner 出未签名 IPA）。

> 说明：MITM 核心逻辑（模块 1、2）是**平台无关**的 Go 代码，在 Linux/macOS/Android 上都能先开发调试；iOS 只是最后一层的隧道封装 + 证书信任注入。

---

## 4. 落地里程碑

| 里程碑 | 内容 | 交付物 | 依赖环境 |
|---|---|---|---|
| **M1** | goja 引擎接入 + 圈X API 桥接骨架 | `component/mitm/script.go` + go.mod 依赖 | 任意 Linux（可本地跑 Go test） |
| **M2** | `script-request` / `script-response` 规则解析 + 执行 | 扩展 `rule.go` + `interceptor.go` | Linux |
| **M3** | 远端规则拉取 + 脚本缓存 + 定时刷新 | `core/mitm_remote.go` + Flutter 规则源 UI | Linux |
| **M4** | iOS 平台目录 + NetworkExtension 隧道 + 描述文件信任 | `ios/` + 隧道 Swift + 证书描述文件 | macOS/Xcode 或 CI |
| **M5** | 集成联调 + 圈X订阅导入测试 | 完整可用 | macOS + 真机 |

---

## 5. 关键决策点（建议确认）

1. **JS 引擎**：goja（纯 Go、iOS 友好）——推荐；备选 quickjs（性能强但需 cgo，iOS 交叉编译复杂）。
2. **脚本执行沙箱**：是否限制脚本超时/内存（建议 goja 的 `Interrupt` + 超时，防脚本卡死隧道）。
3. **iOS 优先级**：MITM 核心逻辑可先在本机 Linux 开发验证，iOS 封装放最后（M4）。

---

## 6. 下一步可立即执行

M1（goja 引擎 + 圈X API 桥接）**不依赖 macOS、不依赖 iOS**，可以在当前 WSL 里直接写 Go 代码并跑 `go test` 验证。我可以现在就开始：
- 在 `core/Clash.Meta/component/mitm/` 下新建 `script.go`（goja 引擎 + `$request`/`$response`/`$done` 桥接）
- 扩展 `rule.go` 支持 `script-request`/`script-response`
- 写单元测试验证一个最小圈X脚本（如 body 正则替换）能跑通

需要我现在开始写 M1 的 Go 代码吗？
