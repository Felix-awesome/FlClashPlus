# FlClash iOS 版本开发方案（比对 clashmi 实现）

> 目标：参考 clashmi 的 iOS 实现，为 FlClash 补齐 iOS 版本。
> 本文档基于对两个工程源码的逐文件比对，结论可落地。

---

## 1. 核心架构比对（决定性差异）

两个 app 都是「**Go 代理内核 + Flutter UI**」，差异集中在 **iOS 隧道封装**这一层。

### 1.1 clashmi 的 iOS 架构（要参考的范本）

```
Go 内核 (mihomo)
   ↓ gomobile 编译
bind/apple/Libclash.xcframework     ← Go 核心，编成 xcframework 供 Swift 调用
   ↓
LibVpnCore.framework (Swift)        ← VPN 隧道层（ExtensionProvider 基类）
   ↓
clashmiService (NetworkExtension)   ← PacketTunnelProvider: ExtensionProvider {}
   ↓
libclash_vpn_service (Dart 插件)    ← vpn_service.dart 桥接 Dart ↔ 原生
```

关键文件（已核实）：
- `ios/Runner.xcodeproj/project.pbxproj`：链接 `Libclash.xcframework` + `LibVpnCore.framework` + `NetworkExtension.framework`
- `ios/clashmiService/PacketTunnelProvider.swift`：`class PacketTunnelProvider: ExtensionProvider {}`
- `ios/Runner/AppDelegate.swift`：`FlutterAppDelegate` + `FlutterImplicitEngineDelegate`
- entitlements：`packet-tunnel-provider` + App Group `group.com.nebula.clashmi`
- `lib/app/local_services/vpn_service.dart`：Dart 侧 VPN 桥接

### 1.2 FlClash 的现状（要补齐的目标）

```
Go 内核 (core/，自定义 mihomo fork)
   ├─ mobile/mobile.go         ← gomobile 绑定，但只有 //go:build android
   ├─ lib.go                   ← 核心 API：InvokeMethod/StartTun/QuickSetup/...
   └─ 已有 darwin/ios 分支     ← ownership_unix.go、listener/config/tun.go
   ↓
plugins/rust_api               ← flutter_rust_bridge（Rust 辅助，非核心）
   ↓
无 ios/ 目录                    ← ❌ 完全缺失
```

### 1.3 差距结论

| 维度 | clashmi | FlClash | 差距 |
|---|---|---|---|
| Go 内核 | mihomo | 自定义 mihomo fork | 基本一致 |
| gomobile 绑定 | `Libclash.xcframework` | `mobile.go` 仅 android | ❌ 缺 iOS 绑定 |
| VPN 隧道层 | `LibVpnCore.framework`(Swift) | 无 | ❌ 缺 |
| NetworkExtension | `PacketTunnelProvider` | 无 | ❌ 缺 |
| Dart 桥接插件 | `libclash_vpn_service` | 无（只有 rust_api 辅助） | ❌ 缺 |
| iOS 平台目录 | `ios/` | 无 | ❌ 缺 |
| MITM | 无 | 已有 Go 层实现 | ✅ FlClash 领先 |

**核心结论**：FlClash 的代理内核（含 MITM）**比 clashmi 更完整**，它缺的只是「iOS 平台封装」这一层外壳——而这层外壳 clashmi 已经做成了成熟范本，可以直接参考其结构移植。

---

## 2. FlClash iOS 移植方案

### 2.1 总体策略

**内核不动，只补平台外壳**。FlClash 的 `core/lib.go` 已经抽象出跨平台 API（`StartTun`/`InvokeMethod`/`SetEventListener` 等），iOS 移植不需要改内核逻辑，只需：

1. 给 gomobile 绑定加 `ios` 支持（参考 clashmi 的 `bind/apple/`）。
2. 新增 Swift 隧道层（NetworkExtension）。
3. 新增 Dart 桥接插件。
4. 新增 `ios/` 平台目录。

### 2.2 分步实现

#### 第 1 步：gomobile iOS 绑定

- 参考 clashmi 的 `bind/apple/Libclash.xcframework` 生成方式（`gomobile bind -target=ios`）。
- 在 FlClash 里新增 `bind/apple/`，为 `core` 包生成 iOS xcframework。
- `core/mobile/mobile.go` 目前 `//go:build android`，需新增 iOS 版本的同名绑定（`TunHandler` 接口的 iOS 实现，`Protect` 走 NE 的 `NEPacketTunnelFlow`）。

