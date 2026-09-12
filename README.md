# Agent Guard

A macOS menu bar application for configuring application monitoring, sensitive-file rules, and user-controlled security decisions.

**Early development. No network or file-access enforcement is active yet.** Saving a rule does not protect a process. This repository will report runtime coverage separately from configured policy.

## Product direction

- Stay quietly in the macOS menu bar.
- Let users select desktop applications and CLI executables to monitor.
- Let users select sensitive paths, including SSH private keys, without indexing their contents by default.
- Record meaningful security events and support explicit user decisions where the platform allows them.
- Share policy concepts across CLI and desktop applications while preserving platform identity and execution boundaries.

## Development approach

The initial macOS app uses Swift and SwiftUI. Native Network Extension and Endpoint Security integrations require separate capability and distribution validation. Anthropic's TypeScript/Node.js sandbox-runtime is evaluated as an optional controlled-launch backend, not as a system-wide process attachment API.

Public development takes place on feature branches. Local conversation transcripts, diagnostic output, personal paths, credentials, and research scratch files are excluded from commits.

