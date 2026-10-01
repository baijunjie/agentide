# Agent 配置

- 项目行为指令统一写在 `AGENTS.md`；`CLAUDE.md` 是指向它的符号链接，不要分别维护。构建、测试与质量检查等工程信息写在 `README.md`。
- 仓库同时提交 Codex 使用的 `.agents/skills/`、`.codex/agents/` 与 Claude Code 使用的 `.claude/skills/`、`.claude/agents/`；修改已安装的同名 skill 或子代理时，两套正文必须保持一致，只允许宿主元数据与文件格式不同。
- 通用规则先在 bjj-agent-skills 的源模板中定型，再同步项目副本；仓库内的副本只保留本项目特有的补充，避免后续插件更新覆盖通用改动。
