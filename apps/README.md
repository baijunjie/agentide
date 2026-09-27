# 应用模块

## macOS 客户端

`apps/macos/` 是 SwiftUI macOS 应用入口，依赖本地 `AgentIDEProtocol` Swift Package。应用登记并保存稳定的本机设备身份，生成短期配对二维码，管理已配对的 iPhone 和 Agent Host 中的本机项目。它持有 Mac 唯一的 Relay 连接，通过该连接响应项目、只读 Git 审查与会话请求，并按目标设备和会话游标重传未确认的 Agent 事件；随包的 Agent Host companion 由应用启动、鉴权、监督和清理。设备连接规则见 [设备配对与 Relay 连接](../docs/product/device-pairing.md)，项目行为见 [项目登记与文件浏览](../docs/product/project-files.md)，Git 审查行为见 [Git 变更与统一 Diff 审查](../docs/product/git-changes.md)，本地执行进程与会话行为见 [Agent 会话执行与事件投递](../docs/product/agent-sessions.md)。

对外入口：

- `AgentIDEMacApp`：macOS 可执行应用入口。

## iOS 客户端

`apps/ios/` 是 SwiftUI iOS 应用入口，依赖同一个 `AgentIDEProtocol` Swift Package。应用扫描 Mac 生成的二维码完成绑定，连接 Relay，根据 Presence 显示 Mac 在线状态，并提供 Projects → Session List → Agent Session 主流程；会话界面负责创建 Claude/Codex 会话、呈现统一 Activity Feed、发送与取消轮次、回应审批和问题，并从会话工作流进入项目文件浏览或 Git Changes/Diff 审查。它还解码、排序并确认 Agent 事件，在连接恢复时续订未结束的事件流。设备连接规则见 [设备配对与 Relay 连接](../docs/product/device-pairing.md)，文件浏览行为见 [项目登记与文件浏览](../docs/product/project-files.md)，Git 审查行为见 [Git 变更与统一 Diff 审查](../docs/product/git-changes.md)，会话行为见 [Agent 会话执行与事件投递](../docs/product/agent-sessions.md)。

对外入口：

- `AgentIDEiOSApp`：iOS 可执行应用入口。
- `pnpm test:ios`：在可用的 iPhone Simulator 上运行 iOS 单元、状态与 UI 自动化测试；可用 `AGENTIDE_IOS_SIMULATOR_ID` 指定模拟器，否则自动选择一个可用设备。

### iOS Simulator 场景运行时

DEBUG 构建可用启动参数 `-mobileScenario <场景名>` 或 `--mobile-scenario=<场景名>` 启用确定性的进程内 Mac 端替身。场景模式不建立 Relay 连接，也不读取或写入设备身份和恢复缓存；请求与事件仍编码为正式的 Envelope JSON，并进入 `MobileConnection` 原有的解码、请求关联和状态归并路径。因此模拟测试验证的是正式客户端状态流，而不是另一套仅供测试使用的界面逻辑。

| 场景名 | 行为 |
| --- | --- |
| `comprehensive` | 提供项目、会话、会话创建、消息发送与取消、审批、提问、文本和图片文件浏览的完整闭环。 |
| `offline` | 以已配对但 Mac 离线的状态启动，不提供远端项目。 |
| `request-failure` | 为请求返回带 `replyTo` 的确定性失败响应。 |
| `timeout` | 不返回请求响应，用于验证正式超时处理。 |
| `invalid-response` | 从非预期 Mac 来源返回响应，用于验证来源校验。 |
| `clean` | 返回 Git 仓库的 clean 工作树。 |
| `not-git` | 返回非 Git 项目的 Changes 空状态。 |
| `binary` | 返回不携带文本 diff 的二进制变更。 |
| `too-large` | 为 Diff 请求返回确定性的超限错误。 |

场景实现位于 `apps/ios/AgentIDEiOS/MobileScenario.swift`。自动化测试分别直接验证场景 Envelope 契约、场景经过 `MobileConnection` 后的状态，以及通过真实 SwiftUI 界面完成会话创建、发送与取消、审批、问题提交、文件浏览和 Changes/Diff 审查。

## Relay Server

`apps/server/` 是 Node.js HTTP/WebSocket Relay 边界。生产入口使用 PostgreSQL 持久化设备控制面；业务 Envelope 只在已绑定设备之间转发，并仅为短暂断线保存在进程内存中。它校验 Envelope 与路由元数据，但不解释或持久化业务 payload。完整行为见 [设备配对与 Relay 连接](../docs/product/device-pairing.md)。

对外接口：

