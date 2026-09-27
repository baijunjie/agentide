export {
  ClaudeAdapter,
  createReportServer,
  type ClaudeAdapterOptions,
  type ClaudeQueryFactory,
  type ClaudeQueryRequest,
} from "./adapter.js";

export const CLAUDE_ADAPTER_KIND = "claude" as const;
