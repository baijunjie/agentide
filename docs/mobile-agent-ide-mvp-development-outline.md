# Mobile Agent IDE — MVP 开发大纲

> 目标：实现一个可实际跑通的 Mobile Agent IDE MVP。Mac 负责运行和连接本地 Agent Runtime，iOS 负责远程控制、会话交互与项目浏览，Server 负责设备配对、连接中继与消息路由。

---

## 1. 产品定位

本项目不是重新实现 Claude Code、Codex 或新的 AI Coding Agent，而是构建一个统一的 **Agent Control Plane / Mobile Agent IDE Shell**。

核心原则：

- Claude Code / Codex 继续负责代码理解、文件修改、工具调用、命令执行与 Agent Loop。
- Mac 客户端负责本地项目访问、Agent Runtime 适配、文件系统访问与远程连接。
- iOS App 负责用户交互、会话控制、项目浏览、文件查看与 Agent 操作。
- Server 不执行代码，不持有项目源码，只负责连接发现、中继、鉴权、在线状态和推送基础能力。
- 从第一版开始建立统一 Agent Adapter 与 Event Protocol，避免 iOS 直接耦合 Claude Code / Codex 的原始协议。

MVP 的重点不是功能广度，而是跑通完整闭环：

```text
Mac 项目
  ↓
Claude Code / Codex
  ↓
Mac Client
  ↓
Relay Server
  ↓
iOS App
  ↓
创建会话 / 交互 / 浏览文件 / 查看内容 / 复制路径 / 回到 Agent 继续指令
```

---

## 2. Monorepo 总体结构

建议采用统一 monorepo：

```text
mobile-agent-ide/
├── apps/
│   ├── macos/                  # 当前实现
│   ├── ios/                    # 当前实现
│   ├── server/                 # 当前实现
│   ├── windows/                # 预留，不实现
│   ├── android/                # 预留，不实现
│   └── web/                    # 预留，不实现
│
├── packages/
│   ├── protocol/               # 统一通信协议 / DTO / Event 定义
│   ├── agent-core/             # Agent Adapter 抽象
│   ├── agent-codex/            # Codex Adapter
│   ├── agent-claude/           # Claude Code Adapter
│   ├── shared-types/           # 通用类型
│   └── crypto/                 # 配对 / 加密 / token 基础能力
│
├── docs/
│   ├── architecture.md
│   ├── protocol.md
│   ├── ios-navigation.md
│   └── agent-adapters.md
│
├── scripts/
├── package.json                # JS/TS workspace 根配置
├── pnpm-workspace.yaml
└── README.md
```

### 推荐技术边界

- `apps/macos`：Swift / SwiftUI + 本地 daemon 能力，或 Swift GUI + Node/TS companion process。
- `apps/ios`：Swift + SwiftUI。
- `apps/server`：TypeScript + Node.js/Bun，WebSocket 为主。
- `packages/protocol`：TypeScript 源定义 + JSON Schema；iOS 侧可基于 Schema 生成 Swift 类型，或手工维护一层稳定 DTO。
- Agent 适配优先放 TypeScript，尤其 Claude Agent SDK 与 Codex app-server 接入更方便。

MVP 可以允许 Mac GUI 与本地 Agent Host 进程拆分：

```text
macOS App
   │
   ├── UI / Pairing / Project List
   │
   └── Agent Host Process
       ├── Claude Adapter
       ├── Codex Adapter
       ├── File Service
       └── Relay Client
```

这样未来 Windows 客户端只需复用 Agent Host 核心逻辑。

---

## 3. 系统总体架构

