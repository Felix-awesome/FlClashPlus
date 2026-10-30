# iOS 签名要求

FlClash 的 iOS 版是一个 **NetworkExtension 数据面**：主 App 只负责界面和
`NETunnelProviderManager` 配置，真正的 Go 核心跑在 `FlClashService.appex`
这个 packet-tunnel 扩展里，两个进程通过 App Group 共享数据目录。

这两件事都不是 App 代码能自给自足的：

| 能力 | entitlement | 用途 |
| --- | --- | --- |
| Network Extension | `com.apple.developer.networking.networkextension: [packet-tunnel-provider]` | 允许创建 VPN 配置、启动隧道进程 |
| App Group | `com.apple.security.application-groups: [group.com.follow.clash]` | 主 App 与扩展读写同一份配置/日志 |

**IPA 本身是未签名的**（`flutter build ios --no-codesign`）。它能带哪些能力，
完全由**重签时**使用的描述文件（`.mobileprovision`）决定：profile 里没有的
entitlement，重签工具会直接丢掉，且不会报错。

## 症状

启动或连接时提示：

```
PlatformException(load_failed, permission denied, null, null)
```

`permission denied` 来自 `NETunnelProviderManager.loadAllFromPreferences`：iOS
在检查调用进程的 Network Extension entitlement 时直接拒绝，**连系统的
「添加 VPN 配置」弹窗都不会出现**。这不是配置写错。

10 秒判定：点连接，看有没有弹出「"FlClash" 想要添加 VPN 配置」。

- 弹了 → 签名没问题，去看别的（见文末）。
- 没弹、直接报错 → 签名缺能力，按下面选一条路。

## 路线一：TrollStore（免费，限 iOS 14.0–16.6.1 / 17.0）

TrollStore 走的是伪签名（`ldid`），系统不校验证书链，因此可以携带任意
entitlement，包括 Network Extension 和 App Group。

CI 会额外产出一个 `FlClash-trollstore-ipa` 制品：构建脚本用

```bash
ldid -S ios/Runner/Runner.entitlements Payload/Runner.app/Runner
ldid -S ios/FlClashService/FlClashService.entitlements \
  Payload/Runner.app/PlugIns/FlClashService.appex/FlClashService
```

把两个 entitlements 写进 ad-hoc 签名，TrollStore 在安装时会重新签名但保留
二进制里已有的 entitlements。

安装：把这个 IPA 传到设备，用 TrollStore 打开 → Install。装完在
「设置 → 通用 → VPN 与设备管理」里应能看到 FlClash，首次连接会弹系统授权框。

## 路线二：付费开发者账号（稳定，$99/年）

1. Apple Developer 后台 → Identifiers，为主 App 建一个**显式** App ID
   （`com.follow.clash`），勾选 **Network Extensions**；再为扩展建
   `com.follow.clash.FlClashService`，同样勾选 Network Extensions。
2. 两个 App ID 都勾选 **App Groups**，创建 `group.com.follow.clash` 并关联。
3. 用这两个 App ID 生成 Development / Ad Hoc 描述文件。
4. 重签时要显式指定 entitlements，否则工具会用 profile 里推导出的那份：

   ```bash
   codesign -f -s "Apple Development: <你的证书>" \
     --entitlements ios/Runner/Runner.entitlements \
     --generate-entitlement-der Payload/Runner.app

   codesign -f -s "Apple Development: <你的证书>" \
     --entitlements ios/FlClashService/FlClashService.entitlements \
     --generate-entitlement-der \
     Payload/Runner.app/PlugIns/FlClashService.appex
   ```

   主 App 先签 Frameworks，扩展最后签（顺序反了会被外层签名覆盖）。

## 路线三：免费 Apple ID / 通配符企业证书

**跑不通，不用试。** Personal Team 的描述文件不包含 Network Extensions 与
App Groups；通配符企业证书（`*` App ID）同样不带这两项 capability。
App 能装上、能打开、能加配置，但一点连接就是 `permission denied`。

## 验证描述文件是否带能力

```bash
openssl smime -verify -noverify -inform der -in xxx.mobileprovision \
  | plutil -convert xml1 -o - - \
  | grep -A3 -E "networkextension|application-groups"
```

要能看到 `packet-tunnel-provider` 和 `group.com.follow.clash`。

## 如果系统弹窗出现过，仍然报错

那就不是签名问题，按顺序查：

1. 「设置 → 通用 → VPN 与设备管理 → VPN」里是否已有 FlClash 配置。
2. 扩展是否被嵌进 IPA：`Payload/Runner.app/PlugIns/FlClashService.appex` 是否存在，
   且 `CFBundleIdentifier` 为 `com.follow.clash.FlClashService`（与
   `AppDelegate.providerBundleIdentifier` 一致）。
3. App Group 容器是否可写：主 App 启动后 `getHomeDir` 应返回
   `.../group.com.follow.clash/Library/Application Support/flclash`，返回空说明
   App Group entitlement 也没进去。
