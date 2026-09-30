# Agent 会话推送通知

当 Mac 上的 Agent 会话需要用户处理或结束当前任务时，系统可通过 APNs 向与该 Mac 绑定的 iPhone 发送通知。通知只携带项目、会话和事件定位所需的最小元数据，不携带消息正文、命令、工具输入输出或报告内容；完整状态始终以 Agent Host 的持久化会话和事件为准。

通知控制面对象的字段与严格校验边界见 [三端通信与 Agent 契约](protocol.md#推送通知控制面对象)，设备身份、绑定和撤销规则见 [设备配对与 Relay 连接](device-pairing.md)。

## 通知类别与偏好

Agent Host 从已经持久化的统一事件生成四类通知意图：

| 类别 | 触发事件 | iPhone 偏好 |
| --- | --- | --- |
| `approval_waiting` | `approval.requested` | Waiting for me |
| `question_waiting` | `question.requested` | Waiting for me |
| `task_completed` | outcome 为 `completed` 的 `turn.completed` 或 `session.completed` | Task completion |
| `task_failed` | outcome 为 `failed` 的 `turn.completed` 或 `session.completed` | Task completion |

iPhone 的 Notifications 开关控制全部通知；Waiting for me 与 Task completion 可分别关闭。偏好随 APNs token 登记到 Relay，由 Relay 在发送前过滤。系统通知权限与应用内偏好相互独立：首次授权由用户在通知设置页发起；系统权限被拒绝后，应用提供跳转系统设置的入口。

## 投递与可靠性

1. Agent Host 先把规范化事件写入权威会话日志，再异步派生独立持久化 outbox；通知持久化不会延迟或拒绝 Agent 事件。事件追加路径的待处理状态只为每个会话合并保存 `fromSequence` 至 `throughSequence` 区间，不复制或积压事件对象；后台任务再从权威日志读取该区间，因此通知写入变慢时，事件主链的额外内存和排队状态仍按会话数有界。outbox 另存每个会话已经派生到的事件序列水位，并在加载会话存储、读取 outbox 和正常关闭时从权威日志补齐缺口。相同事件不会因补齐重复入队；outbox 最多保留 1000 项，超限时丢弃最旧项并显式报告溢出。
2. macOS 应用独立轮询 outbox。这条投递链不依赖 iPhone 当前在线，也不依赖会话事件 WebSocket 是否正在订阅。Mac 本地的 drain 边界用项目名补全最小通知意图，再以 Mac 设备身份提交 Relay；只有响应同时满足 HTTP 202 和 `accepted: true` 才确认对应 Host 游标，提交失败、其它状态码或未接受时停止当前批次并保留未确认项。
3. Relay 只接受已鉴权 Mac 提交的严格通知意图，并仅向仍与该 Mac 绑定、token 有效且偏好允许该类别的 iOS 设备扇出。每个目标的幂等键是 Mac、目标 iOS 设备、会话、事件序列和类别这一结构化元组的 SHA-256 摘要。
4. Relay 以 `processing` 和 `finalized` 状态持久化每个幂等键。`processing` 使用 60 秒租约；租约有效时并发或重试请求返回可重试错误，租约过期后可重新认领，避免发送进程中断后永久卡住。每次成功认领都会取得新的 `claimId`，定稿或释放时必须同时匹配幂等键与该 `claimId`；旧租约持有者迟到的完成或失败不能覆盖新持有者。Relay 同时根据 APNs HTTP 状态与 `reason` 分类拒绝：只有 `BadDeviceToken` 和 `Unregistered` 会删除 token 登记并定稿；`BadPayload`、`PayloadEmpty`、`PayloadTooLarge`、`BadCollapseId`、`BadExpirationDate`、`BadMessageId` 和 `BadPriority` 作为不可恢复的 payload 错误定稿。限流、服务故障、provider topic、配置或认证错误（包括 `InvalidPushType`），以及其它未知客户端拒绝都会释放认领并返回可重试错误，Mac 不确认 outbox 游标。定稿记录在 7 天保留窗口内抑制重复发送，超出窗口后在后续认领时清理；整项重试时，已经定稿的目标会被跳过。

Relay 的通知入口是独立的鉴权 HTTP 控制面，不是 Envelope 路由。现有业务 Envelope 仍只在绑定设备之间转发，Relay 不解释其 payload。

## iPhone 接收与导航

- App Delegate 在 SwiftUI 场景创建前安装通知中心 delegate，使由通知点击触发的冷启动也能接收并保留导航意图。
- 应用在获得或刷新 APNs device token、偏好变化以及完成配对后登记 token。token 与偏好更新由单一串行协调器合并到最新值；提交失败时保留未完成状态，应用再次进入前台后重试，避免并发请求以旧偏好覆盖新值。DEBUG 构建登记为 `development`，发布构建登记为 `production`。
- 应用每次进入前台都会重新读取系统通知授权状态；已授权或临时授权时重新向 APNs 登记远程通知。
- 应用位于前台时不展示系统横幅、声音或角标，但会消费通知意图并在项目页显示类别提示。
- 用户点击系统通知时，应用不使用缓存列表判断目标：每次都先向 Mac 请求权威项目列表，确认项目存在后再请求该项目的权威会话列表，最后决定是否导航。Mac 离线时保留导航意图并提示，连接恢复后从项目列表重新开始；目标项目不存在时停留在项目列表，会话不存在或等待类请求已不再是 `waiting_user` 时则打开该项目的会话列表并提示，不再尝试打开旧请求。
- 导航到会话后，界面仍按正常流程从 Agent Host 获取快照并恢复事件流。通知中的标题、类别和序列只用于提示与定位，不替代权威会话状态。

## Relay HTTP 接口

| 接口 | 鉴权与行为 |
| --- | --- |
| `PUT /notifications/token` | 仅 iOS 设备可调用；登记满足共享协议可变长度十六进制契约的当前 APNs device token、开发/生产环境和通知偏好。同一设备每个环境只保留一个 token。 |
| `DELETE /notifications/token` | 仅 iOS 设备可调用；删除该设备登记的全部 APNs token。设备撤销也会级联删除 token。 |
| `POST /notifications/intents` | 仅 Mac 设备可调用；校验通知意图、按当前绑定和偏好扇出。接受结果返回 HTTP 202；APNs 限流返回 429，临时不可用返回 503。 |

## APNs 部署配置

Relay 使用 APNs token-based authentication。实际发送需要同时配置 `APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_TOPIC` 与 `APNS_PRIVATE_KEY`；私钥环境变量中的 `\n` 会还原为换行。四项未完整配置时 Relay 仍可启动，但对已有目标 token 的通知投递按临时不可用处理，使 Mac 保留 outbox 项等待重试。

Relay 根据 token 登记的 `development` 或 `production` 环境分别连接 APNs sandbox 或 production 端点。单次 APNs 请求最多等待 10 秒；超时按临时故障处理并进入上述重试流程。APNs 请求使用 alert push、默认声音和即时优先级；相同幂等键映射到稳定的 collapse ID。
