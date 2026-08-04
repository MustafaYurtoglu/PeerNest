# PeerNest pre-TestFlight validation

Validation date: 2026-08-04

## Environment

- Repository commit at start: `4be5cf979e0cdddf2622be6e9aced6d9700cee38`
- Worktree: already dirty; all pre-existing changes were preserved
- Xcode: 26.4 (17E192)
- macOS: 26.5.2 (25F84)
- Hardware architecture: arm64
- Main bundle ID: `com.mustafayurtoglu.PeerNest`
- Finder extension bundle ID: `com.mustafayurtoglu.PeerNest.FinderExtension`
- Team: `648PZ73UQ8`
- App Group: `group.com.mustafayurtoglu.PeerNest`
- Deployment target: 26.4 (unchanged)

## Runtime implementation assessment

The launch path was traced from `PeerNestApp` / `AppDelegate` through `ServiceContainer`, `AppState.launch`, device identity, secure sync coordinator, Bonjour listener/browser, pairing/trust, invitation/mapping, folder watcher, journal, transfer, remote application, and recovery.

Bonjour advertisement/browser, incoming/outgoing connections, pairing and trusted-peer persistence, authenticated transport, invitation and share mapping, manifest building, live events, chunked transfer, remote application, loop suppression, recovery journal, reconciliation, conflict models, PeerNest Trash, and version history are implemented runtime paths rather than empty scaffolding. Production pairing UI and physical-LAN Bonjour behavior were not proven by the localhost harness.

## Builds

Dedicated DerivedData was used under `/tmp/PeerNestPreTestFlight`.

```sh
xcodebuild -project PeerNest.xcodeproj -scheme PeerNest -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PeerNestPreTestFlight/final-main-debug clean build

xcodebuild -project PeerNest.xcodeproj -scheme PeerNest -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PeerNestPreTestFlight/final-main-release clean build

xcodebuild -project PeerNest.xcodeproj -scheme PeerNestFinderExtension -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PeerNestPreTestFlight/final-finder-debug clean build

xcodebuild -project PeerNest.xcodeproj -scheme PeerNestFinderExtension -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PeerNestPreTestFlight/final-finder-release clean build

xcodebuild -project PeerNest.xcodeproj -scheme PeerNest -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PeerNestPreTestFlight/final-tests build-for-testing
```

Results: main Debug passed, main Release passed, Finder Debug passed, Finder Release passed, and all test targets built. The repeated `IDERunDestination: Supported platforms ... is empty` diagnostic is an Xcode scheme diagnostic; it did not fail a build. AppIntents metadata extraction was skipped because the app does not link AppIntents; this is harmless.

## Automated tests

The Swift Testing bundle was run directly to avoid LaunchServices reusing an unrelated, already-running PeerNest process:

```sh
env DYLD_LIBRARY_PATH=/tmp/PeerNestPreTestFlight/final-tests/Build/Products/Debug/PeerNest.app/Contents/MacOS \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  /tmp/PeerNestPreTestFlight/final-tests/Build/Products/Debug/PeerNest.app/Contents/PlugIns/PeerNestTests.xctest
```

Final result: **103 passed, 0 failed, 0 skipped**, 14 suites, 8.689 seconds.

The earlier all-target Xcode run executed 97 items: 95 passed and 2 runner/test failures. The unit integration failure was fixed (sandboxed test bookmark access). The UI runner could not enable automation mode because a separate user-launched PeerNest process was already active. It was deliberately not terminated. The three UI test methods therefore remain unexecuted in the final run; this is an environment limitation, not a passing UI result.

## Two-instance configuration

The harness uses real Debug application processes and these arguments:

```text
Instance A: --instance-id peer-a --instance-name "Peer A"
            --test-namespace peer-a --listen-port 51001
            --peer-host 127.0.0.1 --peer-port 51002
            --debug-share-path /tmp/PeerNestIntegration/PeerA
            --integration-auto-start --integration-auto-connect

Instance B: --instance-id peer-b --instance-name "Peer B"
            --test-namespace peer-b --listen-port 51002
            --peer-host 127.0.0.1 --peer-port 51001
            --debug-share-path /tmp/PeerNestIntegration/PeerB
            --integration-auto-start
```

Namespaces isolate UserDefaults, Keychain identity service, bookmarks, Finder state, mapping store, recovery repository, operation journal, and shared roots. The reset marker is consumed inside the sandbox so a reset really clears the namespaced defaults. The only added filesystem exception is the exact `/private/tmp/PeerNestIntegration/` path in `PeerNestDebug.entitlements`; Release uses the original production entitlements.

## Scenarios actually passed

