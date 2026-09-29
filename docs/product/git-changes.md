# Git 变更与统一 Diff 审查

iPhone 可以只读审查 Mac 上已登记项目的当前 Git 工作树。Mac 应用仍是唯一的 Relay 连接持有者：它把 Changes 与 Diff 请求转交本地 Agent Host，Relay 只路由 Envelope，不读取仓库、变更列表或 diff 内容。

## Changes 列表

- 用户可以从 Session List、文件浏览器或具体 Agent Session 打开 Changes。有变更的区域依次按 `Staged`、`Unstaged` 分组，并显示新增、修改、删除、重命名和未跟踪状态；重命名项同时显示原路径。
- 同一路径可以分别出现 staged 与 unstaged 记录。记录还可包含变更前后大小；二进制项明确标记为 Binary。
- 下拉刷新或工具栏刷新会重新读取当前工作树。刷新结果只代表查询时刻的状态，不是仓库快照。
- 不是 Git 仓库时标题是 `Not a Git Repository`；干净工作区的标题是 `No Changes`。两者都不是请求失败。

从具体 Agent Session 进入时，Changes 与 Diff 使用同一套空间层；返回规则见 [项目登记与文件浏览](project-files.md#文件浏览交互)。逐层返回时先从 Diff 回到 Changes，再回到会话。该层级与当前 Diff 选择会随最近会话的工作区状态一起恢复。

Activity Feed 中的 `file.changed` 卡片标明可以查看 diff，并可以直接打开对应路径：客户端先刷新 Changes；当前仍存在该路径的变更时进入其 Diff，文件已经恢复干净时停留在最新的 Changes 状态，不保留事件产生时的旧内容。

## Diff Viewer

文本变更以统一 diff 显示。文件头和 hunk 原样保留；hunk 内同时显示旧文件与新文件行号，新增行和删除行使用不同颜色。着色行从顶部对齐。不带行号的 git 文件头和 `@@` 行会换行，不横向滚动也能读完其中的路径；带行号的正文仍横向滚动，整份 diff 可以纵向滚动。当前路径只出现在导航标题，不在内容里再写一遍。

未跟踪文本文件以整文件新增的统一 diff 展示。二进制文件不传输原始内容或文本 diff，Viewer 只显示 Binary 状态和可用的变更前后大小。Diff 是一次只读查询的结果；文件继续变化时不保证已打开的内容同步更新。

## 请求与一致性

iPhone 使用 `project.listChanges` 请求当前变更，使用项目内相对路径和 `staged` / `unstaged` 区域发送 `project.readDiff`。Mac 分别以同名 `.response` 消息返回 [Git Changes/Diff 共享对象](protocol.md#共享业务对象)。

客户端只接受来自当前 Mac、`replyTo` 匹配原请求、项目一致的响应；Diff 响应还必须与请求的路径和区域一致。每次 Changes 刷新都会进入新的请求代次，较旧的 Changes 或 Diff 响应不能覆盖新结果。离线、发送失败、超时、无效响应和 Mac 返回的查询错误都结束当前加载状态。打不开变更列表或 diff 时，失败说明和重试放在一起。一般错误的按钮是 Retry。diff 超限（`DIFF_TOO_LARGE`）的按钮是 `Request this diff again`；说明写明再试一次发出的是同一个请求，diff 仍超限。

## 只读与仓库边界

- Agent Host 只接受已登记项目 ID、项目内相对路径和 staged/unstaged 区域；仓库根目录、Git 子命令、参数和 revision 不能由远端调用方指定。
- 状态与 diff 使用固定的只读 Git 命令。查询禁用 optional locks、pager、颜色、交互提示、fsmonitor、external diff 和 textconv，并隔离 system/global Git 配置，不执行仓库配置的外部辅助程序，也不刷新 Git index。
- 启动 Git 前，native runner 从文件系统根目录描述符开始逐段以 `O_NOFOLLOW` 打开登记根路径，切换到最终目录描述符后才执行 Git。登记后把根路径或任一祖先替换为符号链接不能把查询导向其它仓库。
- Git 返回的路径会再次通过项目内相对路径校验。二进制文件、符号链接目标和 submodule 内部内容不会作为文本 diff 展开。
- Git 子进程与 Changes/Diff 使用的文件 metadata/read helper 共用执行门：同时最多运行两个操作，等待队列有界，满载时返回可重试的 `git_busy`。每个操作最长运行 10 秒；Git stdout 与 stderr 合计、未跟踪文件读取和最终 diff 分别受 700 KiB 上限约束。超时、超限和无效路径均返回明确错误；超限 diff 不会以截断文本冒充完整结果。

该流程没有 stage、unstage、commit、discard、checkout、merge、push、历史提交浏览或分支管理能力。