```text
┌──────────────────────────────────────────────┐
│                  Mac Client                  │
│                                              │
│  Project Registry                            │
│       │                                      │
│       ├── File Service                       │
│       ├── Session Manager                    │
│       ├── Agent Adapter Layer                │
│       │     ├── Claude Code                  │
│       │     └── Codex                        │
│       ├── Event Normalizer                   │
│       └── Relay Client                       │
└──────────────────────┬───────────────────────┘
                       │ outbound WSS
                       ▼
┌──────────────────────────────────────────────┐
│                 Relay Server                 │
│                                              │
│  Pairing / Auth / Presence / Routing         │
└──────────────────────┬───────────────────────┘
                       │ WSS
                       ▼
┌──────────────────────────────────────────────┐
│                   iOS App                    │
│                                              │
│  Connection                                  │
│  Project                                     │
│  Session List                                │
│  Agent Session UI                            │
│  File Browser                                │
│  File Viewer                                 │
│  Image Viewer                                │
└──────────────────────────────────────────────┘
```

MVP 中 Server 不直接连接 Claude/Codex，也不直接读取用户项目。

---

# 4. Mac 客户端

## 4.1 MVP 目标

Mac 客户端只承担必要职责：

1. 选择并登记本地项目。
2. 方便地与 iOS App 配对并建立远程连接。
3. 启动、恢复、管理 Claude Code / Codex 会话。
4. 把 Agent 原始事件转换成统一 Event。
5. 提供项目文件树与文件读取接口。
6. 将 iOS 操作转发给对应 Agent。

不做完整 IDE，不做代码编辑器，不做复杂 Terminal。

---

## 4.2 Mac UI

MVP 使用极简菜单栏 App 或小型窗口。

### 首页建议

```text
Mobile Agent IDE

Status
● Connected

Paired Devices
- Junjie's iPhone

Projects
- PutWhere              Online
- AnotherProject        Offline

[ Add Project ]
[ Pair iPhone ]
```

### Pair iPhone

点击后：

```text
Pair New Device

[ QR Code ]

Pairing code: 382 921
Expires in 5:00
```

iOS 扫码完成后：

```text
✓ Junjie's iPhone connected
```

---

## 4.3 Project Registry

项目数据：

```ts
interface Project {
  id: string;
  name: string;
  rootPath: string;
  createdAt: string;
  enabledAgents: AgentType[];
}
```

MVP 支持：

- 添加目录
- 删除项目登记
- 项目重命名显示名
- 检测 Claude Code / Codex 是否可用

不修改项目本身。

---

## 4.4 Agent Adapter

统一接口：

```ts
interface AgentAdapter {
  type: 'claude' | 'codex';

  capabilities(): AgentCapabilities;

  createSession(options: CreateSessionOptions): Promise<AgentSession>;

  resumeSession(nativeSessionId: string): Promise<AgentSession>;

  sendMessage(sessionId: string, input: AgentInput): Promise<void>;

  cancel(sessionId: string): Promise<void>;

  respondToInteraction(
    sessionId: string,
    interactionId: string,
    response: InteractionResponse
  ): Promise<void>;

  events(sessionId: string): AsyncIterable<AgentEvent>;
}
```

### Claude Code

优先接 Claude Agent SDK，不以 PTY 文本解析为主架构。

需要支持：

- 创建 session
- resume session
- streaming output
- tool call
- permission request
- user question
- completion / failure

### Codex

优先接 Codex app-server / 官方结构化协议。

需要支持：

- thread/session 创建
- turn/message
- streaming
- command / tool event
- approval
- cancellation
- completion / failure

### PTY Fallback

MVP 可预留：

```text
agent-pty-adapter/
```

但不作为首选实现。

---

# 5. Unified Agent Event Protocol

这是整个项目最重要的稳定层。

iOS 不直接理解 Claude / Codex 的原始协议，只理解统一 Event。

## 5.1 MVP Event 类型

```ts
type AgentEvent =
  | SessionStartedEvent
  | TextDeltaEvent
  | MessageEvent
  | ToolStartedEvent
  | ToolFinishedEvent
  | CommandEvent
  | FileChangedEvent
  | ApprovalRequestedEvent
  | QuestionRequestedEvent
  | StatusEvent
  | ErrorEvent
  | SessionCompletedEvent;
```

### 基础结构

```ts
interface BaseEvent {
  id: string;
  sessionId: string;
  sequence: number;
  timestamp: string;
  type: string;
}
```

### Message

```ts
interface MessageEvent extends BaseEvent {
  type: 'message';
  role: 'agent' | 'user' | 'system';
  content: string;
  format: 'plain' | 'markdown';
}
```