- Two real processes ran concurrently with different stable peer IDs and ports 51001/51002.
- TCP connection, hello/helloAck, ready handshake, single deterministic share offer, stable mappings, disconnect detection, and bounded reconnect were observed in separate sanitized logs.
- Pre-populated A and B trees reconciled conservatively in both directions; unmatched files were preserved and byte comparisons passed.
- Live A→B and B→A create, modify, empty file, binary file, rename, nested move, file delete, and directory delete passed with final filesystem assertions.
- The rename-source deletion defect was retested after the watcher snapshot fix and passed in both directions.
- Final offline run queued eight raw watcher records, survived an A relaunch, coalesced them, replayed edit/create/rename/delete, converged, and ended with zero active pending operations and zero conflicts on both peers.
- A real 64 MiB zero-filled file transferred A→B. Both sides were 67,108,864 bytes and SHA-256 was `3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351`; no staging residue remained.
- The automated real-loopback authenticated transport test passed, including encrypted handshake and payload exchange.
- Pairing transcript equality, signatures, confirmation on both sides, replay rejection, expiry, rejection, trust persistence, and identity-change behavior passed component/integration tests.
- Path traversal, nested traversal, absolute/malformed paths, shared-root deletion, symlink escape, overlapping roots, and corrupt Finder snapshot/one-shot command queue cases passed automated tests.
- No infinite echo was observed; live and offline runs returned to zero active pending operations. Exact packet/operation cardinality was not instrumented in the real processes.

## Fixes applied during validation

- Added DEBUG-only namespaced persistence and a safe two-process launcher.
- Added a Debug-only narrow `/private/tmp/PeerNestIntegration/` sandbox entitlement; Release remains unchanged.
- Replaced security-scoped test bookmarks with an explicit DEBUG test bookmark store.
- Fixed debounce cancellation dropping a file event that arrives while hashing/transferring another file.
- Added watcher snapshots so APFS rename/move old paths and missed deletes become journaled deletions.
- Made DEBUG share negotiation single-owner, persisted mappings, and reused mapping IDs after relaunch.
- Added one-time DEBUG initial reconciliation and deterministic sandboxed-defaults reset.
- Fixed false delete-vs-modify conflicts when the expected version matches.
- Allowed transfer-resume responses to bypass a serialized-message deadlock.
- Registered remote tombstones with the suppression registry.
- Coalesced reconciliation journal entries, terminalized superseded records, and stopped identical versions from creating conflict copies.
- Added focused regression tests for the defects above.

## Release security audit

- Release main and embedded Finder extension signatures verify with `codesign --verify --deep --strict`.
- Release main has App Sandbox, App Group, app-scope bookmarks, user-selected read/write, and client/server networking.
- Release Finder extension has the same App Group/bookmark access and **no networking entitlement**.
- Release has no temporary absolute-path sandbox exception; Debug alone contains the exact integration-root exception.
- Release binary string inspection found none of: `PeerNestIntegration`, `test-namespace`, `integration-auto`, `debug-share-path`, or `/Users/mustafa`. `plaintextForbidden` remains intentionally as the fail-closed error symbol.
- `#if DEBUG` removes test namespaces, deterministic test identity overrides, automatic test shares, and localhost plaintext controls from Release behavior.
- Bundle IDs, Team, App Group, deployment target, Info.plist Bonjour service, local-network description, signing settings, and branding assets were preserved.
- The locally built Release is development-signed and contains `get-task-allow=true`. This is expected for this Xcode build command but is not distribution/archive evidence; the TestFlight archive must be distribution-signed and re-audited.

## Not fully validated / manual-only

- Production UI pairing and trust persistence between two running app processes.
- Bonjour discovery, local-network privacy prompt, firewall behavior, duplicate connection resolution, and encrypted production sync between two physical Macs.
- Actual two-sided offline conflict convergence and delete-versus-modify convergence through the app protocol. Their deterministic algorithms and persistence tests passed, but this was not a process-level scenario.
- Menu bar visibility, window reopen/no-duplicate-window behavior, background sync after close, explicit Quit teardown, and Dock policy. UI automation was blocked.
- Real sleep/wake, network interface change, and service restart exactly-once behavior. Coordinators were inspected; actual sleep was intentionally not forced.
- Finder extension enablement in System Settings, live context menus, and live badges. Build, embedding, identifiers, entitlements, atomic queue, and snapshot tests passed.
- Memory growth during the 64 MiB transfer was not sampled. Code/tests verify 256 KiB streaming, chunk framing, resume, hash checking, atomic promotion, and partial cleanup.
- Release archive/export/notarization, App Store validation, privacy answers, and the TODO Support/Privacy/Marketing URLs.

## Recommendation

**Not ready for TestFlight.** Core localhost synchronization and Release fail-closed checks are strong, but production pairing/Bonjour/encrypted sync still requires a second physical Mac; UI lifecycle tests were blocked; actual process-level conflict/delete-vs-modify scenarios remain; and a distribution-signed archive plus required App Store URLs have not been validated.
