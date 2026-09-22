# 设备配对与 Relay 连接

Mac 与 iPhone 各自持有稳定的设备标识和 Relay 签发的长期 token，通过主动建立的 WebSocket 连接交换在线状态和业务 Envelope。Relay 是设备身份、绑定关系和当前可达性的权威来源；它不执行 Agent、不读取项目文件，也不解释业务 payload。

## 设备身份与凭据

- Mac 首次连接一个 Relay 时登记本机设备标识与名称，Relay 签发设备 token。相同且仍有效的设备标识不能再次登记，避免用同一标识覆盖现有身份。
- iPhone 在配对成功时取得自己的设备 token。未被撤销的 iPhone 设备标识不能通过另一场配对被接管；被撤销后，同一 iPhone 可以重新配对并取得新 token。
- 生产 Relay 只保存 token 和配对 secret 的 SHA-256 摘要，不保存明文凭据。macOS 与 iOS 把设备 token 存入 Keychain，并以 Relay 地址的小写 scheme、host 和显式 port 作为账户键；设备标识和所选 Relay 地址保存在本机偏好设置中。
- HTTP 控制面使用设备标识头和 Bearer token 鉴权；WebSocket 使用连接参数中的设备标识和 Bearer token 鉴权。已撤销 token 不能建立新连接或调用受保护接口。

设备 token 只建立设备到 Relay 的身份，不提供业务 payload 的端到端加密。线协议中的加密载荷结构及当前能力边界见 [三端通信与 Agent 契约](protocol.md)。

## 配对

1. 已鉴权的 Mac 创建配对会话。Relay 返回版本、公开 Relay 地址、配对 ID、随机 secret 和到期时间；Mac 把该载荷编码为二维码，同时显示倒计时和短码提示。
2. iPhone 扫描二维码，只接受版本 `1` 且 Relay 地址为 HTTPS 的载荷；`localhost` 和 `127.0.0.1` 可在本地开发时使用 HTTP。
3. iPhone 提交配对 ID、secret、自身设备标识和名称。配对 secret 默认五分钟过期，只能成功使用一次。
4. Relay 原子地认领配对会话、登记 iPhone 并建立 Mac—iPhone 绑定，然后向 iPhone 签发设备 token。

过期、已使用、secret 不匹配或试图覆盖未撤销 iPhone 身份的认领统一失败，不产生部分绑定。

## 连接、在线状态与路由

设备使用 HTTPS 对应的 WSS 地址主动连接 Relay；Mac 不向公网暴露入站项目或 Agent Runtime 服务。连接建立后，Relay 向该设备发送所有已绑定对端的 Presence 快照，并在对端上线或最后一条连接断开时发送 `system.presence` Envelope。一个设备可以同时有多条连接，只要其中一条仍打开就保持在线。

Relay 每 15 秒发送 WebSocket ping；连续一个心跳周期未收到 pong 的连接会被终止。客户端在非主动断开后自动重连。iOS 根据 Mac 的 Presence 显示 `Mac Online` 或 `Mac Offline`；macOS 显示已绑定 iPhone 的当前在线状态。

通过 WebSocket 路由的业务消息必须是带 `payload` 的合法 Envelope，`sourceDeviceId` 必须等于当前鉴权设备，且必须指定已与来源设备绑定的 `targetDeviceId`。不满足这些条件的消息不会转发；需要发送空载荷时应显式使用 `payload: null`。Relay 不根据 payload 内容作路由决策。

目标在线时，Relay 把消息发送给该设备的所有活动连接。目标离线时，每个目标设备最多在进程内保留最近 100 条消息，每条最多保留 30 秒；目标重连后按保留顺序发送，超时消息和 Relay 进程重启前的缓冲不会恢复。

## 撤销与重新配对

Mac 可以撤销已绑定的 iPhone。撤销会使目标 token 失效、删除相关绑定并以专用关闭码断开目标的现有 WebSocket；iOS 收到该关闭码后删除 Keychain 中的 token 并回到未配对状态。之后可使用新的二维码重新绑定，同一 iPhone 设备标识会取得新 token。

已鉴权设备也可以撤销自身；iPhone 不能撤销已绑定的 Mac。

## Relay 部署约束

生产入口要求 `DATABASE_URL` 和 `PUBLIC_URL`。设备、配对会话与绑定关系持久化在 PostgreSQL；Presence 和短时消息缓冲只存在于当前 Relay 进程。

`PUBLIC_URL` 是写入二维码的客户端可达地址，生产必须使用 HTTPS；只有显式设置 `ALLOW_INSECURE_HTTP=1` 才允许明文 HTTP。Relay 进程默认只监听 `127.0.0.1:8787`，公开部署需要在前置代理终止 TLS 并转发 HTTP 与 WebSocket upgrade。
