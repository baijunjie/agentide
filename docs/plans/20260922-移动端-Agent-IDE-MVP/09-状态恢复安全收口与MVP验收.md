# 09 状态恢复、安全收口与 MVP 验收

> 目标: 在完整功能闭环上收口断线恢复、会话恢复与 MVP 安全边界，并通过全部端到端演示验收。
> 完成判据: iOS 断线或被系统结束后能恢复项目、会话、最近事件、待处理交互与实时流；TLS/WSS、设备身份、可撤销 token、单次配对密钥和项目路径沙箱均经验证；大纲中 7 组 MVP Demo 全部通过。

## 技术设计

- [ ] Mac 继续作为 Session Source of Truth，本地持久化 projects、sessions、events、paired devices 和 settings。
- [ ] iOS 只持久化 paired Macs、project metadata、session metadata、recent sessions、UI navigation state 和 recent file paths，事件只缓存最近一段。
- [ ] iOS 打开项目时请求 `session.list`；进入会话时请求 `session.getSnapshot`，获取 session metadata、recent normalized events、current pending interaction 和 current status。
- [ ] snapshot 恢复完成后订阅 live event stream，使用 sequence 衔接历史事件与实时事件。
- [ ] 确认所有传输使用 TLS/WSS，device identity 可验证，device token 可撤销，pairing secret 单次且短期有效。
- [ ] 确认 iOS 只能访问已登记 Project，所有文件路径均经过遍历、绝对路径与符号链接逃逸检查。
- [ ] 确认 Relay 不运行 Agent、不读取项目文件、不保存项目源码，并保留未来引入 payload E2EE 的协议空间。

## 实现方案

- [ ] 覆盖 WebSocket 断开、iOS 进入后台、iOS 被系统结束与 Mac 上 Agent 仍在运行时的恢复流程。
- [ ] 验证 snapshot 中的待审批/待回答交互不丢失，恢复后的回复仍可到达正确 Agent session。
- [ ] 执行 Demo 1：Mac 启动、添加项目、配对 iPhone，iPhone 显示项目。
- [ ] 执行 Demo 2：iPhone 新建 Codex 会话，实时查看 Agent 活动直至完成。
- [ ] 执行 Demo 3：iPhone 新建 Claude Code 会话，实时查看 Agent 活动直至完成。
- [ ] 执行 Demo 4：从 Session 右滑进入 File Browser，展开目录并复制相对路径。
- [ ] 执行 Demo 5：从 File Browser 进入 Swift、TS 或 Markdown 文件，查看内容并顺畅返回。
- [ ] 执行 Demo 6：打开 PNG/JPEG，左右切换同目录图片并返回原目录位置。
- [ ] 执行 Demo 7：Agent 请求执行操作，iPhone 显示 Approval Card，批准后 Agent 继续。

## 可复用能力

- 里程碑 02 的 heartbeat、presence、传输重连与临时消息缓冲。
- 里程碑 05–06 的 Mac 会话、事件与 native session 映射。
- 里程碑 07–08 的 iOS 会话呈现、交互卡片和 Workspace Navigation State。

## 开发要点

- 本里程碑只收口 MVP 已定义的恢复和安全边界，不扩展 Push Notification、完整 E2EE、云端 Agent Runtime 或源码云端索引。
- 任何 Windows、Android、Web、Git Diff、代码编辑、LSP、调试器、搜索、Rich Report 与更多 Agent 需求都进入 MVP 之后的独立主题。
