# Agent 会话执行与事件投递

Agent 会话由 Mac 上的 Agent Host 执行和持久化。iPhone 通过已配对设备之间的 Relay 消息列出和创建会话、发送后续消息、取消当前轮次并回应审批或问题，再以带确认的事件流取得执行结果。Relay 只负责路由 Envelope，不运行 Agent，也不保存会话记录。

统一事件字段和 Adapter 接口见 [三端通信与 Agent 契约](protocol.md)；设备鉴权、在线状态与 Relay 的短时离线缓冲见 [设备配对与 Relay 连接](device-pairing.md)。

## Mac 本地执行进程

macOS 应用随包携带 Agent Host 及其 Node.js 运行时、生产依赖和原生文件访问 helper。用户启动应用后无需另行启动本地服务；应用按需启动 Agent Host，等它通过启动握手报告实际监听端口后才发送项目或会话请求。

Agent Host 只监听 loopback 地址，并在每次启动时使用系统分配的随机端口和新的随机 Bearer 凭据。macOS 应用持有该端口与凭据，所有本地 IPC 请求都必须通过鉴权；启动配置在 Adapter 初始化前从 Agent Host 的进程环境中移除，不会传给 Claude 或 Codex 子进程。

Agent Host 异常退出后，macOS 应用以最长 30 秒的指数退避持续尝试重启；应用退出时会终止其监督的 Agent Host，而 Agent Host 也会监视父进程，避免 Mac 应用意外退出后成为孤儿进程。退出期间，Agent Host 在有限期限内关闭 HTTP 连接与 Agent Adapter；Codex 子进程组先收到终止信号，未退出时再强制结束，Claude 的活动 Query 则被主动关闭。会话元数据与已经写入的规范化事件仍以本地持久化数据为准。

## 会话与轮次

- 创建会话时必须指定已登记项目及该项目已启用的 Agent。Agent Host 先建立 Agent 原生会话并持久化统一 `Session`，再发送可选的初始任务。
- 会话可以包含多个顺序执行的轮次。同一会话的发送、取消和交互回应会串行执行；活动轮次结束后，会话进入 `idle`，仍可发送下一条消息。
- `turn.completed` 表示一个轮次以 `completed`、`failed` 或 `cancelled` 结束。`session.completed` 只表示整个会话真正终止，不能用来表示一次普通轮次结束。
- 发送消息的本地 IPC 只有在该轮次的 `status: running` 事件已经持久化后才返回成功。调用方因此可以在成功响应后立即按序列号读取到该轮次已开始的记录。
- 取消只中断当前活动轮次；没有活动轮次时是幂等操作。当前 Claude 与 Codex 集成都只接受文本输入，不接受附件。

## Claude 执行与归一化

Claude Adapter 通过 Claude Agent SDK 执行会话，声明支持审批、提问和原生会话恢复。新会话的统一会话 ID 同时作为 Claude 原生会话 ID；Agent Host 重启后，Adapter 会在下一轮发送前探测项目目录中的同名会话记录，已建立的会话按原生 ID 恢复，尚未真正启动的会话则以该 ID 启动首轮。

Claude 的流式文本、完整消息、工具、命令、审批、提问、结构化报告、错误和轮次结果都会转换为统一 `AgentEvent`。`AskUserQuestion` 中的每个问题分别产生 `question.requested`，允许提交选项、自由文本或两者；一次原生请求包含多个问题时，全部得到回应后才继续执行。

每一轮 Claude 查询都挂载进程内第一方 MCP 工具 `agentide.report`。该工具不触发用户审批，只接受协议规定的首版测试、计划、待办和诊断报告；参数校验成功时直接产生统一 `report` 事件，校验失败时返回工具错误。普通进度和说明仍走消息或工具事件，不会从自然语言推测为报告。

审批只暴露 SDK 当前请求允许的动作。会话级批准只应用于当前会话；SDK 禁止持久批准或没有提供相应权限建议时，不会暴露 `approve_session`。取消、完成或失败都会结束当前轮次并回到可继续发送消息的 `idle` 状态。

## Codex 执行与归一化

Codex Adapter 启动 `codex app-server` 子进程，并通过标准输入输出上的 JSONL RPC 初始化连接、创建或恢复 thread、启动或中断 turn。它声明支持审批和原生会话恢复，不声明支持提问。

