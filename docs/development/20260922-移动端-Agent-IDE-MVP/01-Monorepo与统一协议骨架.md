# 01 Monorepo 与统一协议骨架

> 目标: 建立可分别运行的 macOS、iOS、Server 骨架，并确立三端共用的协议、会话、Agent Adapter 和文件数据边界。
> 完成判据: Mac App、iOS App 和 Server 均可启动，共享协议可完成序列化与反序列化验证，基础 CI 可检查各工程。

## 技术设计

- [ ] 建立统一 monorepo，当前实现范围只包含 macOS、iOS 和 Server；Windows、Android 和 Web 仅保留未来边界。
- [ ] 建立 protocol、agent-core、agent-codex、agent-claude、shared-types 和 crypto 的共享能力边界。
- [ ] 以下 `Envelope<T>` 是三端通信的固定封装：`version` 固定为 `1`，`payload` 必填，只有目标设备、项目和会话上下文可选。

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

- [ ] request-response 使用 `id` 与 `replyTo` 关联；Agent streaming event 不使用 request-response，而是异步 push。

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

- [ ] 将消息类别限定为 `system.*`、`pairing.*`、`project.*`、`file.*`、`session.*`、`agent.*` 和 `interaction.*`。
- [ ] `AgentEvent` 联合类型和基础字段按以下契约落地，`sequence` 用于稳定重放。

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

- [ ] 三端必须保留下列已确定的 message、tool、approval 和 question payload，不使用 Agent 原生字段替代。

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

- [ ] `AgentAdapter` 必须保留 Agent 类型、方法入参、返回类型与异步事件边界。

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

- [ ] 统一 `Project`、`Session` 和 `FileEntry` 的字段与枚举字面量，其中 Session 的等待用户状态固定为 `waiting_user`。

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
- [ ] 在协议边界为未来 payload E2EE 预留 encryption version 与 ciphertext 表达，但不在本里程碑实现完整 E2EE。

## 实现方案

- [ ] macOS 保持 UI / Pairing / Project List 职责，并允许将 Agent Host 作为本地独立进程，承载 Agent Adapter、File Service 和 Relay Client。
- [ ] Agent 适配核心优先采用 TypeScript，以便对接 Claude Agent SDK 与 Codex 结构化协议。
- [ ] protocol 以 TypeScript 源定义与 JSON Schema 作为边界，iOS 使用 Schema 生成 Swift 类型或维护稳定 DTO 映射。
- [ ] 建立基础 CI，覆盖三个应用和共享包的编译、类型与协议校验。

## 开发要点

- 后续所有 iOS 交互只面向统一协议，不引入 Agent 原生事件特例。
- Server 数据模型不依赖可读的项目源码或 Agent payload 内容。
