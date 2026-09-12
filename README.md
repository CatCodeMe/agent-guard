# Agent Guard

A macOS menu bar application for configuring application monitoring, sensitive-file rules, and user-controlled security decisions.

**Early development. No network or file-access enforcement is active yet.** Saving a rule does not protect a process. This repository will report runtime coverage separately from configured policy.

## Product direction

- Stay quietly in the macOS menu bar.
- Let users select desktop applications and CLI executables to monitor, with hints for common Codex, Claude and Cursor install locations.
- Let users select sensitive paths, including SSH private keys, without indexing their contents by default.
- Record meaningful security events and support explicit user decisions where the platform allows them.
- Share policy concepts across CLI and desktop applications while preserving platform identity and execution boundaries.

## Development approach

The initial macOS app uses Swift and SwiftUI. Native Network Extension and Endpoint Security integrations require separate capability and distribution validation. Anthropic's TypeScript/Node.js sandbox-runtime is an optional controlled-launch backend: Agent Guard can detect an installed `srt`, but does not bundle Node, install it, or use it to attach to an already-running desktop app.

Public development takes place on feature branches. Local conversation transcripts, diagnostic output, personal paths, credentials, and research scratch files are excluded from commits.

## Build and run

Requires macOS 14 or newer and a Swift 6 toolchain.

```sh
swift test
bash scripts/build-app.sh
open "build/Agent Guard.app"
```

Click the shield in the menu bar and open the configuration window. Add applications and sensitive paths, then use the preview button to simulate a rule decision. All preview events are synthetic and retained only in memory.

Configuration is stored in `~/Library/Application Support/AgentGuard/configuration.json`. For isolated development runs, set `AGENT_GUARD_DATA_DIR` when launching the executable. The build script creates an ad-hoc signed local development app; it does not install privileged services or produce a notarized distribution.

See the [architecture and limitations](docs/architecture.md) and [implementation milestones](docs/roadmap.md).
