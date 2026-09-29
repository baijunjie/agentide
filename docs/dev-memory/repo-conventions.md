# 仓库约定：指令、agent 配置与检查环境

- 项目指令只规范 agent 行为，全部写在 `AGENTS.md`；`CLAUDE.md` 是指向它的符号链接，两个宿主读同一份，改指令只动 `AGENTS.md`。构建、测试、质量检查等工程信息写 `README.md`，不要写进 `AGENTS.md`。
- skill 与子代理定义在仓库里有两套镜像：Codex 读 `.agents/skills/`、`.codex/agents/`，Claude Code 读 `.claude/skills/`、`.claude/agents/`。正文必须逐字一致，只有宿主字段（model / effort / sandbox 等）与文件格式可以不同；动了一套必须同步另一套。
- 两套镜像的正文由 bjj-agent-skills setup 插件的模板装入。改的是通用规则就先改模板再重新装入，否则下次重装会盖掉；只适用于本项目的约定就地加在仓库副本里，setup 的「已存在时」比对会保留它。
- 新建的 worktree 里没有 `node_modules`，先 `pnpm install --frozen-lockfile` 再跑 `pnpm check` 等检查命令，否则满屏 `Cannot find module` 容易被误判成本次改动引入的类型错误。