- `ControlPlaneStore`：设备、配对会话和设备绑定的持久化接口。
- `PostgresControlPlaneStore`：生产控制面的 PostgreSQL 实现；`initialize()` 建立所需表结构。
- `InMemoryControlPlaneStore`：测试和嵌入式装配使用的进程内实现。
- `ControlPlane`：登记、鉴权、创建配对会话和认领配对的领域边界。
- `DeviceRelay`：鉴权 WebSocket、Presence、心跳、绑定内路由和短时缓冲边界。
- `RelayServerOptions`、`createRelayServer()`：注入控制面存储、公开 URL 和时钟，创建未监听端口的 Node HTTP server。
- `GET /health`：返回进程健康状态。
- `POST /devices/register`：登记新的 Mac 设备身份并签发长期 token。
- `POST /pairing/sessions`：由已鉴权 Mac 创建短期单次配对会话和二维码载荷。
- `POST /pairing/claim`：由 iPhone 使用配对载荷建立绑定并取得设备 token。
- `GET /devices`：列出当前设备已绑定的对端及在线状态。
- `DELETE /devices/:deviceId`：撤销自身，或由 Mac 撤销已绑定的 iPhone。
- `GET /connect?deviceId=...`（WebSocket upgrade）：建立鉴权设备连接，交换 Presence 和已绑定设备间的 Envelope。
- `POST /relay`：只校验最大 1 MiB 的 Envelope 并返回接收结果，不参与 WebSocket 实时路由。
- `pnpm --filter @agentide/server start`：要求 `DATABASE_URL` 与 `PUBLIC_URL`，默认监听 `127.0.0.1:8787`，可用 `PORT` 覆盖端口；生产 `PUBLIC_URL` 必须使用 HTTPS，仅 `ALLOW_INSECURE_HTTP=1` 时允许明文公开 URL。

## Agent Host

`apps/agent-host/` 是随 macOS 应用分发的本地 Agent 执行进程边界。它持久化 Mac 明确登记的项目、统一会话和规范化事件，通过 loopback HTTP IPC 提供项目管理、会话管理、受根目录约束的文件访问和固定参数的只读 Git 查询；本地组合默认装配 Claude 与 Codex Adapter，`AgentHost` 也可通过依赖注入组合文件访问、Relay 连接和具体 Agent 集成。macOS 应用使用每次启动新生成的凭据鉴权全部 IPC，并监督进程生命周期。项目与文件访问规则见 [项目登记与文件浏览](../docs/product/project-files.md)，Git 审查规则见 [Git 变更与统一 Diff 审查](../docs/product/git-changes.md)，进程生命周期、会话执行与恢复规则见 [Agent 会话执行与事件投递](../docs/product/agent-sessions.md)。

对外接口：

