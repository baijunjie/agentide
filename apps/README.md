# 应用模块

## macOS 客户端

`apps/macos/` 是 SwiftUI macOS 应用入口，依赖本地 `AgentIDEProtocol` Swift Package。当前可启动界面提供配对和项目两个顶层入口。

对外入口：

- `AgentIDEMacApp`：macOS 可执行应用入口。

## iOS 客户端

`apps/ios/` 是 SwiftUI iOS 应用入口，依赖同一个 `AgentIDEProtocol` Swift Package。当前可启动界面提供未配对状态入口。

对外入口：

- `AgentIDEiOSApp`：iOS 可执行应用入口。

## Relay Server

`apps/server/` 是 Node.js HTTP Relay 边界。它校验 Envelope 与路由元数据，但不解释或持久化业务 payload。

对外接口：

- `createRelayServer()`：创建未监听端口的 Node HTTP server，供可执行入口和测试装配。
- `GET /health`：返回进程健康状态。
- `POST /relay`：接收最大 1 MiB 的 Envelope；合法请求返回 `202` 与消息 `id`，非法协议、非法 JSON 和超限请求分别返回错误状态。
- `pnpm --filter @agentide/server start`：默认监听 `127.0.0.1:8787`，可用 `PORT` 覆盖端口。

## Agent Host

`apps/agent-host/` 是 Mac 本地 Agent 执行进程的组合边界。文件访问、Relay 连接和具体 Agent 集成通过依赖接口注入，`AgentHost` 本身不拥有这些实现。

对外接口：

- `FileService`：按项目和相对路径列目录或读取文件字节。
- `RelayClient`：建立/断开 Relay 连接并发送 Envelope。
- `AgentHostDependencies`：汇总 Adapter、文件服务与 Relay 客户端。
- `AgentHost.start()` / `stop()`：控制 Relay 生命周期。
- `AgentHost.adapter()`：按 `claude` 或 `codex` 取得已配置 Adapter，缺失时抛错。
- `GET /health`：独立进程 bootstrap 的当前健康检查端点。
- `pnpm --filter @agentide/agent-host start`：默认监听 `127.0.0.1:8788`，可用 `AGENT_HOST_PORT` 覆盖端口。
