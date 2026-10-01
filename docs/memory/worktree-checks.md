# Worktree 检查环境

- 新建的 worktree 不带 `node_modules`；运行 `pnpm check` 等质量检查前先执行 `pnpm install --frozen-lockfile`，避免把依赖缺失误判为本次改动引入的错误。