Codex 的流式文本、完整消息、命令、文件变更、MCP 工具调用、结构化报告、审批、错误和轮次结果都会转换为统一 `AgentEvent`。审批只暴露原生请求实际允许的 `approve_once`、`approve_session` 和 `reject` 动作；回应会再映射回 Codex 的原生决定。

新建 Codex thread 时，Adapter 通过 `thread/start` 注入免审批的 `agentide.report` 动态工具；合法调用产生统一 `report` 事件，并向 Codex 返回成功结果，未知工具、会话已失效或报告参数非法时返回受控工具错误。当前 app-server 的 `thread/resume` 不能补充动态工具，因此通过原生 thread 恢复的 Codex 会话仍可继续普通事件流，但恢复后的轮次没有结构化报告工具；只有通过 `thread/start` 新建的 thread 获得该工具。

会话工作目录固定为登记项目的根目录。文件变更事件只允许项目内相对路径；项目外路径不会进入统一事件流。移动会表示为旧路径删除和新路径创建。

## 本地持久化与恢复

Agent Host 是会话元数据与规范化事件历史的本地权威来源：

- 会话元数据保存在本地 `sessions.json`；每个会话的事件使用独立 JSONL 日志追加保存，避免流式增量导致整份历史反复重写。
- Agent Host 按实际写入顺序为每个会话分配从 `0` 开始、严格递增且重启后稳定的 `sequence`。该持久化序列号是事件重放的唯一游标。
- 事件读取接受 `afterSequence`，只返回该序列号之后的事件。
- Agent Host 从同一个持久化视图构造 [`SessionSnapshot`](protocol.md#共享业务对象)。交互的解决状态与具体请求序列绑定：回应一个问题不会清除同轮的其他问题，之后重用相同 `interactionId` 的新请求也不会被旧回应误判为已解决。
- Agent Host 重启后，在下一次会话操作时用 `nativeSessionId` 恢复原生会话。
- 等待审批或问题时进程重启会使原生请求失效。Agent Host 在首次访问会话数据时记录可恢复错误和失败的 `turn.completed`，把会话恢复为 `idle`；旧交互回应会被明确拒绝，用户仍可开始新的轮次。

## iPhone 会话与交互界面

iPhone 的项目主路径是 Projects → Session List → Agent Session：

- Session List 的导航标题是完整项目名。列表按更新时间倒序显示当前项目的会话标题、首字母大写的 Agent 类型和统一状态。列表可下拉刷新；Mac 离线或项目没有启用任何 Agent 时不能新建会话。
- 新建会话只能选择项目已启用的 Claude 或 Codex，并且必须填写非空 initial task。任务为空时示例是 `For example, fix the failing test`，并说明要先输入任务，Create 才可用。创建成功后新会话进入列表首位，界面直接进入该会话。
- 会话层的导航标题保留会话标题。状态徽章在动态顶部，会随动态滚动；`waiting user` 显示 `Waiting for you`，不用枚举名做标题。只有 `idle` 状态可以发送非空文本；`running` 状态改为提供取消当前轮次的操作。会话当前不能发送时，输入区说明原因。会话列表和 Agent Session 都可以进入当前项目的文件浏览器。
- Composer 草稿按会话隔离。切换会话、进入文件浏览、导航往返或暂时离线都不会清空草稿；从文件 Viewer 加入 Agent 引用时，非空草稿以换行追加，重复引用不自动去重。文件引用格式和入口见 [项目登记与文件浏览](project-files.md#文本与图片查看)。
- 草稿只在对应消息收到匹配的成功响应、且等待期间内容未继续编辑时清空。离线、发送失败、响应超时，或发送后又修改草稿时，当前内容保留。

Agent Session 把两种 Agent 的统一事件呈现在同一个 Activity Feed 中：

- 用户、Agent 和系统消息以文本块显示，Markdown 消息按 Markdown 渲染；工具、命令、文件变更、结构化报告、错误、状态、轮次完成和会话完成各自显示为活动块。
- 测试报告显示通过、失败和跳过统计及失败条目；计划和待办显示完成进度与逐项状态；诊断报告按严重级别汇总，并允许从带项目相对路径的条目打开文件 Viewer。报告默认折叠，每次展开最多显示前 50 条详情并提示截断；详情超过 8 条时在卡片内滚动，截断说明仍在。未知类型或未来版本显示标题、摘要和不支持提示，不另加一行重复标题，也不解释其 payload。
- 相邻的 `text.delta` 会合并为同一个流式 Agent 文本块；随后到达的完整 Agent `message` 替换该流式内容。其他事件会结束当前文本流，避免不相邻的增量被错误拼接。
- Feed 以 `sequence` 排序。同一序列号的重投事件不重复显示；较晚收到的旧事件会插入正确位置并重新计算状态与交互卡片是否仍可响应。
- 未回答的问题和未决审批在动态滚动区外面有固定入口，分别为 `Answer question` 和 `Review approval`；点按后滚到对应卡片。
- 审批卡片只显示事件声明的动作；问题卡片的选项可以多选，提交所选 `optionIds`，并仅在 `allowFreeText` 为真时接受自由文本。还没选择、也没填写自由文本时，说明为什么不能提交。回应提交后卡片立即停用，同一 `sessionId + interactionId` 不会重复提交；收到成功响应、Agent 继续运行、轮次结束或服务端表示交互已不再等待时，卡片保持已回应状态。

会话列表、创建、发送、取消、快照、订阅和交互回应都必须收到与原请求 `replyTo`、响应类型、Mac 来源以及该请求适用的项目和会话相匹配的响应；不匹配的结果按失败处理。请求在 15 秒内没有响应时会结束等待并显示错误，Session List 与空 Activity Feed 提供显式重试入口。

iPhone 会保存有界的恢复缓存，用于在应用重启或暂时离线后恢复最近的项目和会话列表、活动事件、待回应交互状态、按会话隔离的 Composer 草稿、每个会话在会话、文件或变更、文本或 diff 这一空间层中的位置，以及每个会话最近 50 个报告的展开状态。草稿与报告展开状态随所属会话淘汰，并与其他恢复数据共享条目数量和 512 KiB 总预算；空间不足时先丢弃报告展开状态，再裁剪缓存中的报告及其他事件或会话。缓存优先保留当前会话与较新数据，超出边界的会话及其草稿、展开状态和历史不保证离线可见。对于仍在缓存内的会话，待回应交互属于必需恢复状态，不会因普通历史、草稿、报告展开状态或导航状态被淘汰而单独丢失。恢复缓存不是会话权威来源，连回 Mac 后会用 Agent Host 快照覆盖相应会话的缓存状态。

## iPhone 事件投递

远程会话操作使用 `session.list`、`session.create`、`session.sendMessage`、`session.cancel`、`session.getSnapshot`、`interaction.respond` 和 `session.subscribe` 请求。Mac 对涉及既有会话的操作校验会话确实属于请求中的项目，再转交本地 Agent Host。

规范化事件以 `agent.event` 推送。可靠投递遵循以下规则：

1. Mac 为每个“目标设备 + 会话”分别维护已确认游标，只发送游标之后的事件。
2. iPhone 成功解码事件后记录本次运行中已收到的最新序列号，并发送 `agent.event.ack`。在收到对应确认之前，Mac 会重复发送该事件，不会推进游标；超出 Mac 已发送范围的确认不会推进游标。
3. iPhone 打开会话或重新连上 Mac 后，先请求 `session.getSnapshot`，再以快照的 `latestSequence` 作为 `afterSequence` 订阅后续事件。这样快照创建前后发生的事件既不会遗漏，也不会因缓存重复显示。应用进入后台时保存恢复缓存并断开 Relay，回到前台后重连，并按同一流程恢复缓存仍保留的当前与近期未终止会话；已超出有界缓存的会话不会自动恢复订阅。Agent Host 的持久化状态是恢复依据，Relay 的短时缓冲和 iPhone 本地缓存都不是权威历史。
4. 一批事件以 `turn.completed` 或 `session.completed` 结束且已确认后，Mac 停止该批轮询。后续发送消息或重新订阅会启动新的投递批次。

单个 Relay Envelope 不能超过 1 MiB。若某个规范化事件本身超过该上限，Mac 会在相同 `sequence` 上改发可恢复的 `agent_event_too_large` 错误，使确认游标能够继续前进，不会让后续事件被永久阻塞。会话快照超限时，Mac 可删除最旧的 `recentEvents`，但不会静默删除 `pendingInteractions`；即使移除全部最近事件仍无法容纳必要状态时，快照请求会明确失败。
