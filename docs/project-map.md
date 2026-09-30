# 项目地图

## 应用

应用入口与公开接口的完整清单见 [应用模块](../apps/README.md)。

| 路径 | 职责 |
| --- | --- |
| `apps/macos/` | macOS SwiftUI 客户端及其 `MacNotificationCore` Swift target，持有 Mac 设备身份与唯一 Relay 连接，随应用启动和监督本地 Agent Host companion，管理配对设备和本机登记项目，把 iPhone 的项目文件浏览与搜索、只读 Git 审查及会话请求转交该进程，负责按设备和会话确认重传 Agent 事件，并以严格 Relay 接受条件转交持久化通知 outbox；通过本地 Swift Package 依赖统一协议 DTO。 |
| `apps/ios/` | iOS SwiftUI 客户端，扫描二维码完成设备绑定，显示 Mac 与项目在线状态，列出和创建 Claude/Codex 会话，以统一 Activity Feed 承载消息、结构化报告、Agent 活动与用户交互，并可浏览和搜索项目文件、查看 Git Changes 与统一 diff；同时管理 APNs 授权、token、通知偏好和通知到会话的深链；通过本地 Swift Package 依赖统一协议 DTO。 |
| `apps/server/` | Node.js Relay Server，使用 PostgreSQL 持久化设备、配对会话、绑定、APNs token 与租约式通知幂等记录，负责鉴权、Presence、心跳、绑定内 Envelope 路由、短时断线缓冲，以及按绑定和偏好扇出最小通知意图；不解释业务 Envelope payload。 |
| `apps/agent-host/` | 随 macOS 应用分发的本地 companion 进程，持久化项目登记、统一会话、权威事件日志和可从事件区间水位补齐的有界通知 outbox，通过经启动凭据鉴权的 loopback HTTP IPC 管理 Agent 会话与通知游标，并提供受项目根目录约束的文件浏览、文件搜索与固定参数的只读 Git 查询。 |

## 共享包

共享包的导出接口与协议一致性规则见 [共享包](../packages/README.md)。

| 路径 | 职责 |
| --- | --- |
| `packages/protocol/` | TypeScript 线协议类型、运行时校验器、JSON Schema 和跨语言测试 fixtures，包括结构化报告、推送通知控制面、项目文件搜索与 Git Changes/Diff 的字段组合约束。 |
| `packages/client-protocol-swift/` | iOS 与 macOS 共用的 Swift `Codable` 协议 DTO（含结构化报告、推送通知控制面、通知 outbox 页面和项目文件搜索对象）及事件联合类型。 |
| `packages/shared-types/` | 项目、会话、推送通知控制面、文件条目、项目文件搜索和 Git Changes/Diff 的跨服务领域类型。 |
| `packages/agent-core/` | Agent 能力、输入、交互响应、含结构化报告的统一事件流与 `AgentAdapter` 接口。 |
| `packages/agent-codex/` | `codex app-server` JSONL RPC 客户端及 Codex 到统一会话、事件、审批和第一方结构化报告工具的适配器。 |
| `packages/agent-claude/` | 基于 Claude Agent SDK 的 Claude Code 适配器，把会话、流式输出、工具、命令、审批、提问和第一方结构化报告归一化为统一 Agent 契约。 |
| `packages/crypto/` | 加密能力的独立边界；当前仅导出边界版本。 |

## 仓库基础设施

| 路径 | 职责 |
| --- | --- |
| `package.json`、`pnpm-workspace.yaml`、`tsconfig.base.json` | pnpm workspace、统一构建命令和 TypeScript 严格编译基线。 |
| `scripts/test-push-notification.mjs` | 经真实 Agent Host HTTP 与 Relay HTTP、使用 Mock APNs 验证推送离线扇出、成功确认和临时故障重试的根级集成测试。 |
