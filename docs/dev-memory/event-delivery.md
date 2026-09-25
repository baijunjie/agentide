# 确认式事件投递

- 显式 `session.subscribe` 必须开启新的投递 epoch：旧任务取消后仍要用 epoch/token 阻止其异步返回改写新流状态，且 ACK 只能推进到当前 epoch 已发送的最高 sequence。
