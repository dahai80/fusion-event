#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/.build/release/fusion-event"
BIN_DEBUG="$SCRIPT_DIR/.build/debug/fusion-event"
SOCK="${FUSION_EVENT_SOCK:-/tmp/fusion-event.sock}"
PID_FILE="${FUSION_EVENT_DATA:-$HOME/.fusion-event}/fusion-event.pid"
LOG_FILE="${FUSION_EVENT_DATA:-$HOME/.fusion-event}/launchd.log"
DATA_DIR="${FUSION_EVENT_DATA:-$HOME/.fusion-event}"

PLIST_LABEL="com.fusion.event"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

cmd="${1:-status}"

resolve_bin() {
    if [[ -x "$BIN" ]]; then echo "$BIN"
    elif [[ -x "$BIN_DEBUG" ]]; then echo "$BIN_DEBUG"
    else echo ""; fi
}

rotate_log() {
    local f="$LOG_FILE"
    [[ -f "$f" ]] || return 0
    local sz
    sz="$(stat -f%z "$f" 2>/dev/null || echo 0)"
    if [[ "$sz" -gt 10485760 ]]; then
        for i in 3 2 1; do
            [[ -f "$f.$i" ]] && mv "$f.$i" "$f.$((i+1))"
        done
        mv "$f" "$f.1"
        echo "[rotate] $f size=${sz}B rotated (O4: log rotation)" >> "$f.1"
    fi
}

do_start() {
    exec 9>"$DATA_DIR.lock"
    if ! flock -n 9; then
        echo "ERROR: another start.sh instance holding lock, abort (M5)" >&2
        exit 1
    fi
    local bin
    bin="$(resolve_bin)"
    if [[ -z "$bin" ]]; then
        echo "binary not found, building..." >&2
        (cd "$SCRIPT_DIR" && swift build -c release 2>&1 | tail -5)
        bin="$(resolve_bin)"
    fi
    [[ -z "$bin" ]] && { echo "ERROR: build failed" >&2; exit 1; }
    mkdir -p "$DATA_DIR"
    rotate_log
    if [[ -f "$PLIST_FILE" ]]; then
        echo "[WARN] launchd agent installed ($PLIST_FILE) — prefer 'start.sh install' for production; nohup 'start' may race with launchd KeepAlive (O9)" >&2
    fi
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "already running pid=$(cat "$PID_FILE")"
        return 0
    fi
    setsid "$bin" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        echo "started pid=$pid sock=$SOCK"
    else
        echo "ERROR: start failed, see $LOG_FILE" >&2
        exit 1
    fi
}

do_stop() {
    if launchctl list "$PLIST_LABEL" >/dev/null 2>&1; then
        local lpid
        lpid="$(launchctl list "$PLIST_LABEL" 2>/dev/null | grep -o '"PID" = [0-9]*' | grep -o '[0-9]*' || true)"
        if [[ -n "$lpid" ]]; then
            launchctl unload "$PLIST_FILE" 2>/dev/null || true
            for i in $(seq 1 50); do
                kill -0 "$lpid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$lpid" 2>/dev/null; then
                kill -9 "$lpid" 2>/dev/null || true
            fi
            rm -f "$SOCK"
            echo "stopped (launchd)"
            return
        fi
    fi
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid
        pid="$(cat "$PID_FILE")"
        kill -TERM "$pid"
        for i in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
        echo "stopped"
    else
        echo "not running"
    fi
    rm -f "$SOCK"
}