- `FileService`：定义 `list()`、`readText()`、`readBinary()` 和 `listSiblingImages()` 文件访问边界。
- `LocalFileService`：`FileService` 的本地文件系统实现，提供目录列举、文本读取、二进制读取和同目录图片列举。
- `LocalGitService`：按已登记项目执行固定的只读 Git 状态与统一 diff 查询。
- `GitServiceError`、`GitArea`：只读 Git 查询的稳定错误与 staged/unstaged 区域边界。
- `ProjectStore`：持久化项目登记，提供 `list()`、`get()`、`add()`、`rename()` 和 `remove()`；随包可用的 Claude 始终启用，Codex 则按 `PATH` 中的可执行文件检测。
- `SessionStore`：持久化统一会话元数据和按会话分隔的 JSONL 事件日志，并按稳定序列号查询事件。
- `SessionManager`、`CreateManagedSession`：通过统一边界创建或恢复 Claude/Codex 会话，串行化会话操作，并把 Adapter 事件写入 `SessionStore`。
- `createAgentHostServer()`：创建承载项目、文件和会话 IPC 的未监听端口 Node HTTP server；配置启动凭据后，所有端点都要求完全匹配的 Bearer token。
- `RelayClient`：建立/断开 Relay 连接并发送 Envelope。
- `RelayClientOptions`：配置 Relay URL、设备凭据、重连基准延迟和消息回调。
- `ReconnectingRelayClient`：带最多 100 条待发送队列和最长 30 秒指数退避的 WebSocket 客户端。
- `AgentHostDependencies`：汇总 Adapter、文件服务与 Relay 客户端。
- `AgentHost.start()` / `stop()`：控制 Relay 生命周期。
- `AgentHost.adapter()`：按 `claude` 或 `codex` 取得已配置 Adapter，缺失时抛错。
- `GET /health`：返回 Agent Host 进程健康状态。
- `GET /projects`、`POST /projects`：列出项目登记，或登记一个本机目录。
- `PATCH /projects/:projectId`、`DELETE /projects/:projectId`：修改项目显示名，或删除项目登记。
- `GET /sessions`、`POST /sessions`：按可选项目筛选会话，或为已登记项目创建会话并发送可选初始任务。
- `GET /sessions/:sessionId`：取得一个统一会话。
- `GET /sessions/:sessionId/events`：按可选 `afterSequence` 读取持久化事件。
- `POST /sessions/:sessionId/messages`、`POST /sessions/:sessionId/cancel`：发送后续文本消息，或取消当前轮次。
- `POST /sessions/:sessionId/interactions`：回应待处理审批或问题；审批使用 `approve_once`、`approve_session` 或 `reject`，问题可提交选项 ID、自由文本或两者。
- `POST /projects/:projectId/files/list`：列出项目根目录或其子目录。
- `POST /projects/:projectId/files/read-text`、`POST /projects/:projectId/files/read-binary`：读取项目内文本，或以 Base64 返回二进制文件。
- `POST /projects/:projectId/files/list-images`：列出指定文件同目录的图片。
- `POST /projects/:projectId/changes`：列出项目当前 staged 与 unstaged 变更；非 Git 项目返回 `isGitRepository: false`。
- `POST /projects/:projectId/diff`：按项目内相对路径和 staged/unstaged 区域读取受限统一 diff。
- `pnpm --filter @agentide/agent-host start`：直接启动 companion 入口；必须提供至少 32 字符的 `AGENT_HOST_TOKEN` 和监督进程的 `AGENT_HOST_PARENT_PID`，默认在 `127.0.0.1` 上使用系统分配的随机端口，也可用 `AGENT_HOST_PORT` 指定端口。项目登记与会话数据默认写入 `~/Library/Application Support/AgentIDE/`，可用 `AGENTIDE_DATA_DIR` 覆盖数据目录。

macOS 随包构建：

- `scripts/package-macos-companion.sh` 把独立 Node.js 运行时、Agent Host 生产依赖、Claude 可执行文件和按目标架构构建的 native helper 组装到应用资源中的 `AgentHost/`。构建会检查其中每个 Mach-O 可执行文件覆盖全部目标架构，缺失任一架构即失败。
- 启用代码签名时，打包脚本只为 Node.js 与 Claude 可执行文件附加运行 JavaScript 所需的最小 runtime entitlement，其他 Mach-O 使用普通 hardened runtime 签名；签名完成后还会直接执行随包 Node.js 探针，不能运行则构建失败。

文件访问实现边界：

- `LocalFileService` 负责校验项目 ID 与相对路径、标注文件类型，并调用随包构建的 `native/file-access.c` helper；helper 才执行目录列举和文件读取。
- helper 从文件系统根目录描述符开始，逐段打开登记根路径和项目内相对路径且不跟随符号链接，避免根路径祖先或项目内路径在检查与实际打开之间被并发替换。默认忽略路径在 TypeScript 授权层和 helper 中都会拒绝；修改忽略集合时必须保持两处一致。
- helper 将单次文件读取限制为最多 700 KiB 原始字节，并在读取过程中再次守住该上限，以免文件在打开后增长导致响应越界。
- `pnpm --filter @agentide/agent-host build` 除编译 TypeScript 外，还要求系统提供 `cc`，并把 helper 构建为 `dist/native/file-access`；运行 Agent Host 前必须保留该相对位置。

Git 审查实现边界：

- `LocalGitService` 从 `ProjectStore` 解析项目根目录，只接受项目内相对路径和 staged/unstaged 区域，不暴露任意 Git 参数或 revision。
- native helper 从文件系统根目录描述符开始逐段以 `O_NOFOLLOW` 打开登记根路径，`fchdir` 到最终描述符后才执行 `/usr/bin/git`；根路径或祖先被并发替换为符号链接时查询失败，不会切换到链接目标。
- 查询固定使用只读 `status`、`diff` 和对象 metadata 命令，禁用 optional locks、pager、颜色、交互提示、fsmonitor、external diff 和 textconv，并隔离 system/global 配置。
- Git 子进程与 Changes/Diff 使用的文件 metadata/read helper 共用执行门，同时最多运行两个操作且等待队列有界；队列满载返回 `git_busy`。每个操作最长运行 10 秒，Git stdout 与 stderr 合计、文件读取和最终 diff 分别受 700 KiB 上限约束。查询进程按独立进程组终止，繁忙、超时、超限、无效路径和一般查询失败使用 `GitServiceError` 区分。