### Tool

```ts
interface ToolStartedEvent extends BaseEvent {
  type: 'tool.started';
  toolName: string;
  title?: string;
  input?: unknown;
}
```

### Approval

```ts
interface ApprovalRequestedEvent extends BaseEvent {
  type: 'approval.requested';
  interactionId: string;
  title: string;
  description?: string;
  command?: string;
  actions: ('approve_once' | 'approve_session' | 'reject')[];
}
```

### Question

```ts
interface QuestionRequestedEvent extends BaseEvent {
  type: 'question.requested';
  interactionId: string;
  question: string;
  options?: {
    id: string;
    label: string;
    description?: string;
  }[];
  allowFreeText: boolean;
}
```

---

# 6. Agent Session 数据模型

```ts
interface Session {
  id: string;
  projectId: string;
  agentType: 'claude' | 'codex';
  nativeSessionId?: string;
  title: string;
  status:
    | 'starting'
    | 'running'
    | 'waiting_user'
    | 'completed'
    | 'failed'
    | 'cancelled';
  createdAt: string;
  updatedAt: string;
}
```

Mac 本地保存 Session 映射，确保 iPhone 断线后可恢复。

建议本地 SQLite：

```text
projects
sessions
events
paired_devices
settings
```

其中 events 保存：

- normalized event
- native event（可选，方便调试）

---

# 7. File Service

文件浏览必须由 Mac Client 自己实现，不通过 Agent 获取。

## 7.1 MVP API

```text
project.listFiles
project.readFile
project.listImages
```

建议内部接口：

```ts
listDirectory(projectId, relativePath)
readTextFile(projectId, relativePath)
readBinaryFile(projectId, relativePath)
listSiblingImages(projectId, relativePath)
```

### File Entry

```ts
interface FileEntry {
  name: string;
  relativePath: string;
  type: 'file' | 'directory';
  size?: number;
  extension?: string;
  isText?: boolean;
  isImage?: boolean;
}
```

## 7.2 安全规则

所有传入路径：

```text
projectRoot + normalizedRelativePath
```

必须验证最终路径仍位于 `projectRoot` 内。

禁止：

```text
../../
absolute path escape
symlink escape
```

MVP 可默认忽略：

```text
.git/
node_modules/
DerivedData/
.build/
Pods/
```

但允许以后由用户设置。

---

# 8. iOS App 信息架构

MVP 主流程：

```text
Connection / Projects
        ↓
Project
        ↓
Session List
        ↓
Agent Session
        → File Browser
              → File Viewer
              → Image Viewer
```

---

# 9. iOS 首屏：项目连接

如果没有 Mac：

```text
Mobile Agent IDE

No Mac connected

[ Scan Pairing QR ]
```

连接后：

```text
Projects

● PutWhere
  Mac mini · Online

● MyServer
  Mac mini · Online
```

点项目进入 Session List。

---

# 10. Session List

```text
< Projects               PutWhere

Sessions

● Fix Search Race Condition
  Codex · Running

● Refactor Settings
  Claude · Waiting for approval

○ Review subscription flow
  Claude · Completed

                 [ + New Session ]
```

## 创建 Session

MVP 弹出：

```text
New Session

Agent
[ Claude Code ]
[ Codex       ]

Initial task
[______________________]

[ Create ]
```

创建成功直接进入 Agent Session。

---

# 11. Agent Session 主屏幕

这是 MVP 最重要的页面。

不要设计成纯聊天 App，而是采用简化 Agent Activity Feed。

建议结构：

```text
< Sessions        Fix Search Race       •••
────────────────────────────────────────────

You
修复 SearchViewModel 的 race condition

Agent
我正在检查搜索请求生命周期……

┌──────────────────────────────────────┐
│ Read                                 │
│ SearchViewModel.swift                │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ Running                              │
│ xcodebuild test ...                  │
└──────────────────────────────────────┘

Agent
问题来自旧任务没有取消……

────────────────────────────────────────────
[ Message Agent...                   ] [↑]
```

