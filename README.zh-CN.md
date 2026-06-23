# AppleSyncKit ![](https://img.shields.io/badge/Swift-6-f05138) ![](https://img.shields.io/badge/macOS-14%2B-blue)

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager/)

[English](README.md) | **简体中文**

一个通用的、与实体无关的 Swift 库，用于通过 Cloudflare D1 Worker 进行双向同步。它实现了 last-write-wins 同步算法，包含 AES-GCM 加密、批量 HTTP 传输和本地 SQLite 持久化——设计为由消费方 CLI 嵌入使用，消费方自带自己的记录类型。

## 架构

该库不内置任何实体类型或 JSON 模式。消费方项目通过 `WritableKeyPath` 传入自己的 `Codable` 类型，并以字符串名称标识实体。依赖向内指向；没有组合根——组装工作由消费方 CLI 完成。

```
SyncEngine（无状态算法）
    ↓
D1SyncClient（HTTP 传输，actor）
    ↑
ConfigStore（持久化）    EncryptionService（AES-GCM，actor）
    ↑
SQLiteSyncStore（本地数据库）
```

### 同步策略

引擎提供两种推送策略和一种拉取：

- **`pushSnapshot`** —— 用于 EventKit/macOS。将当前状态与记录的快照进行差异比较，推送已变更的项目，然后软删除本地已不存在的远程 ID。状态在任何删除 RPC 发送之前就已持久化，因此失败的删除不会丢失已记录的推送。
- **`pushLocalOnly`** —— 用于 SQLite/Linux。推送标记为 `is_local_only` 的项目，清除该标记，然后处理删除。
- **`pull`** —— 基于游标的增量拉取，使用 last-write-wins 冲突解决。项目提供 upsert 和 delete 的闭包。

## 模块

| 模块 | 用途 |
|---|---|
| **Engine** | 无状态同步算法（`pushSnapshot`、`pushLocalOnly`、`pull`） |
| **Network** | 基于 `actor` 的 D1 Worker HTTP 客户端；批量大小 500（必须与 Worker 的 `MAX_BATCH_SIZE` 匹配） |
| **Crypto** | 对 `Codable` 载荷进行 AES-GCM 加密，绑定 `recordId|modifiedDate` 作为 AAD |
| **Models** | 值类型：`SyncEntityState`、`SyncResults`、`SyncMapping`、`SyncTimestamp`、`DateFormatting` |
| **DTO** | 内部线格式类型（`RawJSON`、`JSONValue` 保留服务器原始字节，无需 `AnyCodable`） |
| **Errors** | `SyncError` 枚举；`SyncNotFound` 协议用于跨模块的"未找到"识别 |
| **Persistence** | `~/.config/<namespace>/` 下的 JSON 状态，独占 `flock`，原子 0o600 写入 |
| **SQLite** | 本地同步的通用行辅助方法；`Connection: @unchecked Sendable` 扩展 |

## 安装

在你的 `Package.swift` 中添加：

```swift
dependencies: [
  .package(url: "https://github.com/FradSer/apple-sync-kit.git", from: "0.1.0"),
],
targets: [
  .target(
    name: "YourCLI",
    dependencies: [.product(name: "AppleSyncKit", package: "apple-sync-kit")]
  ),
]
```

## 配置

配置解析顺序：先环境变量，再 `~/.config/<namespace>/config.json`。环境变量键名按消费方项目添加前缀：

| 环境变量 | 用途 |
|---|---|
| `<PREFIX>_SYNC_API_URL` | D1 Worker URL（必须为 HTTPS） |
| `<PREFIX>_SYNC_API_TOKEN` | Worker 的 Bearer 令牌 |
| `<PREFIX>_SYNC_DEVICE_ID` | 唯一设备标识符 |
| `<PREFIX>_SYNC_ENCRYPTION_KEY` | Base64 32 字节密钥（`openssl rand -base64 32`） |

在参与同步的每台设备上导出加密密钥。

## 开发

**要求：** Swift 6.2+，macOS 14+

```bash
# 构建
swift build

# 测试
swift test

# 单个测试
swift test --filter EncryptionServiceTests/testEncryptDecryptRoundTrip

# 格式化（原地写入）
swift format --in-place --recursive Sources Tests

# 代码检查
swift format lint --strict --recursive Sources Tests
```

格式化工具是 Apple `swift-format`（内置于 `swift format` 子命令），通过 `.swift-format` 配置（2 空格缩进，100 列宽）。这不是 SwiftLint。

### 并发模型

Swift 6 严格并发。所有跨越并发边界的类型都是 `Sendable` 的。有状态的服务（`EncryptionService`、`D1SyncClient`）是 `actor`。`SQLite/Connection+Sendable.swift` 中的 `Connection: @retroactive @unchecked Sendable` 扩展是有意为之的，必须仅存在于该处——消费方项目导入它即可，不得重新声明。

## 许可证

MIT
