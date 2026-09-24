# 05 Codex 会话适配

> 目标: 通过统一 Agent Adapter 对接 Codex 结构化协议，建立可创建、继续、交互、取消和归一化输出的会话闭环。
> 完成判据: 通过统一 session 和 interaction 协议可为已授权项目创建 Codex session、发送任务、实时接收归一化事件、处理一次基础 approval，并正常完成或取消会话；不依赖里程碑 07 的最终交互界面。

## 落地状态

- Codex Adapter 已通过 `codex app-server` 的 JSONL RPC 实现 thread 创建/恢复、多轮 turn、streaming、命令与工具事件、文件变更、approval、取消和失败映射。统一会话以 `idle` 表示可继续发送，单轮结束使用 `turn.completed`，不会误将多轮会话标记为终止。
- Agent Host 是 Session 和归一化事件的本地权威源：Session 元数据原子写入，每个 Session 的事件按 JSONL 追加，并为跨进程恢复重新分配连续 sequence。发送 API 在新 turn 的 `status.running` 已持久化后才返回，避免转发端把历史终止事件当成当前轮次。
- Mac 与 iPhone 通过 `agent.event` 、累计 ACK 和 `session.subscribe` 传递事件，游标按设备与 Session 隔离；断线后从已确认 sequence 继续，轮次终止并确认后停止轮询。超过 Relay 大小限制的单个事件会降级为同 sequence 的可恢复错误，不会阻塞后续事件。
- 已通过全仓 TypeScript 类型检查、构建与 Node 测试、Swift 协议测试、macOS 构建、iOS Simulator 构建，并用真实 Codex app-server 完成 Agent Host 端到端冒烟会话。approval、恢复、并发发送、日志截断恢复和初始化失败由自动化测试覆盖；真机交互、网络切换和打包后 companion process 生命周期仍交给里程碑 09 验收。

## 技术设计

- [x] 优先对接 Codex app-server 或官方结构化协议，不以 PTY 文本解析作为主实现。
- [x] 检测已登记项目环境中的 Codex 可用性，并通过 Adapter capabilities 向上层暴露能力。
- [x] Adapter 实现 thread/session 创建与恢复、turn/message、streaming、command/tool event、approval、cancellation、completion 和 failure 映射。
- [x] 将 Codex native session id 与里程碑 01 的统一 `Session` 关联。
- [x] 为每个归一化事件分配稳定 sequence，保存 normalized event，并允许选择性保存 native event 用于调试。
- [x] 基础 approval 映射为 `approval.requested`，使用 interactionId 关联 approve once、approve session 或 reject 响应。

## 实现方案

- [x] Session Manager 在 Mac 本地管理统一 Session 与 Codex native session 的生命周期。
- [x] 调用方通过 `session.create`、`session.sendMessage`、`session.cancel` 和 `interaction.respond` 发起操作，Mac 通过 `agent.event` 持续推送结果。
- [x] Event Normalizer 将 Codex 原生 streaming、命令、工具、审批和终止事件转换为里程碑 01 定义的联合类型。
- [x] Mac 本地持久化 sessions 与 events，使当前 Agent 运行不依赖 iPhone 持续在线。

## 可复用能力

- 里程碑 01 的 Agent Adapter、统一 Session 模型和 Agent Event Protocol。
- 里程碑 02 的 Relay 路由、设备身份与传输重连。

## 开发要点

- Mac 是会话与事件的权威来源，Relay 不解析或持久化 Agent 运行所需的项目内容。
