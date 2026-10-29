#!/bin/bash
# Tests for the start.sh port-registry self-check (issue #14, Config Phase 3.3).
# Sources start.sh (dispatch guard prevents command execution) and exercises
# registry_selfcheck against temp registry copies:
#   1. missing registry file      -> warn + exit 0 (standalone deploy)
#   2. no fusion-event entry      -> exit 0 (UDS-only, correctly unregistered)
#   3. entry with port            -> refuse, exit 1 (misregistration)
#   4. entry with port + bypass   -> warn + exit 0 (FUSION_SKIP_REGISTRY_CHECK=1)
#   5. entry without port         -> exit 0 (documented UDS-only entry is fine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SH="$SCRIPT_DIR/../start.sh"
TMP="$(mktemp -d /tmp/fe-registry-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

run_check() {
    # Subshell: exit code of registry_selfcheck without killing this script.
    ( source "$START_SH" && registry_selfcheck )
}

expect() {
    local name="$1" want_rc="$2" want_msg="$3" rc out
    set +e
    out="$(run_check 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" == "$want_rc" ]] && [[ "$out" == *"$want_msg"* ]]; then
        echo "[OK] $name"
        pass=$((pass+1))
    else
        echo "[FAIL] $name: rc=$rc (want $want_rc), output: $out" >&2
        fail=$((fail+1))
    fi
}

# 1. missing registry file
export FUSION_REGISTRY="$TMP/absent.yaml"
unset FUSION_SKIP_REGISTRY_CHECK || true
expect "missing registry warns + continues" 0 "registry self-check skipped"

# 2. registry present, no fusion-event entry
cat > "$TMP/ok.yaml" <<'EOF'
services:
  fusion-mlx:
    port: 11434
    purpose: MLX inference
  fusion-gateway:
    port: 11432
    purpose: API gateway
EOF
export FUSION_REGISTRY="$TMP/ok.yaml"
expect "no entry passes" 0 ""

# 3. entry with port (misregistration — daemon is UDS-only)
cat > "$TMP/bad.yaml" <<'EOF'
services:
  fusion-mlx:
    port: 11434
    purpose: MLX inference
  fusion-event:
    port: 11499
    purpose: misregistered event daemon
    boot: T2
    fixed: false
EOF
export FUSION_REGISTRY="$TMP/bad.yaml"
expect "port entry refuses" 1 "refusing to start"

# 4. bypass flag
FUSION_SKIP_REGISTRY_CHECK=1 expect "bypass warns + continues" 0 "registry check bypassed"
unset FUSION_SKIP_REGISTRY_CHECK || true

# 5. entry without port (documented UDS-only entry)
cat > "$TMP/nosock.yaml" <<'EOF'
services:
  fusion-event:
    purpose: UDS-only reactive event daemon (no TCP port)
    boot: T2
EOF
export FUSION_REGISTRY="$TMP/nosock.yaml"
expect "entry without port passes" 0 ""

echo "registry self-check tests: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
