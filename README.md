# Agent Guard

A macOS menu bar application for configuring application monitoring, sensitive-file rules, and user-controlled security decisions.

**Early development.** The macOS binary contains the policy and `AUTH_OPEN` enforcement seam, but the default local build is ad-hoc signed and the menu-bar process is not a root Endpoint Security client. A production implementation must move the ES client into a signed, Apple-entitled root LaunchDaemon and keep this app as the configuration/notification control plane. Saving a rule alone is not proof of protection; the UI reports the runtime capability separately from configured policy.

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

Click the shield in the menu bar and open the configuration window. Add applications and sensitive paths, then click **测试通知** beside a rule. The first test asks macOS for notification permission; the resulting notification has **允许一次**, **阻止**, and **打开 Agent Guard** actions. Choosing an action updates the audit record. This is a safe end-to-end notification test: it does not read, write, or block the selected file.

The notification uses the bundled Agent Guard shield icon. If macOS still shows the old generic icon after upgrading, quit Agent Guard completely and launch the newly built `.app` again so Notification Center reloads the bundle metadata.

The real file path subscribes to `AUTH_OPEN` and only considers an event when both the executable and configured sensitive path match. `record` responds with allow and writes metadata; `ask` shows a notification and waits only until the Endpoint Security deadline; `block` responds with denied flags and shows a post-decision notification. Unmatched events are allowed without an audit entry. The current prototype reports missing entitlement or missing root privilege instead of pretending it is protecting files; it is not yet the final daemon/GUI split.

Configuration and metadata-only audit records are stored in `~/Library/Application Support/AgentGuard/configuration.json` and `audit.json`, respectively. Both files are written with a private directory and `0600` file mode, and audit history is bounded to 500 entries. File contents, raw paths from Endpoint Security events, and notification bodies are not persisted. For isolated development runs, set `AGENT_GUARD_DATA_DIR` when launching the executable.

To build a controlled read-only probe for a real entitlement acceptance test:

```sh
bash scripts/build-open-probe.sh
printf 'agent-guard test\n' > /tmp/agent-guard-probe.txt
```

Add `build/agent-guard-open-probe` as a protected CLI and `/tmp/agent-guard-probe.txt` as a blocked rule. A signed/approved Agent Guard build should make the probe return `Permission denied` or `Operation not permitted` and add an Endpoint Security event to the records tab. The helper only opens and reads one byte; it never creates or changes the target file.

The build script accepts `CODE_SIGN_IDENTITY` for a real signed build and supplies `Resources/AgentGuard.entitlements`. That entitlement must be issued for the signing identity by Apple. The future root helper must also be approved under **System Settings → Privacy & Security → Full Disk Access**. Without the Apple entitlement, a valid signed helper, root deployment, and TCC approval, the expected state is “未启用”, not a failed policy decision. See [macOS entitlement and privileged-helper setup](docs/macos-entitlement.md).

The **能力状态** tab has buttons for opening the Full Disk Access page, revealing the current `Agent Guard.app` in Finder, and copying its path. The buttons are useful for the control-plane app during development; the production permission entry must point to the exact signed privileged helper or its approved bundle. The app cannot add itself to the protected list silently; macOS requires the user to confirm the bundle in System Settings.

To test Codex specifically, first add the Codex `.app` from **应用** and add a temporary test file rule with `询问我` or `阻止`. Ask Codex to perform an operation that opens that exact file. A real event appears in **记录** with `Endpoint Security` as its source and the actual application name. If the state is still “未启用”, or no event appears, test the controlled probe above first; if that works, add the executable helper that Codex actually uses when it lives outside the `.app/Contents/` directory.

See the [architecture and limitations](docs/architecture.md) and [implementation milestones](docs/roadmap.md).
