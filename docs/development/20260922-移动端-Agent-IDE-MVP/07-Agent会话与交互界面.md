# 07 Agent 会话与交互界面

> 目标: 将两种 Agent 的统一事件呈现为可操作的 iOS Agent Activity Feed，完成项目、会话列表、创建会话和交互响应主流程。
> 完成判据: 用户可从项目进入 Session List，选择 Claude Code 或 Codex 新建会话，在同一个 Activity Feed 中阅读输出、发送指令、批准/拒绝操作并回答问题，无需 Terminal UI。

## 技术设计

- [ ] Session List 按项目展示 title、agent type 和 running、waiting user、completed 等统一状态。
- [ ] New Session 输入包含 Agent 选择和 initial task，创建成功后直接进入 Agent Session。
- [ ] Activity Feed 支持 UserMessageBlock、AgentMarkdownBlock、ToolActivityBlock、CommandBlock、ApprovalBlock、QuestionBlock、ErrorBlock 和 StatusBlock。
- [ ] ApprovalBlock 按事件 actions 提供 approve once、approve session 和 reject；QuestionBlock 支持选项与可选自由文本。
- [ ] 输入区可向当前会话发送新消息，并正确表达 running、waiting user、completed、failed 与 cancelled 状态。
- [ ] 事件列表使用 sequence 维持稳定顺序，text delta 与最终 message 在界面上形成连续输出。

## 实现方案

- [ ] Projects → Session List → Agent Session 作为主信息架构，File Browser 作为 Agent Session 内的空间分支。
- [ ] Activity Feed 按归一化事件映射对应 Rich Block，两种 Agent 共用完全一致的呈现和操作路径。
- [ ] 交互卡片携带 interactionId，回复成功后更新卡片状态，避免对同一请求重复响应。
- [ ] 文件树中复制的名称或相对路径可直接粘贴到当前 Agent 输入区。

## 可复用能力

- 里程碑 05–06 的统一 Session 操作、Agent Event 流和 interaction response。
- 里程碑 03–04 的项目选择、File Browser 和 Viewer 状态。

## 开发要点

- 不实现复杂报告组件、Terminal emulator、Git diff 或 Agent 子任务可视化。
