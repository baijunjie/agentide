# 05 Push Notification

> 目标：当 Agent 等待用户、完成或失败时，即使 iOS 不在前台也能向已配对设备发送最小化通知，并在点击后恢复到正确会话。
>
> 完成判据：通知意图、设备 token 生命周期、绑定校验、去重、深链和错误处理通过自动化测试；开发与生产 APNs 环境在真机完成集中验收。

## 产品范围

- 支持四类通知：审批等待、问题等待、任务完成、任务失败。
- 通知默认只显示项目名、会话标题和事件类别，不包含源码、命令输出、问题正文或 Agent 完整回答。
- 用户可全局关闭通知，并可分别关闭完成类或等待操作类通知。
- 前台收到通知意图时只更新应用内状态，不重复弹出系统通知。
- 点击通知打开对应 Project 和 Session；目标不存在、已淘汰或已解决时进入项目会话列表并给出说明。
- 相同 Session、事件 sequence 和通知类别只投递一次。

## 架构边界

- iOS 通过 Relay 的鉴权控制面登记和撤销 APNs token；token 与当前 iOS 设备身份绑定，设备撤销或重新配对时同步失效。
- Agent Host 在持久化审批、问题和轮次终止事件时，同时写入持久化 notification outbox。Mac 通过独立于 iPhone `sessionStreams` 的本地鉴权 IPC 按游标排空 outbox；因此 iPhone Presence 离线、实时 stream 已取消时，Agent 后续事件仍能触发通知。
- Mac 把 outbox 项转换为最小化 notification intent，包含项目/会话标识、事件 sequence、类别和非敏感展示元数据。Relay 接受来自已鉴权 Mac 的专用通知控制面请求，根据现有绑定关系向所有已启用对应类别的 iOS 设备扇出；Mac 不接触 APNs token。
- 通知 intent 不使用普通业务 Envelope，Relay 也不解析 `agent.event` payload。普通 Relay WebSocket 继续保持业务 payload 不透明；通知控制面只理解独立、受限的 intent Schema。
- APNs 凭据只存在服务端部署环境，不进入 Mac、iOS 包或数据库明文字段。
- 通知不是事件投递权威通道。App 打开后仍通过 snapshot + subscribe 取得真实状态，通知丢失不影响会话正确性。
- Mac 只在 Relay 接受 intent 后推进本地 outbox 游标；临时失败按幂等键重试。outbox 采用有界保留和明确超限错误，不能阻塞 Agent 事件日志。

## 实现步骤

1. 定义通知类别、意图、偏好和 token 控制面契约。
2. 在 Agent Host 实现通知 outbox、独立游标 IPC 和保留上限；在 Mac 实现与 Presence 无关的持续排空任务。
3. 在 Relay 实现专用 intent 控制面、token 持久化、绑定扇出、偏好、撤销、幂等记录和可替换 APNs Provider。
4. 在 iOS 接入授权、token 更新、偏好设置、前台处理和深链恢复。
5. 为 Simulator 提供本地通知/深链注入入口，不伪装真实 APNs 成功。
6. 配置开发与生产 APNs 环境并执行真机验收。

## 自动化验收

- Mock APNs Provider 覆盖成功、临时失败、无效 token、限流、重试和永久撤销。
- 未绑定设备、已撤销设备、错误来源和重复幂等键不能产生投递。
- 通知意图序列化测试确认不包含消息正文、命令、文件内容和绝对路径。
- 集成测试先让 iOS Presence 离线并确认实时 `sessionStreams` 已取消，再写入 Agent 等待/完成事件；Mac 仍须从 outbox 向专用控制面提交，Mock APNs 收到一次投递。
- 多个绑定 iOS 设备按各自类别偏好扇出；未启用类别的设备不接收，解绑后不再属于目标集合。
- iOS 状态与 UI 测试覆盖授权状态、偏好切换、前台抑制、深链成功和目标失效降级。
- Scenario Runtime 注入四类通知响应，验证点击后仍以 snapshot 状态为准。

## 真机验收

- 首次授权、拒绝后设置引导和系统设置中重新开启。
- 开发/生产 APNs token、App 重装、设备重启和 token 轮换。
- 前台、后台、被系统结束三种状态的展示与点击恢复。
- 网络不可用、延迟和重复投递下的去重。
- 设备撤销或重新配对后旧 token 不再收到通知。

## 不在本轮

- 通知中直接批准、回答问题或执行其他写操作。
- 静默后台长时间运行、Live Activity 和通知服务扩展中的富媒体下载。
- 把 APNs 作为会话事件可靠投递或恢复通道。
