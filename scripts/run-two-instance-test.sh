#!/bin/zsh

set -euo pipefail

SCRIPT_PATH="${0:A}"
REPO_ROOT="${SCRIPT_PATH:h:h}"
TEST_ROOT="/tmp/PeerNestIntegration"
DERIVED_DATA="$TEST_ROOT/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/PeerNest.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PeerNest"
PEER_A_ROOT="$TEST_ROOT/PeerA"
PEER_B_ROOT="$TEST_ROOT/PeerB"
LOG_ROOT="$TEST_ROOT/Logs"
STATE_ROOT="$TEST_ROOT/State"

usage() {
    echo "Usage: $0 {build|reset|start|start-a|start-b|stop|stop-a|stop-b|status|capture-logs|logs|clean}"
    echo "  build  Build the isolated Debug application without changing test state."
    echo "  reset  Stop harness processes and reset only the isolated test state."
    echo "  start  Build Debug, reset isolated state, and launch both instances."
    echo "  start-a/start-b Launch one previously built instance without resetting state."
    echo "  stop   Stop only processes recorded by this harness."
    echo "  stop-a/stop-b Stop only the selected harness instance."
    echo "  status Show recorded process state and log locations."
    echo "  capture-logs Save separate sanitized PeerNest unified logs for A and B."
    echo "  logs   Print the latest captured and stdout/stderr logs."
    echo "  clean  Stop the harness and remove only $TEST_ROOT."
}

pid_file() { echo "$TEST_ROOT/$1.pid"; }
launcher_pid_file() { echo "$TEST_ROOT/$1.launcher.pid"; }

stop_instance() {
    local label="$1"
    local namespace="$2"
    local file=""
    file="$(pid_file "$label")"
    [[ -f "$file" ]] || return 0

    local pid=""
    pid="$(<"$file")"
    if [[ "$pid" != <-> ]]; then
        echo "Refusing invalid PID file: $file" >&2
        return 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        local command=""
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" != *"$APP_BINARY"* || "$command" != *"--test-namespace $namespace"* ]]; then
            echo "Refusing to stop PID $pid because it is not the recorded $namespace harness process." >&2
            return 1
        fi
        kill -TERM "$pid"
        local attempts=0
        while kill -0 "$pid" 2>/dev/null && (( attempts < 20 )); do
            sleep 0.25
            (( attempts += 1 ))
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "PID $pid did not stop after SIGTERM; leaving it untouched." >&2
            return 1
        fi
    fi
    /bin/rm -f "$file"

    local launcher_file=""
    launcher_file="$(launcher_pid_file "$label")"
    if [[ -f "$launcher_file" ]]; then
        local launcher_pid=""
        launcher_pid="$(<"$launcher_file")"
        if [[ "$launcher_pid" == <-> ]] && kill -0 "$launcher_pid" 2>/dev/null; then
            local launcher_command=""
            launcher_command="$(ps -p "$launcher_pid" -o command= 2>/dev/null || true)"
            if [[ "$launcher_command" == *"/usr/bin/open"* && "$launcher_command" == *"$APP_BUNDLE"* ]]; then
                kill -TERM "$launcher_pid" 2>/dev/null || true
            fi
        fi
        /bin/rm -f "$launcher_file"
    fi
}

stop_all() {
    stop_instance "peer-a" "peer-a"
    stop_instance "peer-b" "peer-b"
}

reset_state() {
    stop_all
    if [[ "$TEST_ROOT" != "/tmp/PeerNestIntegration" ]]; then
        echo "Refusing unexpected test root: $TEST_ROOT" >&2
        exit 1
    fi
    /bin/rm -rf "$TEST_ROOT"
    mkdir -p "$PEER_A_ROOT" "$PEER_B_ROOT" "$LOG_ROOT" "$STATE_ROOT/peer-a" "$STATE_ROOT/peer-b"
    chmod 700 "$TEST_ROOT" "$PEER_A_ROOT" "$PEER_B_ROOT" "$LOG_ROOT" "$STATE_ROOT" \
        "$STATE_ROOT/peer-a" "$STATE_ROOT/peer-b"
    /usr/bin/touch "$STATE_ROOT/peer-a/reset-defaults.request" "$STATE_ROOT/peer-b/reset-defaults.request"

    defaults delete com.mustafayurtoglu.PeerNest.integration.peer-a >/dev/null 2>&1 || true
    defaults delete com.mustafayurtoglu.PeerNest.integration.peer-b >/dev/null 2>&1 || true
    security delete-generic-password -s com.mustafayurtoglu.PeerNest.device-identity.integration.peer-a >/dev/null 2>&1 || true
    security delete-generic-password -s com.mustafayurtoglu.PeerNest.device-identity.integration.peer-b >/dev/null 2>&1 || true
}

build_debug() {
    xcodebuild -quiet \
        -project "$REPO_ROOT/PeerNest.xcodeproj" \
        -scheme PeerNest \
        -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$DERIVED_DATA" \
        build
}

