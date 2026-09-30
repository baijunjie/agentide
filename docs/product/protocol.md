# 三端通信与 Agent 契约

macOS、iOS、Relay Server 与 Agent Host 通过同一套版本化 JSON 契约通信。iOS 和 Relay Server 只依赖统一协议；Claude Code 与 Codex 的原生事件必须由各自的 Adapter 转换成统一事件后再进入协议层。

## Envelope v1

已绑定设备之间经 Relay 路由的业务请求和异步推送都使用 `Envelope`。独立 HTTP 控制面对象不封装为 Envelope。固定元数据如下：

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
| `report` | 版本化结构报告；已知类型使用封闭 payload，未知类型或未来版本保留为通用报告。 |

事件中的工具输入、工具输出和错误详情是未解释的 JSON 值；其中显式 `null` 必须在跨语言编解码后保留。事件判别仅使用统一的 `type` 字段，不使用 Agent 原生字段替代。

### 结构化报告

`report` 事件除公共事件字段外，还包含正整数 `reportVersion`、非空 `reportId`、`kind`、非空 `title`、`summary` 和对象形式的 `payload`。报告中的整数字段必须在 JSON 安全整数范围内（上限 `9007199254740991`）。首版 `reportVersion` 为 `1`，定义四种已知报告：

| `kind` | payload 契约 |
| --- | --- |
| `test_report` | `total`、`passed`、`failed`、`skipped` 为非负整数，且后三者之和必须等于 `total`；`failures` 给出失败名称与可选消息。 |
| `plan` | `steps` 按顺序列出标题，状态为 `pending`、`in_progress`、`completed` 或 `blocked`。 |
| `todo` | `items` 列出标题，状态为 `not_started`、`in_progress`、`completed` 或 `blocked`。 |
| `diagnostics` | `items` 的严重级别为 `error`、`warning` 或 `info`，包含消息以及可选的项目内相对路径、正整数行列；列存在时行必须存在。 |

已知首版报告拒绝 payload 中的额外字段。诊断路径必须是使用 `/` 分段的非空项目相对路径，不接受绝对路径、反斜杠、空路径段以及 `.` 或 `..` 路径段。

客户端必须接受未知 `kind` 和高于当前支持范围的 `reportVersion`，把其对象 payload 保留为未解释的 JSON，并以通用报告呈现；已知 `reportVersion: 1` 与已知 `kind` 的组合仍必须严格满足对应 payload，不能因字段错误退回未知报告。客户端只以纯文本和固定原生组件呈现报告，不解释或执行字段中的 HTML、脚本及未知 payload。

`test_report` 的计数和式属于 JSON Schema 无法表达的跨字段语义约束。只依赖 Schema 校验的消费者还必须执行等价的运行时检查；当前 TypeScript 运行时校验器和 Swift DTO 都会拒绝不满足和式的报告。

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

## 推送通知控制面对象

推送 token 登记与通知意图使用独立的鉴权 HTTP 控制面 JSON，不封装为 Envelope。相关对象拒绝未知字段：

- `NotificationCategory` 固定为 `approval_waiting`、`question_waiting`、`task_completed` 或 `task_failed`。
- `NotificationPreferences` 包含总开关 `enabled`、等待类开关 `waitingEnabled` 和完成类开关 `completionEnabled`。
- `PushTokenRegistration` 包含长度可变的 APNs device token、`development` 或 `production` 环境以及完整偏好。`token` 必须保留系统返回的全部 token 字节，以 2 至 512 个偶数长度的 ASCII 十六进制字符编码（1 至 256 字节），不能截断或假设固定 32 字节。
- `NotificationIntent` 只包含非空 `projectId`、非空 `sessionId`、范围为 0 至 `9007199254740991` 的整数 `sequence`、通知类别、各不超过 200 个 Unicode 标量的非空 `projectName` 与 `sessionTitle`，以及 UTC 时间戳 `createdAt`。它不允许携带消息正文、命令、工具输入输出或报告内容。

