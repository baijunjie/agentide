# 09 状态恢复、安全收口与 MVP 验收

> 目标: 在完整功能闭环上收口断线恢复、会话恢复与 MVP 安全边界，并通过全部端到端演示验收。
> 完成判据: iOS 断线或被系统结束后能恢复项目、会话、最近事件、待处理交互与实时流；TLS/WSS、设备身份、可撤销 token、单次配对密钥和项目路径沙箱均经验证；大纲中 7 组 MVP Demo 全部通过。

## 落地状态

- 会话快照、iOS 有界恢复缓存、项目路径沙箱和 Relay 职责边界已落地；受认证的 Agent Host companion process 也已替换 Mac App 的固定开发端点。
- Mac App 现在随包携带独立 Node 运行时、Agent Host 生产依赖和按目标架构构建的原生 helper，以随机本地端口和每次启动凭据完成就绪握手。App 监督异常退出并持续退避重启；App 或父进程退出时会关闭 HTTP 连接、并发停止 Agent adapter，并为拒绝退出的 Codex 进程组设置强制清理期限。
- 已通过全仓 TypeScript 检查、构建与测试、Swift 协议测试、macOS 与 iOS Simulator 构建；另以带空格的输出目录验证 ad-hoc 签名、最小 JIT 权限和签后 Node 探针。尚未在已签名发布 App 内手工执行真实 Claude/Codex 会话，也未完成真机、TLS/WSS 与 7 组 MVP Demo 验收。
- 本里程碑继续保留：传输与设备凭据部署验证、真机恢复路径、TCC 保护目录和全部 Demo 仍需在具备真实部署及已配对设备的环境中完成。

## 技术设计

- [x] Mac 上的 Agent Host 继续作为 projects、sessions 和 events 的本地权威源，Mac 持久化设备设置；设备绑定与撤销仍以 Relay 控制面为权威，避免产生两套安全状态。
- [x] iOS 只持久化 paired Mac、project metadata、session metadata、recent sessions、UI navigation state 和 recent file paths，事件只缓存最近一段。
- [x] iOS 打开项目时请求 `session.list`；进入会话时请求 `session.getSnapshot`，获取 session metadata、recent normalized events、current pending interactions 和 current status。
- [x] snapshot 恢复完成后订阅 live event stream，使用 sequence 衔接历史事件与实时事件。
- [ ] 确认所有传输使用 TLS/WSS，device identity 可验证，device token 可撤销，pairing secret 单次且短期有效。
- [x] 确认 iOS 只能访问已登记 Project，所有文件路径均经过遍历、绝对路径与符号链接逃逸检查。
- [x] 确认 Relay 不运行 Agent、不读取项目文件、不保存项目源码，并保留未来引入 payload E2EE 的协议空间。

## 实现方案

- [x] 将固定端口的开发期 Agent Host 替换为随 macOS App 分发、认证并受监督的 companion process；App 退出时停止 companion，发布构建不得回退到外部 Node 或固定 `127.0.0.1:8788`。
- [ ] 使用已配对真机完整检查 Session → Files → Text File、Session → Files → Image 与逐级返回，覆盖横竖屏、手势阈值和安全区域。
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
