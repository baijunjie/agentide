# Agent 会话执行与事件投递

Agent 会话由 Mac 上的 Agent Host 执行和持久化。iPhone 通过已配对设备之间的 Relay 消息创建会话、发送后续消息、取消当前轮次和回应审批或问题，并以带确认的事件流取得执行结果。Relay 只负责路由 Envelope，不运行 Agent，也不保存会话记录。

统一事件字段和 Adapter 接口见 [三端通信与 Agent 契约](protocol.md)；设备鉴权、在线状态与 Relay 的短时离线缓冲见 [设备配对与 Relay 连接](device-pairing.md)。

## 会话与轮次

- 创建会话时必须指定已登记项目及该项目已启用的 Agent。Agent Host 先建立 Agent 原生会话并持久化统一 `Session`，再发送可选的初始任务。
- 会话可以包含多个顺序执行的轮次。同一会话的发送、取消和交互回应会串行执行；活动轮次结束后，会话进入 `idle`，仍可发送下一条消息。
- `turn.completed` 表示一个轮次以 `completed`、`failed` 或 `cancelled` 结束。`session.completed` 只表示整个会话真正终止，不能用来表示一次普通轮次结束。
- 发送消息的本地 IPC 只有在该轮次的 `status: running` 事件已经持久化后才返回成功。调用方因此可以在成功响应后立即按序列号读取到该轮次已开始的记录。
- 取消只中断当前活动轮次；没有活动轮次时是幂等操作。当前 Claude 与 Codex 集成都只接受文本输入，不接受附件。

## Claude 执行与归一化

Claude Adapter 通过 Claude Agent SDK 执行会话，声明支持审批、提问和原生会话恢复。新会话的统一会话 ID 同时作为 Claude 原生会话 ID；Agent Host 重启后，Adapter 会在下一轮发送前探测项目目录中的同名会话记录，已建立的会话按原生 ID 恢复，尚未真正启动的会话则以该 ID 启动首轮。

Claude 的流式文本、完整消息、工具、命令、审批、提问、错误和轮次结果都会转换为统一 `AgentEvent`。`AskUserQuestion` 中的每个问题分别产生 `question.requested`，允许提交选项、自由文本或两者；一次原生请求包含多个问题时，全部得到回应后才继续执行。

审批只暴露 SDK 当前请求允许的动作。会话级批准只应用于当前会话；SDK 禁止持久批准或没有提供相应权限建议时，不会暴露 `approve_session`。取消、完成或失败都会结束当前轮次并回到可继续发送消息的 `idle` 状态。

## Codex 执行与归一化

Codex Adapter 启动 `codex app-server` 子进程，并通过标准输入输出上的 JSONL RPC 初始化连接、创建或恢复 thread、启动或中断 turn。它声明支持审批和原生会话恢复，不声明支持提问。

Codex 的流式文本、完整消息、命令、文件变更、MCP 工具调用、审批、错误和轮次结果都会转换为统一 `AgentEvent`。审批只暴露原生请求实际允许的 `approve_once`、`approve_session` 和 `reject` 动作；回应会再映射回 Codex 的原生决定。

会话工作目录固定为登记项目的根目录。文件变更事件只允许项目内相对路径；项目外路径不会进入统一事件流。移动会表示为旧路径删除和新路径创建。

## 本地持久化与恢复

Agent Host 是会话元数据与规范化事件历史的本地权威来源：

- 会话元数据保存在本地 `sessions.json`；每个会话的事件使用独立 JSONL 日志追加保存，避免流式增量导致整份历史反复重写。
- Agent Host 按实际写入顺序为每个会话分配从 `0` 开始、严格递增且重启后稳定的 `sequence`。该持久化序列号是事件重放的唯一游标。
- 事件读取接受 `afterSequence`，只返回该序列号之后的事件。
- Agent Host 重启后，在下一次会话操作时用 `nativeSessionId` 恢复原生会话。
- 等待审批或问题时进程重启会使原生请求失效。Agent Host 在首次访问会话数据时记录可恢复错误和失败的 `turn.completed`，把会话恢复为 `idle`；旧交互回应会被明确拒绝，用户仍可开始新的轮次。

## iPhone 事件投递

远程会话操作使用 `session.create`、`session.sendMessage`、`session.cancel`、`interaction.respond` 和 `session.subscribe` 请求。Mac 校验会话确实属于请求中的项目，再转交本地 Agent Host。

规范化事件以 `agent.event` 推送。可靠投递遵循以下规则：

1. Mac 为每个“目标设备 + 会话”分别维护已确认游标，只发送游标之后的事件。
2. iPhone 成功解码事件后保存最新序列号，并发送 `agent.event.ack`。在收到对应确认之前，Mac 会重复发送该事件，不会推进游标。
3. iPhone 重新连上 Mac 后发送 `session.subscribe`，携带本机最后确认的 `afterSequence`；Mac 从 Agent Host 的持久化历史继续重放，因此 Relay 自身的短时缓冲不是会话恢复依据。
4. 一批事件以 `turn.completed` 或 `session.completed` 结束且已确认后，Mac 停止该批轮询。后续发送消息或重新订阅会启动新的投递批次。

单个 Relay Envelope 不能超过 1 MiB。若某个规范化事件本身超过该上限，Mac 会在相同 `sequence` 上改发可恢复的 `agent_event_too_large` 错误，使确认游标能够继续前进，不会让后续事件被永久阻塞。