这些对象由 TypeScript 类型、`notifications.schema.json`、Swift `Codable` DTO 和共同 fixture 固定跨语言接受边界。类别如何从事件产生、Relay 如何过滤和投递、iPhone 如何呈现与导航，见 [Agent 会话推送通知](push-notifications.md)。

## 共享业务对象

- `Project` 保存稳定标识、显示名、本机根路径、创建时间和启用的 Agent 类型。根路径属于 Mac 本地项目模型。
- `Session` 关联项目与 Agent，状态固定为 `starting`、`running`、`idle`、`waiting_user`、`completed`、`failed` 或 `cancelled`。`idle` 表示当前没有活动轮次但会话仍可继续。
- `FileEntry` 使用项目内相对路径标识文件或目录，并可附带大小、扩展名以及文本/图片能力标记。
- `ProjectSearchFilesRequest` 使用 1 至 128 个 Unicode 标量的 `searchId` 关联一次项目文件搜索；客户端先去除 `query` 首尾属于 Unicode `White_Space` 属性的标量，线协议值本身不得再以这类空白开头或结尾（包括 U+0085），并在匹配规范化前按原始 Unicode 标量计数 2 至 256 个，`limit` 为 1 至 100。`ProjectCancelSearchRequest` 以满足相同长度约束的 `searchId` 取消搜索。`ProjectSearchFilesResponse` 回显满足上述约束的 `searchId` 与查询文本，返回最多 100 个 `FileEntry`，并以 `hasMore` 表示受服务端边界限制或遍历期间目录变化而未返回完整结果。
- `GitChange` 使用项目内相对路径标识当前工作树变更，类型固定为 `added`、`modified`、`deleted`、`renamed` 或 `untracked`，区域固定为 `staged` 或 `unstaged`。重命名必须包含 `previousRelativePath`，其它类型禁止携带该字段；`isBinary` 必填，变更前后大小为可选的非负整数。
- `ProjectChangesResponse` 以 `isGitRepository` 区分非 Git 项目与 Git 工作树，并返回 `GitChange` 列表；非 Git 项目的列表必须为空。`ProjectDiffRequest` 只包含项目内相对路径和变更区域。`ProjectDiffResponse` 回显对应变更并可携带统一 diff；二进制变更禁止携带 `diff`。
- `SessionSnapshot` 是远程客户端恢复会话的一致视图：`session` 和 `currentStatus` 给出同一时点的会话状态，`recentEvents` 包含最近最多 200 条持久化事件，`pendingInteractions` 单独列出仍待回应的审批与问题，`latestSequence` 是完整持久化事件流的最新序列号（空流为 `-1`）。最新序列号可以高于 `recentEvents` 窗口的首条序列号，客户端不应把该窗口当作完整历史。

Envelope 与 `AgentEvent` 由 TypeScript 运行时校验器、Draft 2020-12 JSON Schema 和 Swift `Codable` DTO 共同消费正反例 fixtures，以固定各自可表达边界内的跨语言接受与拒绝行为；Schema 无法表达的跨字段语义另用运行时反例 fixture 固定。`Project`、`Session`、`FileEntry`、项目文件搜索和 Git Changes/Diff 对象当前只有 TypeScript 静态类型、JSON Schema 与 Swift DTO，没有独立的 TypeScript 运行时守卫；前三者以正例 fixture 验证共同解码，项目文件搜索、Git Changes/Diff 对象与 `SessionSnapshot` 同时使用正反例 fixtures 验证字段组合和拒绝边界。通知控制面对象还在 Relay HTTP 入口执行等价的严格运行时校验，并以共同 fixture 和正反例测试固定边界。协议字段、枚举或可选值语义变化时，相关类型、Schema、DTO、入口校验与覆盖该边界的 fixtures 必须同步更新。
