# 项目地图

## 应用

应用入口与公开接口的完整清单见 [应用模块](../apps/README.md)。

| 路径 | 职责 |
| --- | --- |
| `apps/macos/` | macOS SwiftUI 客户端，承载本机配对和项目入口；通过本地 Swift Package 依赖统一协议 DTO。 |
| `apps/ios/` | iOS SwiftUI 客户端，承载移动端项目、会话和文件入口；通过本地 Swift Package 依赖统一协议 DTO。 |
| `apps/server/` | Node.js Relay Server；校验协议封装和路由元数据，提供中继接收边界，不解释业务 payload。 |
| `apps/agent-host/` | Mac 本地独立进程边界，组合 Agent Adapter、文件服务和 Relay 连接。 |

## 共享包

共享包的导出接口与协议一致性规则见 [共享包](../packages/README.md)。

| 路径 | 职责 |
| --- | --- |
| `packages/protocol/` | TypeScript 线协议类型、运行时校验器、JSON Schema 和跨语言测试 fixtures。 |
| `packages/client-protocol-swift/` | iOS 与 macOS 共用的 Swift `Codable` 协议 DTO 和事件联合类型。 |
| `packages/shared-types/` | 项目、会话和文件条目的跨服务领域类型。 |
| `packages/agent-core/` | Agent 能力、输入、交互响应、统一事件流与 `AgentAdapter` 接口。 |
| `packages/agent-codex/` | Codex 适配器的独立集成边界；当前仅导出适配器类型标识。 |
| `packages/agent-claude/` | Claude 适配器的独立集成边界；当前仅导出适配器类型标识。 |
| `packages/crypto/` | 加密能力的独立边界；当前仅导出边界版本。 |

## 仓库基础设施

| 路径 | 职责 |
| --- | --- |
| `package.json`、`pnpm-workspace.yaml`、`tsconfig.base.json` | pnpm workspace、统一构建命令和 TypeScript 严格编译基线。 |
