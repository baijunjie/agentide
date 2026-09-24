# 共享包

## 协议与跨语言 DTO

### `@agentide/protocol`

线协议的 TypeScript 权威边界，包含运行时校验器、JSON Schema 和跨语言 fixtures。

对外接口：

- 常量与类型：`PROTOCOL_VERSION`、`MESSAGE_NAMESPACES`、`ProtocolVersion`、`MessageNamespace`、`MessageType`。
- Envelope：`EnvelopeMetadata`、`Envelope`、`RequestEnvelope`、`ResponseEnvelope`、`ProtocolError`。
- payload：`WirePayload`、`EncryptedPayload`。
- 校验器：`isMessageType()`、`isEncryptedPayload()`、`isEnvelope()`、`isProtocolTimestamp()`。

`schema/` 提供 Envelope、响应、Agent 事件和共享业务对象的 Draft 2020-12 Schema。Envelope 与 Agent 事件的正反例 `fixtures/` 同时被 TypeScript 与 Swift 测试消费，用于固定跨语言的接受与拒绝行为；共享业务对象目前只用正例 fixture 验证 Schema 与 Swift DTO 的共同解码。

### `AgentIDEProtocol`

`packages/client-protocol-swift/` 提供 iOS 和 macOS 共用的 Swift Package，与 TypeScript/JSON Schema 线协议互操作。

对外接口：

- 协议封装：`ProtocolVersion`、`MessageType`、`Envelope`、`ResponseEnvelope`、`ProtocolError`、`WirePayload`、`EncryptedPayload`、`JSONValue`、`EmptyPayload`。
- 共享对象：`AgentType`、`SessionStatus`、`Project`、`Session`、`FileEntry`。
- Agent 事件：`AgentEvent`、13 个具体事件 DTO、`ApprovalAction` 与 `QuestionOption`。

Swift DTO 在 Envelope 和 Agent 事件的协议边界区分“缺失”和“显式 null”；未解释的 JSON payload 通过 `JSONValue` 往返，不能用普通 Swift 可选值吞掉显式 null。

## 领域与 Agent 抽象

### `@agentide/shared-types`

该包只导出 TypeScript 静态类型，不提供 `Project`、`Session` 或 `FileEntry` 的运行时守卫；运行时结构约束由 `@agentide/protocol` 中的 JSON Schema 描述，调用方需要通过 Schema validator 执行校验。

对外接口：

- `AgentType`：`claude` 或 `codex`。
- `Project`：本地项目元数据与启用的 Agent。
- `SessionStatus`、`Session`：统一会话状态与 Agent 原生会话标识。
- `FileEntry`：项目内文件或目录的相对路径元数据。

### `@agentide/agent-core`

归一化不同 Agent 的能力、命令和事件，使调用方不依赖 Claude Code 或 Codex 的原生协议。

对外接口：

- `AgentAdapter`：创建/恢复会话、发送消息、取消、回应交互和订阅异步事件。
- `AgentCapabilities`、`CreateSessionOptions`、`AgentSession`、`AgentInput`、`InteractionResponse`：Adapter 的输入输出模型。
- `AgentEvent`、`BaseEvent` 与各具体事件接口：统一事件联合类型。
- `ApprovalAction`、`QuestionOption`：用户交互的共享类型。
- `isAgentEvent()`：统一事件的运行时类型守卫。

## 集成边界

| 包 | 当前对外接口 | 职责边界 |
| --- | --- | --- |
| `@agentide/agent-codex` | `CODEX_ADAPTER_KIND`、`CodexAdapter`、`CodexAdapterOptions`、`SpawnedCodexAppServer`、`CodexAppServerConnection`、`CodexNotification`、`CodexServerRequest` | 管理 `codex app-server` JSONL RPC，并把 Codex thread、turn、工具、文件变更和审批适配为统一 Agent 契约。 |
| `@agentide/agent-claude` | `CLAUDE_ADAPTER_KIND` | Claude Adapter 的独立集成位置。 |
| `@agentide/crypto` | `CRYPTO_BOUNDARY_VERSION` | payload 加密能力的独立实现位置。 |
