# AgentIDE

AgentIDE is a mobile control surface for local coding agents. The monorepo contains the current macOS, iOS, and relay server applications together with their shared protocol and agent-host libraries.

## Repository layout

- `apps/macos`: macOS pairing and project-list application.
- `apps/ios`: iOS session and file-browser application.
- `apps/server`: payload-opaque relay server.
- `apps/agent-host`: local process boundary for adapters, files, and relay connectivity.
- `packages`: protocol, agent adapters, shared types, cryptography boundary, and Swift protocol DTOs.

Windows, Android, and Web clients are intentionally outside the MVP. New clients must integrate through the versioned protocol rather than importing an agent's native event format.

## Quality checks

The TypeScript commands run over every workspace project; the Swift and Xcode ones need macOS with Xcode installed.

- `pnpm check`: type-check all workspace projects.
- `pnpm build`: build all workspace projects.
- `pnpm test`: run the unit tests of all workspace projects.
- `pnpm check:swift`: test the Swift protocol DTO package.
- `pnpm check:macos` / `pnpm check:ios`: build the macOS and iOS applications without code signing.
- `pnpm test:ios`: run the iOS client simulation tests.

Run at least `pnpm check` before merging a change; add the platform commands that cover what the change touched.
