# 04 Rich Report Blocks

> 目标：在 Activity Feed 中用统一结构展示测试结果、执行计划、待办和诊断信息，同时保留普通事件作为兼容回退。
>
> 完成判据：Claude 与 Codex 都能调用同一个第一方结构化报告工具产生四类统一事件，iOS 在不同内容规模和恢复场景下稳定渲染，未知报告类型不会破坏 Feed。

## 产品范围

- 第一版支持四类报告：`test_report`、`plan`、`todo`、`diagnostics`。
- Test Report 显示总数、通过、失败、跳过和失败条目摘要。
- Plan 显示有序步骤和状态；Todo 显示未开始、进行中、完成和阻塞状态。
- Diagnostics 显示严重级别、消息、项目内文件路径和可选行列；可打开对应文件。
- 报告块默认展示摘要，可展开查看受限详情；大量条目采用分段加载或折叠。
- 未识别的类型或版本显示通用 Report 卡片和安全摘要，不导致整个事件解码失败。

## 协议设计

- 在统一 `AgentEvent` 中增加版本化 `report` discriminator，公共字段包含 `reportId`、`kind`、`title`、`summary` 和结构化 payload。
- payload 使用封闭的已知 kind 联合类型，并保留未知 kind 的兼容解码路径；不能把任意 HTML、脚本或终端控制序列交给客户端渲染。
- 报告内文件定位只接受项目相对路径和正整数行列，不包含本机绝对路径。
- Agent Host 向两个 Adapter 暴露版本化的第一方 `agentide.report` 工具，参数直接使用统一 Report DTO。Claude 与 Codex 的工具调用都由 Adapter 校验并转换为 `report` 事件，这是首版四类报告的生产入口。
- Adapter 只在 `agentide.report` 工具调用或原生来源提供可靠结构时产生 report；不能可靠归一化的内容继续作为 message/tool 事件，不用文本猜测强行结构化。
- 报告事件遵循现有 sequence、持久化、快照、ACK、大小限制和重放规则。

| Report kind | Claude 生产路径 | Codex 生产路径 |
| --- | --- | --- |
| `test_report` | 调用 `agentide.report` 并提交测试摘要 DTO | 调用 `agentide.report` 并提交测试摘要 DTO |
| `plan` | 调用 `agentide.report` 并提交步骤 DTO | 调用 `agentide.report` 并提交步骤 DTO |
| `todo` | 调用 `agentide.report` 并提交待办 DTO | 调用 `agentide.report` 并提交待办 DTO |
| `diagnostics` | 调用 `agentide.report` 并提交诊断 DTO | 调用 `agentide.report` 并提交诊断 DTO |

工具能力在会话启动时显式提供给 Agent，并在工具描述中约束适用场景；Agent 没有调用工具时仍显示普通事件，不承诺把所有自然语言回答转换成报告。

## 实现步骤

1. 定义 TypeScript/Swift Report DTO、Schema、已知和未知 kind fixtures。
2. 更新 Agent Core、持久化与事件大小处理。
3. 实现 `agentide.report` 工具注册、Schema 校验和 Claude/Codex 调用映射；Adapter 测试确认四种 kind 都能从真实工具调用路径产生事件。
4. 在 iOS 实现四类卡片、折叠状态和文件定位。
5. 将折叠状态纳入有界 UI 恢复缓存，但不影响权威报告内容。
6. 扩展 Scenario Runtime，覆盖正常、未知、超大、重复投递和离线恢复。

## 自动化验收

- 跨语言 fixtures 覆盖每种 kind、未知 kind、字段缺失、显式 null 和版本前向兼容。
- Agent Host 重放报告时 sequence 稳定，快照裁剪不破坏待处理交互。
- iOS 状态测试覆盖重复事件、旧事件插入、展开状态恢复和文件定位失败。
- UI 自动化分别打开 Test Report、Plan、Todo 和 Diagnostics，并从诊断进入文件 Viewer 后返回原 Feed。
- 超过单事件上限时继续使用现有可恢复错误，不能阻塞后续事件。

## 不在本轮

- 任意 HTML/WebView 报告、图表脚本或插件渲染器。
- 把普通 Markdown 文本启发式转换成报告。
- 报告编辑、评论、云端分享和历史聚合 Dashboard。
