# 01 Monorepo 与统一协议骨架

> 目标: 建立可分别运行的 macOS、iOS、Server 骨架，并确立三端共用的协议、会话、Agent Adapter 和文件数据边界。
> 完成判据: Mac App、iOS App 和 Server 均可启动，共享协议可完成序列化与反序列化验证，基础 CI 可检查各工程。

## 落地状态

- 最终建立了 pnpm TypeScript workspace、两个独立 SwiftUI Xcode 应用、Relay Server、本地 Agent Host 进程边界与 Swift 协议包。协议的 TypeScript 运行时校验、Draft 2020-12 JSON Schema 和 Swift DTO 共用同一组正反 fixtures。
- `ResponseEnvelope.payload` 按本文契约保持可选；时间戳收紧为 UTC `Z` 时区的 RFC 3339 子集，避免 JavaScript 与 Foundation 日期解析器的宽松规则不一致。显式 JSON `null` 在 response payload、tool input/output 和 error details 中可无损往返。
- 刻意保留的过渡层：`agent-codex` 和 `agent-claude` 当前只有包边界，分别由里程碑 05 和 06 替换；Agent Host 当前只有健康检查 bootstrap 与依赖接口，由里程碑 02、03、05、06 逐步接入 Relay、File Service 和 Adapter；macOS/iOS 当前为可编译的占位界面，由里程碑 02、03、07 接入真实状态。这些位置已在代码中标注 `TODO`。
- 交给后续里程碑的账：Relay 尚未实现配对、长连接与设备路由；File Service 只有接口；两个 Agent 包尚未连接原生 SDK/结构化协议；两个 Apple 应用尚未读取在线设备、项目、文件或会话数据。
- 已验证 `pnpm check`、`pnpm build`、全部 Node 测试、Swift Package 测试、macOS Xcode build、iOS Simulator generic build、Relay 回环请求与 Agent Host 独立进程启动。未手工操作 macOS/iOS 界面，未在真机启动 iOS，也未在 GitHub 远端实际触发 CI。

## 技术设计

- [x] 建立统一 monorepo，当前实现范围只包含 macOS、iOS 和 Server；Windows、Android 和 Web 仅保留未来边界。
- [x] 建立 protocol、agent-core、agent-codex、agent-claude、shared-types 和 crypto 的共享能力边界。
- [x] 以下 `Envelope<T>` 是三端通信的固定封装：`version` 固定为 `1`，`payload` 必填，只有目标设备、项目和会话上下文可选。

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

- [x] request-response 使用 `id` 与 `replyTo` 关联；Agent streaming event 不使用 request-response，而是异步 push。

  ```ts
  interface RequestEnvelope {
    id: string;
    type: string;
    payload: unknown;
  }

  interface ResponseEnvelope {
    replyTo: string;
    ok: boolean;
    payload?: unknown;
    error?: ProtocolError;
  }
  ```

- [x] 将消息类别限定为 `system.*`、`pairing.*`、`project.*`、`file.*`、`session.*`、`agent.*` 和 `interaction.*`。
- [x] `AgentEvent` 联合类型和基础字段按以下契约落地，`sequence` 用于稳定重放。

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

  interface BaseEvent {
    id: string;
    sessionId: string;
    sequence: number;
    timestamp: string;
    type: string;
  }
  ```

- [x] 三端必须保留下列已确定的 message、tool、approval 和 question payload，不使用 Agent 原生字段替代。

  ```ts
  interface MessageEvent extends BaseEvent {
    type: 'message';
    role: 'agent' | 'user' | 'system';
    content: string;
    format: 'plain' | 'markdown';
  }

  interface ToolStartedEvent extends BaseEvent {
    type: 'tool.started';
    toolName: string;
    title?: string;
    input?: unknown;
  }

  interface ApprovalRequestedEvent extends BaseEvent {
    type: 'approval.requested';
    interactionId: string;
    title: string;
    description?: string;
    command?: string;
    actions: ('approve_once' | 'approve_session' | 'reject')[];
  }

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

- [x] `AgentAdapter` 必须保留 Agent 类型、方法入参、返回类型与异步事件边界。

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

- [x] 统一 `Project`、`Session` 和 `FileEntry` 的字段与枚举字面量，其中 Session 的等待用户状态固定为 `waiting_user`。

  ```ts
  interface Project {
    id: string;
    name: string;
    rootPath: string;
    createdAt: string;
    enabledAgents: AgentType[];
  }

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
- [x] 在协议边界为未来 payload E2EE 预留 encryption version 与 ciphertext 表达，但不在本里程碑实现完整 E2EE。

## 实现方案

- [x] macOS 保持 UI / Pairing / Project List 职责，并允许将 Agent Host 作为本地独立进程，承载 Agent Adapter、File Service 和 Relay Client。
- [x] Agent 适配核心优先采用 TypeScript，以便对接 Claude Agent SDK 与 Codex 结构化协议。
- [x] protocol 以 TypeScript 源定义与 JSON Schema 作为边界，iOS 使用 Schema 生成 Swift 类型或维护稳定 DTO 映射。
- [x] 建立基础 CI，覆盖三个应用和共享包的编译、类型与协议校验。

## 开发要点

- 后续所有 iOS 交互只面向统一协议，不引入 Agent 原生事件特例。
- Server 数据模型不依赖可读的项目源码或 Agent payload 内容。
