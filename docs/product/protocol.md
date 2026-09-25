# 三端通信与 Agent 契约

macOS、iOS、Relay Server 与 Agent Host 通过同一套版本化 JSON 契约通信。iOS 和 Relay Server 只依赖统一协议；Claude Code 与 Codex 的原生事件必须由各自的 Adapter 转换成统一事件后再进入协议层。

## Envelope v1

所有请求和异步推送都使用 `Envelope`。固定元数据如下：

| 字段 | 约束 |
| --- | --- |
| `version` | 固定为 `1`。 |
| `id` | 非空消息标识。 |
| `type` | 点分消息类型，首段必须属于封闭命名空间。 |
| `sourceDeviceId` | 非空来源设备标识。 |
| `targetDeviceId` | 可选目标设备标识。 |
| `projectId` | 可选项目上下文。 |
| `sessionId` | 可选会话上下文。 |
| `timestamp` | UTC `Z` 时区的 ISO 8601 时间字符串。 |
| `payload` | 请求与推送必填，可为明文值或加密载荷。 |

合法消息命名空间只有 `system.*`、`pairing.*`、`project.*`、`file.*`、`session.*`、`agent.*` 和 `interaction.*`。命名空间以外的 Agent 原生消息不能直接进入三端协议。

响应沿用相同元数据，并通过非空 `replyTo` 指向请求 `id`。`ok` 表示结果；`payload` 可省略，错误由 `error.code`、`error.message` 和可选的 `error.details` 表达。Agent 流式事件不套用 request/reply，而是独立异步推送。

协议拒绝未知 Envelope 字段、空的必填标识、非 UTC 时间、未知协议版本和显式 `null` 的可选路由字段。可选字段省略与 `payload: null` 是不同状态；响应可用后者表达一个明确的空载荷。

## WirePayload

`payload` 可以是明文业务值，也可以是以下加密载荷：

```json
{
  "encryptionVersion": 1,
  "ciphertext": "..."
}
```

该结构只定义线协议上的版本与密文字段，不代表系统已经提供密钥协商、加解密或端到端加密流程。只要对象出现 `encryptionVersion` 或 `ciphertext` 之一，就必须完整满足加密载荷结构，不能退回按普通业务对象解释。

## 统一 Agent 事件

每个 `AgentEvent` 都包含非空 `id`、非空 `sessionId`、非负整数 `sequence`、UTC 时间戳和 `type`。`sequence` 是会话内稳定排序与重放的依据。

| `type` | 语义 |
| --- | --- |
| `session.started` | 会话已启动，可附带 Agent 原生会话标识。 |
| `text.delta` | 流式文本增量。 |
| `message` | 完整的用户、Agent 或系统消息，格式为纯文本或 Markdown。 |
| `tool.started` | 工具开始执行，可携带标题与未解释的输入。 |
| `tool.finished` | 工具执行结束，可携带未解释的输出或错误文本。 |
| `command` | 命令开始、完成或失败，可在结束时附带退出码。 |
| `file.changed` | 项目内相对路径被创建、修改或删除。 |
| `approval.requested` | 请求用户一次批准、会话级批准或拒绝。可用动作必须是非空集合。 |
| `question.requested` | 请求用户选择选项或按 `allowFreeText` 提交自由文本。 |
| `status` | 会话正在运行、空闲或等待用户。 |
| `error` | 带稳定错误码、消息和可恢复标记的错误。 |
| `turn.completed` | 当前轮次以完成、失败或取消结束；会话随后仍可继续。 |
| `session.completed` | 整个会话以完成、失败或取消终止。 |

事件中的工具输入、工具输出和错误详情是未解释的 JSON 值；其中显式 `null` 必须在跨语言编解码后保留。事件判别仅使用统一的 `type` 字段，不使用 Agent 原生字段替代。

## Agent Adapter

所有 Agent 集成实现同一 `AgentAdapter` 边界：

- `capabilities()` 声明审批、提问与恢复会话能力；
- `createSession()` 和 `resumeSession()` 建立统一会话；
- `sendMessage()` 发送文本及可选附件；
- `cancel()` 取消会话；
- `respondToInteraction()` 回应审批或问题；
- `events()` 以异步序列提供 `AgentEvent`。

Adapter 类型只能是 `claude` 或 `codex`。上层以统一会话 ID 调用 Adapter；Agent 自己的会话标识单独保存在 `nativeSessionId`，不替代统一会话 ID。

Claude 与 Codex 的现行能力、会话恢复以及统一事件的持久化和远程投递规则见 [Agent 会话执行与事件投递](agent-sessions.md)。

## 共享业务对象

- `Project` 保存稳定标识、显示名、本机根路径、创建时间和启用的 Agent 类型。根路径属于 Mac 本地项目模型。
- `Session` 关联项目与 Agent，状态固定为 `starting`、`running`、`idle`、`waiting_user`、`completed`、`failed` 或 `cancelled`。`idle` 表示当前没有活动轮次但会话仍可继续。
- `FileEntry` 使用项目内相对路径标识文件或目录，并可附带大小、扩展名以及文本/图片能力标记。

Envelope 与 `AgentEvent` 由 TypeScript 运行时校验器、Draft 2020-12 JSON Schema 和 Swift `Codable` DTO 共同消费正反例 fixtures，以固定跨语言的接受与拒绝行为。`Project`、`Session` 和 `FileEntry` 当前只有 TypeScript 静态类型、JSON Schema 与 Swift DTO，并以正例 fixture 验证共同解码；它们没有独立的 TypeScript 运行时守卫。协议字段、枚举或可选值语义变化时，相关类型、Schema、DTO 与覆盖该边界的 fixtures 必须同步更新。
