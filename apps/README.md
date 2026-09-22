# 应用模块

## macOS 客户端

`apps/macos/` 是 SwiftUI macOS 应用入口，依赖本地 `AgentIDEProtocol` Swift Package。应用登记并保存稳定的本机设备身份，连接 Relay，生成短期配对二维码，并展示或撤销已配对的 iPhone。设备配对与连接规则见 [设备配对与 Relay 连接](../docs/product/device-pairing.md)。

对外入口：

- `AgentIDEMacApp`：macOS 可执行应用入口。

## iOS 客户端

`apps/ios/` 是 SwiftUI iOS 应用入口，依赖同一个 `AgentIDEProtocol` Swift Package。应用扫描 Mac 生成的二维码完成绑定，连接 Relay，并根据 Presence 显示 Mac 在线状态。设备配对与连接规则见 [设备配对与 Relay 连接](../docs/product/device-pairing.md)。

对外入口：

- `AgentIDEiOSApp`：iOS 可执行应用入口。

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

`apps/agent-host/` 是 Mac 本地 Agent 执行进程的组合边界。文件访问、Relay 连接和具体 Agent 集成通过依赖接口注入，`AgentHost` 本身不拥有这些实现。当前独立进程入口只提供健康检查；Relay 客户端供后续组合入口复用。

对外接口：

- `FileService`：按项目和相对路径列目录或读取文件字节。
- `RelayClient`：建立/断开 Relay 连接并发送 Envelope。
- `RelayClientOptions`：配置 Relay URL、设备凭据、重连基准延迟和消息回调。
- `ReconnectingRelayClient`：带最多 100 条待发送队列和最长 30 秒指数退避的 WebSocket 客户端。
- `AgentHostDependencies`：汇总 Adapter、文件服务与 Relay 客户端。
- `AgentHost.start()` / `stop()`：控制 Relay 生命周期。
- `AgentHost.adapter()`：按 `claude` 或 `codex` 取得已配置 Adapter，缺失时抛错。
- `GET /health`：独立进程 bootstrap 的当前健康检查端点。
- `pnpm --filter @agentide/agent-host start`：默认监听 `127.0.0.1:8788`，可用 `AGENT_HOST_PORT` 覆盖端口。