## MVP 需要支持的 Rich Blocks

- UserMessageBlock
- AgentMarkdownBlock
- ToolActivityBlock
- CommandBlock
- ApprovalBlock
- QuestionBlock
- ErrorBlock
- StatusBlock

不需要第一版支持复杂报告组件。

---

# 12. 核心交互：右滑多层空间 UI

这是产品亮点，需要作为独立 UI 系统设计。

定义 3 层：

```text
Level 0：Agent Session
Level 1：File Browser
Level 2：Text File Viewer
```

视觉上每深入一级，前一级退到左侧、缩小并雾化。

---

## 12.1 Level 0 → Level 1

用户在 Session 主页面向右滑。

完成状态：

```text
┌─────────────┬──────────────────────────────────┐
│             │                                  │
│   Session   │          File Browser            │
│             │                                  │
│   1 / 4     │             3 / 4                │
│             │                                  │
└─────────────┴──────────────────────────────────┘
```

### 左侧 Session Panel

- 宽度：屏幕约 25%
- scale：约 0.92–0.96
- blur：适度
- opacity：降低
- 禁止交互
- 保留整体画面，让用户明确知道自己仍在同一个 Session 上下文中

### 右侧 File Browser

- 宽度约 75%
- 高度全屏
- 圆角卡片 / 独立层级
- 带阴影或材质区别
- 可以继续向右滑进入下一层

返回：

- 向左滑
- 或点击左侧雾化区域

---

## 12.2 File Browser 设计

核心是层级清晰、好看、适合手机。

示意：

```text
PutWhere

⌄ apps
   ⌄ ios
      ⌄ PutWhere
         › Features
         › Services
         ▾ Views
            SettingsView.swift
            SearchView.swift

› server
› docs

README.md
CLAUDE.md
```

### 文件夹

- 可展开 / 收起
- 使用 indentation 表达层级
- 展开动画自然
- 图标颜色轻量区分
- 当前展开路径需要视觉连续

### 文件

支持：

- 文本文件
- Markdown
- 图片
- 其他文件显示但不可打开

### 长按菜单

任何文件 / 文件夹：

```text
Copy Name
Copy Relative Path
```

例如：

```text
Copy Name
SettingsView.swift
```

```text
Copy Relative Path
apps/ios/PutWhere/Views/SettingsView.swift
```

这样用户可以直接粘贴进 Agent 输入框。

---

# 13. File Browser → Text File Viewer

如果点击可打开的文本文件：

先进入预选状态，然后通过继续向右滑进入文件 Viewer。

也可以允许：

```text
点击文件 → 自动触发二级推进动画
```

但交互视觉仍表现为第二级右滑层。

最终：

```text
┌─────────────┬──────────────────────────────────┐
│             │                                  │
│ File Browser│          File Viewer             │
│             │                                  │
│    1 / 4    │             3 / 4                │
│             │                                  │
└─────────────┴──────────────────────────────────┘
```

此时：

- Session 主屏完全离场
- File Browser 缩到左侧约 1/4
- File Browser blur + scale down
- File Viewer 占 3/4

这样形成明确空间层级：

```text
Session
  ↳ Files
      ↳ File
```

---

# 14. Text File Viewer

MVP 只读。

支持：

- 普通文本
- Markdown

建议：

```text
SettingsView.swift
apps/ios/PutWhere/Views/SettingsView.swift
──────────────────────────────────

1  import SwiftUI
2
3  struct SettingsView: View {
...
```

Markdown 文件：

- 默认 Rendered Markdown
- 后续再增加 Source / Preview 切换

普通源码：

- 等宽字体
- 行号
- 横向滚动
- 不做完整 syntax highlighting 也可作为 MVP

建议第一版至少按扩展名提供简单 syntax color；如果时间紧可后置。

### 长按

Viewer 顶部支持：

```text
Copy File Name
Copy Relative Path
```

后续再扩展：

```text
Send to Agent
Reference Current File
Reference Selected Lines
```

MVP 暂不实现。

---

# 15. 图片 Viewer

图片与文本不同。

在 File Browser 点击图片时：

