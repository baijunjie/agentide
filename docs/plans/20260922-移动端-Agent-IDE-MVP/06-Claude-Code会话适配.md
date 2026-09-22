# 06 Claude Code 会话适配

> 目标: 在不改变 iOS 协议与会话模型的前提下，通过 Agent Adapter 对接 Claude Code。
> 完成判据: 通过统一 session 和 interaction 协议可为已授权项目创建 Claude Code session、发送任务、实时接收归一化事件、回答一次问题或权限请求，并正常完成或取消会话；不依赖里程碑 07 的最终交互界面。

## 技术设计

- [ ] 优先对接 Claude Agent SDK，不以 PTY 文本解析作为主实现。
- [ ] 检测已登记项目环境中的 Claude Code 可用性，并通过相同 Adapter capabilities 暴露能力。
- [ ] Adapter 实现 session 创建与 resume、streaming output、tool call、permission request、user question、cancellation、completion 和 failure 映射。
- [ ] 将 Claude native session id 与统一 Session id 关联，复用已确立的状态流转与事件顺序。
- [ ] permission request 归一为 `approval.requested`，user question 归一为 `question.requested`，后者支持选项、描述和可选自由文本回答。
- [ ] iOS 回复继续使用 `interaction.respond`，通过 interactionId 返回正确的 Claude 交互。

## 实现方案

- [ ] 复用 Session Manager 管理统一 Session 生命周期，只在 Claude Adapter 内处理 SDK 原生差异。
- [ ] Event Normalizer 将 Claude Code 输出转换为已有的 message、tool、approval、question、status、error 和 completion 事件。
- [ ] 将归一化事件与可选 native event 写入同一 Mac 本地持久化机制。
- [ ] 使用与 Codex 相同的 session、agent 和 interaction 消息边界，确保 iOS 无需引入 Claude 专用分支。

## 可复用能力

- 里程碑 05 已落地的 Session Manager、Event Normalizer、本地 sessions/events 持久化和远程消息边界。

## 开发要点

- Agent 差异只存在适配层；如果归一协议已能表达交互，不在 iOS 增加原生协议特例。
