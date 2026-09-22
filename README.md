# AgentIDE

AgentIDE is a mobile control surface for local coding agents. The monorepo contains the current macOS, iOS, and relay server applications together with their shared protocol and agent-host libraries.

## Repository layout

- `apps/macos`: macOS pairing and project-list application.
- `apps/ios`: iOS session and file-browser application.
- `apps/server`: payload-opaque relay server.
- `apps/agent-host`: local process boundary for adapters, files, and relay connectivity.
- `packages`: protocol, agent adapters, shared types, cryptography boundary, and Swift protocol DTOs.

Windows, Android, and Web clients are intentionally outside the MVP. New clients must integrate through the versioned protocol rather than importing an agent's native event format.
