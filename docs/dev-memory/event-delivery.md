# 异步消息任务隔离

- Relay 接收循环内，可替换或可取消的长任务不能原地 `await`；另起任务后仍须把取消视为 best-effort，并由服务端 token / generation 与客户端 pending 请求及当前操作标识共同拒绝迟到结果。
- Host 的可取消任务若会分步启动原生 helper，`AbortSignal` 既要在步骤间检查，也要主动终止当前子进程；只做一层会让取消卡在另一层。
- 显式 `session.subscribe` 必须开启新的投递 epoch：旧任务取消后仍要用 epoch/token 阻止其异步返回改写新流状态，且 ACK 只能推进到当前 epoch 已发送的最高 sequence。
