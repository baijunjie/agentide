# 项目文档

## 项目地图

- [项目地图](project-map.md)：应用、共享包、入口文件与基础设施的职责导航。

## 产品文档

- [三端通信与 Agent 契约](product/protocol.md)：Envelope、统一 Agent 事件、结构化报告、适配器和共享业务对象的现行契约。
- [Agent 会话执行与事件投递](product/agent-sessions.md)：会话生命周期、Claude/Codex 执行与报告工具、Agent Host 持久化、iPhone 会话交互与可靠重放规则。
- [设备配对与 Relay 连接](product/device-pairing.md)：Mac 与 iPhone 的设备身份、配对、鉴权、在线状态、路由、撤销和重连规则。
- [Agent 会话推送通知](product/push-notifications.md)：等待用户、任务完成或失败通知的偏好、可靠投递、iPhone 导航和 APNs 部署契约。
- [项目登记与文件浏览](product/project-files.md)：Mac 项目登记、远程项目元数据、iPhone 文件树与项目文件搜索、只读文件查看交互，以及项目根目录沙箱规则。
- [Git 变更与统一 Diff 审查](product/git-changes.md)：iPhone 的 Changes 列表、Diff Viewer、`file.changed` 深链以及 Agent Host 只读 Git 查询边界。

## 开发记忆

- [Agent 配置](memory/agent-configuration.md)：项目指令单源维护与 Codex/Claude 配置同步约定。
- [Worktree 检查环境](memory/worktree-checks.md)：新 worktree 运行质量检查前的依赖准备约定。

## 开发计划与专题文档

- [Mobile Agent IDE MVP 开发大纲](mobile-agent-ide-mvp-development-outline.md)：产品定位、总体架构、三端职责、协议、交互与 MVP 阶段划分的完整初始设计。
- [Mobile Agent IDE MVP 开发计划](plans/20260922-移动端-Agent-IDE-MVP/MVP开发计划.md)：MVP 目标、关键设计决策、里程碑状态与验收入口。
- [Monorepo 与统一协议骨架](plans/20260922-移动端-Agent-IDE-MVP/01-Monorepo与统一协议骨架.md)：工作区骨架、共享协议与跨语言 DTO 的落地记录。
- [设备配对与三端连接](plans/20260922-移动端-Agent-IDE-MVP/02-设备配对与三端连接.md)：设备配对、Presence 与三端消息路由的落地记录。
- [项目授权与文件浏览](plans/20260922-移动端-Agent-IDE-MVP/03-项目授权与文件浏览.md)：项目登记、受限文件访问与移动端浏览的落地记录。
- [Codex 会话适配](plans/20260922-移动端-Agent-IDE-MVP/05-Codex会话适配.md)：Codex app-server 接入、事件归一化与恢复能力的落地记录。
- [三层空间手势打磨](plans/20260922-移动端-Agent-IDE-MVP/08-三层空间手势打磨.md)：iPhone 三层空间导航与手势交互的落地记录。
- [状态恢复、安全收口与 MVP 验收](plans/20260922-移动端-Agent-IDE-MVP/09-状态恢复安全收口与MVP验收.md)：恢复、安全边界与 MVP 最终验收的实施状态。
- [MVP 人工验收清单](plans/20260922-移动端-Agent-IDE-MVP/人工验收清单.md)：真实设备、部署环境与完整演示链路的人工验收项目。
- [移动端功能扩展开发计划](plans/20260927-移动端功能扩展/移动端功能扩展开发计划.md)：MVP 后移动端能力的开发原则、迭代顺序和统一验收门槛。
- [Push Notification](plans/20260927-移动端功能扩展/05-PushNotification.md)：推送通知的产品范围、架构边界、实现步骤与验收状态。
- [移动端界面体验改善](plans/20260929-移动端界面体验改善/移动端界面体验改善.md)：已实现移动端功能的界面复查结论、优先级与暂缓范围。