- 不继续右滑进入 Level 2
- 直接打开全屏 Image Viewer

### Image Viewer

支持：

- pinch zoom
- double tap zoom
- drag
- swipe left/right 查看同目录其他图片

打开图片时 Mac 返回：

```ts
{
  current: 'assets/demo1.png',
  siblings: [
    'assets/demo1.png',
    'assets/demo2.png',
    'assets/demo3.jpg'
  ]
}
```

Viewer 采用分页模式。

关闭后回到原 File Browser 状态和滚动位置。

---

# 16. iOS Navigation / Gesture State Machine

不要直接用系统 NavigationStack 模拟所有层级。

建议单独建立：

```swift
enum WorkspaceLayer {
    case session
    case browser
    case file(FileReference)
}
```

或者：

```swift
struct WorkspaceNavigationState {
    var browserPresented: Bool
    var selectedFile: FileReference?
    var imageViewer: ImageViewerState?
}
```

主容器自行管理：

- offset
- scale
- blur
- zIndex
- gesture progress

### 视觉层级建议

Level 0：

```text
scale 1.00
blur 0
```

Level 0 退场：

```text
width ~25%
scale ~0.94
blur 6–12
opacity ~0.7
```

Level 1 激活：

```text
width ~75%
scale 1.0
blur 0
```

进入 Level 2 时 Level 1 使用类似退场参数。

具体参数开发时调优，不写死到协议层。

---

# 17. Server

Server 只承担控制平面与中继。

## 17.1 MVP 职责

- Mac Client 注册连接
- iOS Client 注册连接
- Pairing
- Device identity
- Project / device online presence
- WebSocket message routing
- 心跳
- 重连
- 临时消息缓冲

暂不负责：

- Agent Runtime
- 用户源码持久化
- 项目索引
- Git
- 文件系统

---

## 17.2 Server 模块结构

```text
apps/server/src/
├── auth/
├── pairing/
├── websocket/
├── routing/
├── presence/
├── devices/
├── projects/
├── push/
└── storage/
```

MVP 数据库：PostgreSQL。

可选 Redis 后置，不作为必须依赖。

---

# 18. Pairing Protocol

建议流程：

```text
Mac
 │
 │ createPairingSession
 ▼
Server
 │
 │ pairingId + token + QR payload
 ▼
Mac displays QR

          iOS scans QR
               │
               ▼
             Server
               │
        verifies pairing
               │
       binds iOS ↔ Mac
               │
               ▼
            Success
```

QR payload 示例：

```json
{
  "version": 1,
  "server": "wss://relay.example.com",
  "pairingId": "...",
  "secret": "..."
}
```

Secret 必须：

- 短期有效
- 单次使用
- 成功绑定后立即失效

---

# 19. WebSocket Message Envelope

统一 Envelope：

```ts
interface Envelope<T = unknown> {
  version: 1;
  id: string;
  type: string;
  sourceDeviceId: string;
  targetDeviceId?: string;
  projectId?: string;
  sessionId?: string;
  timestamp: string;
  payload: T;
}
```

消息类别：

```text
system.*
pairing.*
project.*
file.*
session.*
agent.*
interaction.*
```

例如：

```text
session.create
session.sendMessage
session.cancel
agent.event
interaction.respond
file.list
file.read
file.listImages
```

---

# 20. 请求 / 响应模式

使用 requestId：

```ts
interface RequestEnvelope {
  id: string;
  type: string;
  payload: unknown;
}
```

响应：

```ts
interface ResponseEnvelope {
  replyTo: string;
  ok: boolean;
  payload?: unknown;
  error?: ProtocolError;
}
```

Agent streaming event 不使用 request-response，直接异步 push。

---

# 21. 基础安全设计

MVP 就需要有基本安全边界。

### 必须实现

- TLS / WSS
- device identity
- pairing secret 单次有效
- project path sandbox
- device token 可撤销
- Mac 主动向 Relay 建立 outbound connection
- iOS 不能任意访问 Mac 文件系统，只能访问已登记 Project

### 推荐尽早设计

Payload E2EE：

