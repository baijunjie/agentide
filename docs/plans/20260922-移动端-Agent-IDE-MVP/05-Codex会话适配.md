# 05 Codex 会话适配

> 目标: 通过统一 Agent Adapter 对接 Codex 结构化协议，建立可创建、继续、交互、取消和归一化输出的会话闭环。
> 完成判据: 通过统一 session 和 interaction 协议可为已授权项目创建 Codex session、发送任务、实时接收归一化事件、处理一次基础 approval，并正常完成或取消会话；不依赖里程碑 07 的最终交互界面。

## 技术设计

- [ ] 优先对接 Codex app-server 或官方结构化协议，不以 PTY 文本解析作为主实现。
- [ ] 检测已登记项目环境中的 Codex 可用性，并通过 Adapter capabilities 向上层暴露能力。
- [ ] Adapter 实现 thread/session 创建与恢复、turn/message、streaming、command/tool event、approval、cancellation、completion 和 failure 映射。
- [ ] 将 Codex native session id 与里程碑 01 的统一 `Session` 关联。
- [ ] 为每个归一化事件分配稳定 sequence，保存 normalized event，并允许选择性保存 native event 用于调试。
- [ ] 基础 approval 映射为 `approval.requested`，使用 interactionId 关联 approve once、approve session 或 reject 响应。

## 实现方案

- [ ] Session Manager 在 Mac 本地管理统一 Session 与 Codex native session 的生命周期。
- [ ] 调用方通过 `session.create`、`session.sendMessage`、`session.cancel` 和 `interaction.respond` 发起操作，Mac 通过 `agent.event` 持续推送结果。
- [ ] Event Normalizer 将 Codex 原生 streaming、命令、工具、审批和终止事件转换为里程碑 01 定义的联合类型。
- [ ] Mac 本地持久化 sessions 与 events，使当前 Agent 运行不依赖 iPhone 持续在线。

## 可复用能力

- 里程碑 01 的 Agent Adapter、统一 Session 模型和 Agent Event Protocol。
- 里程碑 02 的 Relay 路由、设备身份与传输重连。

## 开发要点

- Mac 是会话与事件的权威来源，Relay 不解析或持久化 Agent 运行所需的项目内容。
