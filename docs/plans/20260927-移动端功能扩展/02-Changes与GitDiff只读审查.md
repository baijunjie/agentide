# 02 Changes 与 Git Diff 只读审查

> 目标：让用户在 iPhone 上查看登记项目当前的 Git 变更和统一 diff，不执行任何 Git 写操作。
>
> 完成判据：Changes 列表和 Diff Viewer 能展示新增、修改、删除、重命名、未跟踪与二进制文件状态，并能从 Session 的文件变更事件进入相应内容；项目边界、大小限制和错误路径具备自动化覆盖。

## 产品范围

- Session 和 File Browser 提供 `Changes` 入口。
- Changes 按工作树路径列出状态，可区分 staged 与 unstaged，但不提供改变暂存区的操作。
- 选择文本文件后打开统一 diff，显示文件头、hunk、行号和新增/删除样式。
- 未跟踪文本文件以“全部新增”形式查看；二进制文件只显示状态和大小，不传输原始内容。
- Activity Feed 中的 `file.changed` 块可进入对应 Changes 或具体文件 diff。
- 非 Git 项目显示明确空状态，不当作请求失败。
- 刷新重新读取当前状态；Viewer 不承诺 diff 在刷新期间保持不变。

## 协议与服务边界

- 在共享协议中增加只读 Changes 摘要和 Diff 请求/响应，字段只包含项目内相对路径、变更类型、暂存区域、大小摘要和受限 diff 文本。
- Mac 继续作为唯一 Relay 连接持有者，把请求转交 Agent Host；Relay 只路由 payload。
- Agent Host 只在登记项目根目录执行只读 Git 查询，不接受客户端提供的仓库根路径、任意参数或 revision 表达式。
- Git 子进程只允许固定子命令和固定参数，不接受客户端参数拼接。调用时设置 `GIT_OPTIONAL_LOCKS=0`，使用 `--no-optional-locks`，并隔离 system/global Git 配置，避免状态查询刷新 index 或继承用户机器上的可执行配置。
- 状态和 diff 查询显式禁用 pager、color、fsmonitor、external diff、textconv 和交互提示；仓库本地 attributes/config 不能触发外部程序。调用设置执行期限、输出字节上限和并发上限。
- 返回路径再次经过项目相对路径校验；仓库外 rename 来源、submodule 内部内容和符号链接目标不展开。
- 超限 diff 返回可重试的明确错误，不静默截断成看似完整的 diff。

## 实现步骤

1. 定义跨语言 Changes/Diff DTO、JSON Schema 和 fixtures。
2. 在 Agent Host 建立只读 Git 服务，并以临时仓库测试状态解析和安全边界。
3. 增加本地 IPC、Mac Relay 转发和响应关联。
4. 扩展 iOS `MobileConnection` 的 Changes/Diff 请求、缓存、错误和重试状态。
5. 实现 Changes List、Diff Viewer 和 `file.changed` 深链。
6. 扩展 Scenario Runtime，覆盖混合状态、空仓库、非 Git、二进制、超限和请求失败。

## 自动化验收

- 临时 Git 仓库覆盖新增、修改、删除、rename、staged/unstaged、未跟踪和二进制状态。
- 路径遍历、任意 Git 参数、外部 diff、textconv、fsmonitor、超时和超限输出均被拒绝或转为明确错误。
- 测试仓库配置恶意 fsmonitor、diff driver 和 textconv 后，查询不能执行这些程序；查询前后 `.git` 内容摘要保持不变。
- iOS 状态测试验证响应类型、来源、项目与路径匹配，过期响应不能覆盖新刷新结果。
- UI 自动化完成：Session → Changes → 选择文件 → 查看 hunk → 返回 Session。
- `file.changed` 事件能定位当前变更；文件已恢复干净时进入 Changes 空状态而不是残留旧 diff。

## 不在本轮

- Stage、unstage、commit、discard、revert、checkout、merge 或 push。
- 历史提交浏览、分支管理和远端比较。
- 语法高亮、逐行评论和多用户 Review。
- 非 Git 版本控制系统。