```text
Mac → encrypted payload → Relay → encrypted payload → iPhone
```

MVP 若为了快速跑通暂不做完整 E2EE，也应保证协议层未来可增加：

```ts
encryptionVersion?: number;
ciphertext?: string;
```

Server 数据模型避免依赖可读源码内容。

---

# 22. iOS 本地数据

iOS 不需要保存完整项目。

本地持久化：

```text
paired macs
project metadata
session metadata
recent sessions
UI navigation state
recent file paths
```

Agent Event 可缓存最近一段，完整 session history 以 Mac 为权威来源。

---

# 23. Session 恢复机制

Mac 是 Session Source of Truth。

iOS 打开项目：

```text
session.list
```

Mac 返回当前 sessions。

进入 session：

```text
session.getSnapshot
```

返回：

```text
session metadata
recent normalized events
current pending interaction
current status
```

随后订阅 live event stream。

因此 iOS 被系统杀掉后可以恢复。

---

# 24. MVP 开发阶段

## Phase 0 — Monorepo 与协议骨架

目标：各项目能编译运行。

完成：

- monorepo
- macOS app shell
- iOS app shell
- server shell
- protocol package
- agent-core package
- CI 基础配置

验收：

```text
Mac app starts
iOS app starts
Server starts
```

---

## Phase 1 — Mac ↔ Server ↔ iOS 通信

完成：

- WebSocket
- device registration
- pairing
- QR
- presence
- ping/pong
- reconnect

验收：

```text
Mac 显示 iPhone 已连接
iPhone 显示 Mac Online
```

---

## Phase 2 — Project 与 File Browser

完成：

- Mac 添加 project
- iOS project list
- file.list
- directory expand/collapse
- file hierarchy UI
- copy filename
- copy relative path

验收：

用户能在手机完整浏览 Mac 上已授权项目目录。

---

## Phase 3 — File Viewer

完成：

- read text file
- text viewer
- Markdown rendering
- Level 1 → Level 2 手势
- image viewer
- sibling image paging

验收：

用户可以：

```text
Session → Files → Text File
Session → Files → Image Viewer
```

并顺畅返回。

---

## Phase 4 — Codex Adapter

完成：

- detect Codex
- create session
- send message
- stream response
- normalized event
- cancel
- basic approval

验收：

从 iPhone 创建 Codex session，指派任务，收到实时反馈并完成一次交互。

---

## Phase 5 — Claude Adapter

完成：

- detect Claude Code
- create session
- send message
- stream response
- normalized event
- user question
- permission request
- cancel

验收与 Codex 相同。

---

## Phase 6 — Agent Session UI

完成：

- message
- markdown
- tool activity
- command
- approval
- question options
- error
- running/completed state
- input composer

验收：

Agent 的基础交互无需 Terminal UI 即可完成。

---

## Phase 7 — 核心空间手势体验打磨

重点调优：

```text
Session → File Browser → File Viewer
```

包括：

- gesture threshold
- interactive animation
- blur
- scale
- shadow
- z-index
- safe area
- orientation behavior
- scroll conflict
- edge gesture conflict

此阶段必须真机测试。

---

# 25. MVP 验收标准

MVP 完成时必须能够完整演示以下流程。

### Demo 1：连接

```text
Mac 启动
→ 添加项目
→ 点击 Pair Device
→ iPhone 扫码
→ iPhone 显示项目
```

### Demo 2：Codex

```text
iPhone 打开项目
→ New Session
→ Codex
→ 输入任务
→ Mac 启动 Codex
→ iPhone 实时显示 Agent 活动
→ Agent 完成
```

### Demo 3：Claude Code

同样流程跑通 Claude。

### Demo 4：文件浏览

```text
Session
→ 右滑
→ Session 缩到左侧并雾化
→ File Browser 显示在右侧
→ 展开目录
→ 长按文件
→ Copy Relative Path
```

### Demo 5：文本文件

```text
File Browser
→ 选择 Swift / TS / MD 文件
→ 继续进入下一层
→ File Browser 缩到左侧并雾化
→ Viewer 显示内容
```