#### 第 2 步：Swift 隧道层（LibVpnCore 等价物）

参考 clashmi 的 `ExtensionProvider`，为 FlClash 新建：

```
ios/FlClashService/
  PacketTunnelProvider.swift   ← NE 入口
  VpnCore.swift                 ← 桥接 Go xcframework 的 Swift 封装
  FlClashService.entitlements  ← packet-tunnel-provider
```

- 用 `NEPacketTunnelProvider` + `NEPacketTunnelNetworkSettings` 建立 TUN。
- `TunHandler.Protect(fd)` 用 `packetFlow` 处理（iOS 上无需 Protect，直接走 UTUN）。
- 启动内核：`StartTun(fd, stack, address, dns, options)`。

#### 第 3 步：Dart 桥接插件

参考 clashmi 的 `libclash_vpn_service`，为 FlClash 新建 Dart 插件（可放 `plugins/vpn_service/`）：

- `vpn_service.dart`：暴露 `startVPN`/`stopVPN`/`onStateChanged` 等。
- 通过 MethodChannel 与 Swift 隧道层通信。

#### 第 4 步：iOS 平台目录

- `flutter create --platforms=ios .` 生成 `ios/` 骨架。
- 配置 App Group、entitlements（`packet-tunnel-provider`、`com.apple.security.network.server`）。
- 配置 `AppDelegate.swift`（`FlutterAppDelegate`）。
- Info.plist 加网络权限 + `NSAppTransportSecurity`。

### 2.3 MITM 的 iOS 落地（衔接上一份方案）

FlClash 的 MITM 是**平台无关的 Go 代码**，iOS 移植后**自动可用**。唯一平台相关的是：

- **CA 证书信任**：iOS 上需要「描述文件 + 手动信任」（`lib/views/mitm.dart` 的证书导出已具备基础，需加 `.mobileconfig` 生成）。
- **证书导出到系统**：iOS 上用 `UIActivityViewController` 或直接跳转设置。

---

## 3. 落地里程碑

| 里程碑 | 内容 | 交付物 | 环境 |
|---|---|---|---|
| **M1** | gomobile iOS 绑定（`bind/apple/`） | `FlClash.xcframework` | macOS + gomobile |
| **M2** | Swift 隧道层 + NetworkExtension | `ios/FlClashService/` | macOS + Xcode |
| **M3** | Dart 桥接插件 + iOS 平台目录 | `plugins/vpn_service/` + `ios/` | macOS |
| **M4** | MITM 证书信任 iOS 化（描述文件） | `mitm.dart` 扩展 | macOS |
| **M5** | 集成联调 + 真机部署 | 可用 iOS 包 | macOS + 真机 |

---

## 4. 关键前提与风险

| 事项 | 说明 |
|---|---|
| **macOS + Xcode** | iOS 的 gomobile 编译、Swift 隧道、真机部署**全部需要 macOS**，当前 WSL 无法执行 |
| **Apple 开发者账号** | packet-tunnel-provider 权限 + 签名需要（免费账号可用但 7 天过期、需前缀） |
| **Go 交叉编译** | gomobile 出 iOS xcframework 必须在 macOS 上（或 CI 的 macos runner） |
| **内核兼容性** | FlClash 的 mihomo fork 需确认 iOS 目标可编译（`tun.go` 已有 darwin 分支，风险低） |

---

## 5. 结论与建议

**FlClash 做 iOS 版本的技术障碍，比 clashmi 更小**——因为 FlClash 的内核（含 MITM）已经完整，缺的只是「iOS 平台外壳」这一层，而这一层有 clashmi 的成熟实现可参考。

**当前环境（WSL）能做的**：Go 内核侧的 iOS build tag 准备、`mobile.go` 的 iOS 绑定代码、Swift 隧道层源码（这些是文本代码，可以写出来，只是**编译验证必须在 Mac 上**）。

**需要 macOS 才能做的**：gomobile 编译 xcframework、Xcode 构建、真机部署。

---

## 6. 下一步

我可以立即开始做**不依赖 macOS 的纯代码产出**：

1. 写 `core/mobile/` 的 iOS gomobile 绑定（`//go:build ios` 的 `mobile_ios.go`）。
2. 写 Swift 隧道层源码（`PacketTunnelProvider.swift` + `VpnCore.swift`），参考 clashmi 结构。
3. 写 Dart 桥接插件骨架。

这些代码写好后，你在 Mac 上一键编译即可。要我开始吗？
