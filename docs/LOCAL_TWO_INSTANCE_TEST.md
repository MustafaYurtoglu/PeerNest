# Local two-instance test

This harness runs two real copies of the Debug app with isolated state. It intentionally uses insecure plaintext localhost transport. It is not production pairing or encryption evidence, and none of its controls are available in Release.

Run commands from the repository root.

## Build and reset

```sh
./scripts/run-two-instance-test.sh stop
./scripts/run-two-instance-test.sh reset
./scripts/run-two-instance-test.sh build
```

`reset` removes only `/tmp/PeerNestIntegration`, requests an in-sandbox reset of the `peer-a` and `peer-b` defaults domains, and clears only the two integration Keychain services. It never touches a normal PeerNest identity, normal shared folder, or unrelated process.

Optional: prepare files before initial synchronization:

```sh
mkdir -p /tmp/PeerNestIntegration/PeerA/NestedA/deeper
mkdir -p /tmp/PeerNestIntegration/PeerB/NestedB
```

## Launch separately

Start B first, then A:

```sh
./scripts/run-two-instance-test.sh start-b
./scripts/run-two-instance-test.sh start-a
./scripts/run-two-instance-test.sh status
```

A listens on 51001 and connects to B on 51002. B listens on 51002. Roots and state are:

```text
/tmp/PeerNestIntegration/PeerA
/tmp/PeerNestIntegration/PeerB
/tmp/PeerNestIntegration/State/peer-a
/tmp/PeerNestIntegration/State/peer-b
```

For a one-command fresh build/reset/launch:

```sh
./scripts/run-two-instance-test.sh start
```

## Inspect status and logs

```sh
./scripts/run-two-instance-test.sh status
./scripts/run-two-instance-test.sh capture-logs
./scripts/run-two-instance-test.sh logs
```

Separate logs are stored at:

```text
/tmp/PeerNestIntegration/Logs/peer-a.log
/tmp/PeerNestIntegration/Logs/peer-b.log
/tmp/PeerNestIntegration/Logs/peer-a-unified.log
/tmp/PeerNestIntegration/Logs/peer-b-unified.log
```

The unified-log capture is restricted to the recorded process ID and the PeerNest subsystem. Logs contain abbreviated peer/mapping identifiers and safe relative paths, not keys, bookmark blobs, payload contents, or full production paths.

## Offline and relaunch tests

Stop only one harness instance:

```sh
./scripts/run-two-instance-test.sh stop-b
./scripts/run-two-instance-test.sh status
```

Make changes under `PeerA`, then relaunch B:

```sh
./scripts/run-two-instance-test.sh start-b
```

To prove A's journal survives its own relaunch:

```sh
./scripts/run-two-instance-test.sh stop-a
./scripts/run-two-instance-test.sh start-a
```

Confirm both roots converge and inspect each namespaced `Recovery/recovery-v1.json`; active pending counts should return to zero.

## Stop and clean

```sh
./scripts/run-two-instance-test.sh stop-a
./scripts/run-two-instance-test.sh stop-b
./scripts/run-two-instance-test.sh stop
./scripts/run-two-instance-test.sh clean
```

The script validates recorded PIDs against the exact Debug binary and `--test-namespace` argument before sending SIGTERM. It refuses to stop an unrelated PeerNest process. `clean` deletes only `/tmp/PeerNestIntegration` and the two integration Keychain services. The next `reset` places per-namespace markers that make each sandboxed Debug instance clear its own integration defaults before launch.
