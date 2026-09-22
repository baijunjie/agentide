# Mobile Agent IDE MVP 开发计划

## 问题描述

Mobile Agent IDE MVP 需要让用户只使用 iPhone，即可连接自己的 Mac、打开已授权项目、操作 Claude Code 或 Codex 会话，并浏览项目文件。产品不重新实现 Agent Runtime，而是在现有 Agent 之上建立统一的远程控制层。

MVP 的完整闭环为：Mac 登记本地项目并运行 Agent，Relay Server 完成配对、在线状态和消息路由，iOS 完成会话交互、文件浏览与查看。Server 不执行代码、不读取项目文件、不持久化用户源码。

## 方案概述

采用统一 monorepo，同时承载 macOS、iOS、Server 三个当前应用，以及通信协议、Agent 抽象、Claude/Codex 适配、通用类型和密码能力。Mac 侧负责项目和会话的本地权威状态，并把不同 Agent 的原始事件归一化；iOS 只依赖统一协议；Server 只处理控制面和中继。

开发顺序按依赖方向展开：先确立可编译骨架和稳定协议，再贯通三端连接与文件能力，然后接入 Codex 和 Claude Code，最后完善 Agent Activity Feed、空间手势、恢复与安全验收。

## 关键设计决策

- 统一 Agent Adapter 和 Agent Event Protocol 是稳定边界，iOS 不直接理解 Claude Code 或 Codex 的原始协议。
- Claude Code 优先使用 Claude Agent SDK，Codex 优先使用 app-server 或官方结构化协议；PTY 只预留为后备方案。
- Mac 是项目、完整会话历史和当前交互状态的权威来源；iOS 只缓存配对、元数据、最近事件与 UI 状态。
- 文件服务由 Mac 实现，不通过 Agent 间接读取；所有路径必须限定在已登记项目根目录内。
- iOS 会话主页使用 Agent Activity Feed，不模拟 Terminal；文件浏览使用独立的三层空间导航状态，不用 `NavigationStack` 替代整个手势系统。
- 先打通文件浏览闭环，再接入 Agent，以便分开验证三端通信、移动端特色交互与 Agent 协议复杂度。
- Windows、Android、Web、代码编辑、Git 操作、LSP、调试器、Push、E2EE 完整实现与插件系统均不进入 MVP。

## 里程碑

| 顺序 | 里程碑 | 状态 | 独立验收结果 |
| --- | --- | --- | --- |
| 01 | [Monorepo 与统一协议骨架](01-Monorepo与统一协议骨架.md) | 已完成 | Mac、iOS、Server 已分别通过构建/启动验证，共享协议通过跨语言 fixtures 校验 |
| 02 | [设备配对与三端连接](02-设备配对与三端连接.md) | 已完成 | 配对、Presence、撤销与路由集成测试通过，双端构建通过；真机扫码与 WSS 部署待验 |
| 03 | [项目授权与文件浏览](03-项目授权与文件浏览.md) | 未开始 | iPhone 可安全浏览已授权项目并复制路径 |
| 04 | [文本与图片查看](04-文本与图片查看.md) | 未开始 | iPhone 可查看文本、Markdown 和同目录图片 |
| 05 | [Codex 会话适配](05-Codex会话适配.md) | 未开始 | Codex Adapter 通过统一协议完成一次实时会话 |
| 06 | [Claude Code 会话适配](06-Claude-Code会话适配.md) | 未开始 | Claude Adapter 通过统一协议完成一次实时会话 |
| 07 | [Agent 会话与交互界面](07-Agent会话与交互界面.md) | 未开始 | 无需 Terminal UI 即可完成两类 Agent 的基础交互 |
| 08 | [三层空间手势打磨](08-三层空间手势打磨.md) | 未开始 | 真机上顺畅完成 Session → Files → File 及返回 |
| 09 | [状态恢复、安全收口与 MVP 验收](09-状态恢复安全收口与MVP验收.md) | 未开始 | 断线恢复、安全边界与全部 MVP Demo 通过 |