launch_instance() {
    local label="$1"
    local namespace="$2"
    local name="$3"
    local listen_port="$4"
    local peer_port="$5"
    local share_path="$6"
    local auto_connect="$7"
    local log_file="$LOG_ROOT/$label.log"
    local args=(
        --instance-id "$namespace"
        --instance-name "$name"
        --test-namespace "$namespace"
        --listen-port "$listen_port"
        --peer-host 127.0.0.1
        --peer-port "$peer_port"
        --debug-share-path "$share_path"
        --integration-auto-start
    )
    if [[ "$auto_connect" == "yes" ]]; then
        args+=(--integration-auto-connect)
    fi

    /usr/bin/nohup /usr/bin/open -n -W -F -g \
        -o "$log_file" --stderr "$log_file" --env OS_ACTIVITY_MODE=stream \
        "$APP_BUNDLE" --args "${args[@]}" >/dev/null 2>&1 &
    local launcher_pid=$!
    echo "$launcher_pid" >"$(launcher_pid_file "$label")"

    local pid=""
    local attempts=0
    while [[ -z "$pid" ]] && (( attempts < 40 )); do
        pid="$(pgrep -f "$APP_BINARY.*--test-namespace $namespace" | tail -n 1 || true)"
        [[ -n "$pid" ]] || sleep 0.25
        (( attempts += 1 ))
    done
    if [[ -z "$pid" ]]; then
        kill -TERM "$launcher_pid" 2>/dev/null || true
        echo "Could not resolve the launched $namespace application PID." >&2
        return 1
    fi
    echo "$pid" >"$(pid_file "$label")"
    echo "Started $name as PID $pid; log: $log_file"
}

start_all() {
    reset_state
    build_debug
    launch_instance "peer-b" "peer-b" "Peer B" 51002 51001 "$PEER_B_ROOT" no
    sleep 1
    launch_instance "peer-a" "peer-a" "Peer A" 51001 51002 "$PEER_A_ROOT" yes
    echo
    echo "INSECURE DEBUG-ONLY localhost mode is active. It is not production pairing evidence."
    echo "Use '$SCRIPT_PATH status', '$SCRIPT_PATH logs', '$SCRIPT_PATH stop', or '$SCRIPT_PATH clean'."
}

start_one() {
    local label="$1"
    local file=""
    file="$(pid_file "$label")"
    if [[ -f "$file" ]]; then
        local existing_pid=""
        existing_pid="$(<"$file")"
        if [[ "$existing_pid" == <-> ]] && kill -0 "$existing_pid" 2>/dev/null; then
            echo "$label is already running as PID $existing_pid." >&2
            return 1
        fi
        /bin/rm -f "$file" "$(launcher_pid_file "$label")"
    fi
    [[ -x "$APP_BINARY" ]] || { echo "Build the harness first with '$SCRIPT_PATH start'." >&2; return 1; }
    if [[ "$label" == "peer-a" ]]; then
        launch_instance "peer-a" "peer-a" "Peer A" 51001 51002 "$PEER_A_ROOT" yes
    else
        launch_instance "peer-b" "peer-b" "Peer B" 51002 51001 "$PEER_B_ROOT" no
    fi
}

show_status() {
    for label in peer-a peer-b; do
        local file=""
        file="$(pid_file "$label")"
        if [[ -f "$file" ]]; then
            local pid=""
            pid="$(<"$file")"
            if kill -0 "$pid" 2>/dev/null; then
                echo "$label: running (PID $pid)"
            else
                echo "$label: stopped (stale PID $pid)"
            fi
        else
            echo "$label: not started"
        fi
    done
    echo "A root: $PEER_A_ROOT"
    echo "B root: $PEER_B_ROOT"
    echo "Logs:   $LOG_ROOT"
}

capture_logs() {
    for label in peer-a peer-b; do
        local file=""
        file="$(pid_file "$label")"
        [[ -f "$file" ]] || continue
        local pid=""
        pid="$(<"$file")"
        [[ "$pid" == <-> ]] || continue
        /usr/bin/log show --last 1h --style compact \
            --predicate "processIdentifier == $pid AND subsystem == 'com.mustafayurtoglu.PeerNest'" \
            >"$LOG_ROOT/$label-unified.log"
        echo "Captured $LOG_ROOT/$label-unified.log"
    done
}

case "${1:-}" in
    build) build_debug ;;
    reset) reset_state ;;
    start) start_all ;;
    start-a) start_one peer-a ;;
    start-b) start_one peer-b ;;
    stop) stop_all ;;
    stop-a) stop_instance peer-a peer-a ;;
    stop-b) stop_instance peer-b peer-b ;;
    status) show_status ;;
    capture-logs) capture_logs ;;
    logs)
        mkdir -p "$LOG_ROOT"
        capture_logs
        touch "$LOG_ROOT/peer-a.log" "$LOG_ROOT/peer-b.log" \
            "$LOG_ROOT/peer-a-unified.log" "$LOG_ROOT/peer-b-unified.log"
        tail -n 200 "$LOG_ROOT/peer-a.log" "$LOG_ROOT/peer-a-unified.log" \
            "$LOG_ROOT/peer-b.log" "$LOG_ROOT/peer-b-unified.log"
        ;;
    clean)
        stop_all
        if [[ "$TEST_ROOT" != "/tmp/PeerNestIntegration" ]]; then
            echo "Refusing unexpected test root: $TEST_ROOT" >&2
            exit 1
        fi
        /bin/rm -rf "$TEST_ROOT"
        defaults delete com.mustafayurtoglu.PeerNest.integration.peer-a >/dev/null 2>&1 || true
        defaults delete com.mustafayurtoglu.PeerNest.integration.peer-b >/dev/null 2>&1 || true
        security delete-generic-password -s com.mustafayurtoglu.PeerNest.device-identity.integration.peer-a >/dev/null 2>&1 || true
        security delete-generic-password -s com.mustafayurtoglu.PeerNest.device-identity.integration.peer-b >/dev/null 2>&1 || true
        ;;
    *) usage; exit 2 ;;
esac
