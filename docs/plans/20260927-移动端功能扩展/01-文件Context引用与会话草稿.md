# 01 文件 Context 引用与会话草稿

> 目标：让用户从项目文件直接生成稳定的 Agent 引用，并带回当前会话继续组织指令。
>
> 完成判据：用户可从文本、Markdown、图片 Viewer 复制文件引用或加入当前会话草稿，返回 Session 后补充内容并按现有消息链路发送；草稿、导航和异常状态均由自动化测试覆盖。

## 产品范围

- 引用格式统一为 `@<项目内相对路径>`，例如 `@apps/ios/AgentIDEiOS/App.swift`。
- Viewer 提供 `Copy Agent Reference` 和 `Send to Agent` 两个操作。
- `Copy Agent Reference` 只写入系统剪贴板，不改变导航。
- `Send to Agent` 把引用加入发起浏览的当前 Session 草稿，并返回 Session；不立即发送，避免误操作。
- 已有草稿非空时，以换行追加引用；同一引用重复加入时不自动去重，保留用户组织上下文的自由。
- 草稿按 Session 隔离。切换会话、进入文件浏览或临时离线不会丢失；消息成功提交后才清空。
- 从 Session List 直接进入文件浏览、没有当前 Session 时，只提供复制引用，不显示 `Send to Agent`。
- V1 只支持文件级引用。行号范围、代码选区和符号引用留给后续小版本。

## 技术设计

- 引用是普通消息文本，不新增 Relay、Mac 或 Agent Host 协议。
- 在 iOS 定义纯值类型的引用格式化器，输入项目内相对路径，输出规范引用文本；不接受绝对路径或空路径。
- 会话草稿由 `MobileConnection` 或独立可持久化状态对象按 `sessionId` 管理，Session View 的输入框绑定该状态，避免 View 重建时丢失。
- 工作区导航携带来源 Session，上层 Viewer 通过统一回调加入草稿并把活动层切回 Session。
- 草稿纳入现有有界恢复缓存。淘汰会话时同时淘汰对应草稿，不能形成无主状态。
- 为 Viewer 操作、Composer 和发送按钮提供稳定辅助功能标识，供 UI 自动化定位。

## 实现步骤

1. 增加引用格式化与草稿状态模型及单元测试。
2. 将 Session Composer 从局部 `@State` 迁移到按会话管理的草稿状态。
3. 在文本、Markdown 和图片 Viewer 接入复制与加入草稿操作。
4. 处理有 Session 与无 Session 两种文件浏览入口。
5. 把草稿加入恢复缓存的预算、裁剪和清理流程。
6. 扩展 comprehensive Scenario 的文件路径和发送记录，完成 UI 自动化。

## 自动化验收

- 相对路径、空格、Unicode、Markdown 特殊字符只作为路径文本处理，不产生绝对路径。
- 多会话草稿互不覆盖，View 重建、离线和导航往返不丢失。
- 发送失败或超时保留草稿；收到匹配的成功响应后清空。
- UI 自动化完成：Session → Files → 打开文件 → Send to Agent → 返回 Session → 补充文字 → 发送 → 进入 running → 取消。
- 无当前 Session 的 Viewer 只显示复制操作。

## 不在本轮

- 行号或选区引用。
- 自动读取文件内容并拼入消息。
- 附件上传、代码编辑、Symbol/LSP 引用。
- 修改 Agent 原生提示词格式。