do_status() {
    local lpid
    lpid="$(launchctl list "$PLIST_LABEL" 2>/dev/null | grep -o '"PID" = [0-9]*' | grep -o '[0-9]*' || true)"
    if [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null; then
        local mem
        mem="$(ps -o rss= -p "$lpid" 2>/dev/null | tr -d ' ')"
        echo "running (launchd) pid=$lpid rss=${mem}KB sock=$SOCK"
        return
    fi
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local pid
        pid="$(cat "$PID_FILE")"
        local mem
        mem="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
        echo "running pid=$pid rss=${mem}KB sock=$SOCK"
    else
        echo "not running"
    fi
}

do_log() {
    shift || true
    if [[ "${1:-}" == "-f" ]]; then
        tail -f "$LOG_FILE"
    else
        tail -n 100 "$LOG_FILE"
    fi
}

rpc_call() {
    local method="$1"
    local params="${2:-{}}"
    printf '{"jsonrpc":"2.0","method":"%s","params":%s,"id":1}\n' "$method" "$params" | nc -U -w2 "$SOCK" 2>/dev/null || echo ""
}

health_field() {
    local json="$1"
    local field="$2"
    python3 -c "
import sys, json
try:
    r = json.loads(sys.argv[1])
    t = r.get('result', {})
    if sys.argv[2] in t: print(t[sys.argv[2]])
    else:
        tr = t.get('triggers', {})
        if sys.argv[2] in tr: print(tr[sys.argv[2]])
        else: print('')
except Exception: print('')
" "$json" "$field" 2>/dev/null
}

do_doctor() {
    local pass=0 fail=0 warn=0
    if [[ -S "$SOCK" ]]; then echo "[OK] socket exists $SOCK"; ((pass++)); else echo "[FAIL] socket missing"; ((fail++)); fi
    local h
    h="$(rpc_call event.health)"
    local ok
    ok="$(health_field "$h" ok)"
    if [[ "$ok" == "True" ]]; then
        echo "[OK] event.health reachable"; ((pass++))
        local submitted blocked failed dropped disp_dropped
        submitted="$(health_field "$h" submitted)"
        blocked="$(health_field "$h" blocked)"
        failed="$(health_field "$h" failed)"
        dropped="$(health_field "$h" dropped)"
        disp_dropped="$(health_field "$h" dispatch_dropped)"
        echo "[INFO] triggers submitted=${submitted:-0} blocked=${blocked:-0} failed=${failed:-0} dropped=${dropped:-0} dispatch_dropped=${disp_dropped:-0} (O5)"
        if [[ "${failed:-0}" != "0" ]]; then echo "[WARN] failed triggers=${failed} — check downstream agent-studio reachability"; ((warn++)); fi
        if [[ "${dropped:-0}" != "0" || "${disp_dropped:-0}" != "0" ]]; then echo "[WARN] dropped triggers present — possible backpressure/source flood"; ((warn++)); fi
        local pend
        pend="$(find "$DATA_DIR/outbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${pend:-0}" -gt 50 ]]; then echo "[WARN] outbox backlog ${pend} files — downstream may be down, triggers queued for replay"; ((warn++)); else echo "[OK] outbox backlog ${pend:-0}"; ((pass++)); fi
    else
        echo "[FAIL] event.health unreachable (O10: python json parse, not grep)"; ((fail++))
    fi
    if [[ -f "$DATA_DIR/rules.db" ]]; then echo "[OK] rules.db exists"; ((pass++)); else echo "[WARN] rules.db missing (first run ok)"; ((warn++)); fi
    echo "doctor: pass=$pass warn=$warn fail=$fail"
    [[ $fail -eq 0 ]]
}

do_install() {
    local bin
    bin="$(resolve_bin)"
    [[ -z "$bin" ]] && { echo "ERROR: build release first (swift build -c release)" >&2; exit 1; }
    bin="$(cd "$SCRIPT_DIR" && cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
    mkdir -p "$(dirname "$PLIST_FILE")"
    cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${bin}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ExitTimeOut</key>
    <integer>15</integer>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>FUSION_EVENT_DATA</key>
        <string>${DATA_DIR}</string>
    </dict>
</dict>
</plist>
EOF
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE" 2>/dev/null
    echo "installed launchd agent ${PLIST_LABEL} (KeepAlive, RunAtLoad)"
    echo "logs: ${LOG_FILE}"
}

do_uninstall() {
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    rm -f "$PLIST_FILE"
    echo "uninstalled launchd agent ${PLIST_LABEL}"
}

case "$cmd" in
    start) do_start ;;
    stop) do_stop ;;
    status) do_status ;;
    log) do_log "$@" ;;
    doctor) do_doctor ;;
    install) do_install ;;
    uninstall) do_uninstall ;;
    *) echo "usage: $0 {start|stop|status|log [-f]|doctor|install|uninstall}"; exit 1 ;;
esac