### Demo 6：图片

```text
File Browser
→ 点击 PNG
→ 全屏图片
→ 左右滑查看同目录其他图片
→ 返回目录
```

### Demo 7：Approval

Agent 请求权限：

```text
Run xcodebuild ...
```

iPhone 显示 Approval Card。

用户：

```text
Approve
```

Mac Agent 继续执行。

---

# 26. MVP Non-goals

第一版明确不实现：

- Windows 客户端
- Android App
- Web App
- 完整 Terminal emulator
- 远程桌面
- SSH 客户端
- 本地代码编辑
- Git diff UI
- Git commit / stage / revert
- LSP
- Symbol navigation
- debugger
- build dashboard
- Agent subagent 可视化
- 多 Agent 协同
- Cloud Agent Runtime
- 项目云同步
- 源码云端索引
- 用户自己配置模型 API
- 插件系统
- MCP UI 管理器

除非实现过程中属于必要依赖，否则不要扩展范围。

---

# 27. 为未来预留但不实现

## Windows

```text
apps/windows/
```

未来复用：

- protocol
- agent-core
- Codex Adapter
- Claude Adapter
- Relay Client

Windows UI 只负责项目授权、配对与运行状态。

## Android

```text
apps/android/
```

与 iOS 保持相同信息架构。

## Web

```text
apps/web/
```

未来可能作为：

- session viewer
- management console
- browser Agent IDE

但 MVP 不开发。

---

# 28. 后续版本优先方向

MVP 跑通后，优先级建议如下。

## P1 — Context 引用

在 File Viewer 中：

```text
Send to Agent
Copy Agent Reference
```

例如：

```text
@apps/ios/PutWhere/Views/SettingsView.swift
```

进一步支持选中行：

```text
SettingsView.swift:132-184
```

## P1 — Changes / Git Diff

Session 里增加：

```text
Files Changed
```

用户直接 Review Agent 修改。

## P1 — Push Notification

场景：

- Agent asks question
- Approval required
- Task completed
- Task failed

## P2 — 搜索

File Browser 顶部增加：

```text
file name search
full text search
```

## P2 — Symbol Navigation

接 LSP。

## P2 — Rich Report Blocks

- Test Report
- Plan
- Todo
- Diff
- Table
- Diagnostics

## P3 — More Agents

新增 adapter：

```text
Gemini CLI
OpenCode
Aider
...
```

---

# 29. 推荐开发顺序总结

不要先同时做三端的大量 UI。

最稳妥顺序：

```text
1. Monorepo
2. Protocol
3. Mac ↔ Server ↔ iPhone connection
4. Pairing
5. Project list
6. File Browser
7. File Viewer / Image Viewer
8. Codex Adapter
9. Claude Adapter
10. Unified Agent Event
11. Session UI
12. Approval / Question
13. Gesture / visual polish
14. Recovery / reconnect
15. Security hardening
```

这里故意先实现 File Browser，再实现 Agent Adapter。

原因是：

- 可以先独立验证三端通信。
- 可以提前把最独特的 iOS 空间交互做出来。
- Agent Adapter 调试时已经有成熟的远程基础设施。
- 能避免所有复杂度同时出现。

---

# 30. 最终 MVP 定义

当用户在外面只有一台 iPhone 时，可以：

```text
打开 App
↓
连接自己的 Mac
↓
打开本地项目
↓
查看已有 Agent Session
↓
创建 Claude Code / Codex Session
↓
向 Agent 指派开发任务
↓
实时查看 Agent 反馈、工具调用、命令与询问
↓
批准 / 拒绝 Agent 操作
↓
右滑进入项目文件树
↓
浏览并展开目录
↓
复制文件名 / 相对路径给 Agent
↓
查看源码 / Markdown
↓
查看项目图片
↓
回到 Session 继续纠错和指派任务
```

如果这条链路体验顺畅，MVP 就已经成立。

后续所有功能——Git Diff、代码引用、Symbol Search、测试报告、Push、更多 Agent、Android/Windows/Web——都应该建立在这条主链路之上，而不是反过来扩大第一版范围。
