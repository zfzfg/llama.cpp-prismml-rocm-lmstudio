#!/usr/bin/env bash
# Tests install-linux-llmster.sh against temporary LMS_HOME directories and a stub lms.
# It runs the real staged llama-server, so it needs the pinned archive:
#   tests/install-linux-llmster.test.sh /path/to/llama-prism-b12128-d7b2896-bin-ubuntu-vulkan-x64.tar.gz
# Temporary directories stay under a mktemp directory, which is printed at the end.
set -uo pipefail

ARCHIVE="${1:?usage: $0 <pinned archive>}"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-linux-llmster.sh"
ENGINE=llama.cpp-linux-x86_64-prism-vulkan-b12128
OFFICIAL=llama.cpp-linux-x86_64-vulkan-avx2
ROOT="$(mktemp -d)"
failures=0

check() {
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

# The stub curl serves the archive, so the script's SHA-256 check still runs on real bytes.
mkdir "$ROOT/bin"
cat > "$ROOT/bin/curl" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do if [[ "\$1" == -o ]]; then cp "$ARCHIVE" "\$2"; exit 0; fi; shift; done
exit 1
EOF
chmod +x "$ROOT/bin/curl"
export PATH="$ROOT/bin:$PATH"

setup() {
    LMS_HOME="$(mktemp -d -p "$ROOT" lms.XXXXXX)"
    export LMS_HOME
    mkdir -p "$LMS_HOME/bin" "$LMS_HOME/.internal" "$LMS_HOME/extensions/backends/$OFFICIAL-2.66.0"
    local official="$LMS_HOME/extensions/backends/$OFFICIAL-2.66.0"
    echo fake > "$official/libllm_engine.so"
    cat > "$official/backend-manifest.json" <<EOF
{"name":"$OFFICIAL","version":"2.66.0","engine_protocol_server":{"runtime_kind":"llama-server","executable_relative_path":"llama-server"}}
EOF
    cat > "$LMS_HOME/.internal/internal-engine-index.json" <<EOF
{"json":[{"manifest":{"name":"$OFFICIAL","version":"2.66.0"},"dirPath":"$official","libLmStudioPath":"$official/l.node","launchInfo":{"engineLibPath":"$official/e.node"}}],"meta":{"values":{"0.displayData":["map"]}}}
EOF
    echo '{"formatDefaults":{"gguf":"previous"},"versions":{"previous":"1.0.0"}}' > "$LMS_HOME/.internal/backend-preferences-v2.json"
    cat > "$LMS_HOME/bin/lms" <<'EOF'
#!/usr/bin/env bash
state="$LMS_HOME/stub"
mkdir -p "$state"
echo "$*" >> "$state/calls"
case "$1 ${2:-}" in
    "ps ") if [[ "${STUB_LOADED:-}" == 1 ]]; then echo "IDENTIFIER glm-ocr"; else echo "No models are currently loaded."; fi ;;
    "server status") echo "The server is running on port 1234." ;;
    "server start") echo up > "$state/server" ;;
    "daemon down")
        echo down > "$state/daemon"
        if [[ "${STUB_FAIL:-}" == corrupt_on_down ]]; then echo broken > "$LMS_HOME/.internal/internal-engine-index.json"; fi ;;
    "daemon up")
        if [[ "${STUB_FAIL:-}" == daemon_up && ! -e "$state/failed" ]]; then touch "$state/failed"; exit 1; fi
        # The real daemon registers hidden directories in backends and outlives the installer.
        find "$LMS_HOME/extensions/backends" -mindepth 1 -maxdepth 1 -name ".*" >> "$state/hidden"
        sleep 30 >/dev/null 2>&1 &
        echo up > "$state/daemon" ;;
    "runtime select")
        if [[ "${STUB_FAIL:-}" == select ]]; then echo changed > "$LMS_HOME/.internal/backend-preferences-v2.json"; exit 1; fi
        echo "{\"selected\":\"$3\"}" > "$LMS_HOME/.internal/backend-preferences-v2.json" ;;
esac
EOF
    chmod +x "$LMS_HOME/bin/lms"
}

snapshot() {
    (cd "$LMS_HOME" && find extensions -type f | sort | xargs sha256sum; sha256sum .internal/internal-engine-index.json .internal/backend-preferences-v2.json) > "$ROOT/$1"
}
unchanged() { snapshot after; cmp -s "$ROOT/before" "$ROOT/after"; }
daemon_up() { [[ "$(cat "$LMS_HOME/stub/daemon" 2>/dev/null)" == up ]]; }
never_stopped() { ! grep -q "daemon down" "$LMS_HOME/stub/calls"; }
no_leftovers() { [[ -z "$(find "$LMS_HOME/extensions" "$LMS_HOME/extensions/backends" -maxdepth 1 -name ".*")" ]]; }
no_hidden_backends() { [[ ! -s "$LMS_HOME/stub/hidden" ]]; }
lock_free() { flock -n "$LMS_HOME/.internal/.prism-installer.lock" true; }
target() { echo "$LMS_HOME/extensions/backends/$ENGINE-2.67.0"; }
index_has_engine() { grep -q "\"name\": \"$ENGINE\"" "$LMS_HOME/.internal/internal-engine-index.json"; }

setup
"$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
check "install succeeds" '[[ $rc == 0 ]]'
check "install adds the runtime" '[[ -x "$(target)/prism/llama-server" ]] && index_has_engine'
check "install selects the runtime" 'grep -q "$ENGINE@2.67.0" "$LMS_HOME/.internal/backend-preferences-v2.json"'
check "install restarts daemon and server" 'daemon_up && [[ -e "$LMS_HOME/stub/server" ]]'
check "install leaves no temporary directories" no_leftovers
check "the daemon sees no hidden backend directories" no_hidden_backends
check "the daemon does not inherit the lock" lock_free

snapshot before
STUB_FAIL=select "$SCRIPT" uninstall > "$ROOT/log" 2>&1; rc=$?
check "failed uninstall reports an error" '[[ $rc != 0 ]]'
check "failed uninstall restores the state" unchanged
check "failed uninstall restarts the daemon" daemon_up
check "failed uninstall leaves no temporary directories" no_leftovers

"$SCRIPT" uninstall > "$ROOT/log" 2>&1; rc=$?
check "uninstall succeeds" '[[ $rc == 0 ]]'
check "uninstall removes the runtime" '[[ ! -e "$(target)" ]] && ! index_has_engine'
check "uninstall selects the official runtime" 'grep -q "$OFFICIAL@2.66.0" "$LMS_HOME/.internal/backend-preferences-v2.json"'
check "uninstall leaves no temporary directories" no_leftovers
check "uninstall hides the old runtime from the daemon" no_hidden_backends

setup
"$SCRIPT" uninstall > "$ROOT/log" 2>&1; rc=$?
check "uninstall without an install is a no-op" '[[ $rc == 0 && ! -e "$LMS_HOME/stub/calls" ]]'

for fault in select daemon_up corrupt_on_down; do
    setup
    snapshot before
    STUB_FAIL=$fault "$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
    check "$fault: install reports an error" '[[ $rc != 0 ]]'
    check "$fault: state is restored" unchanged
    check "$fault: daemon is running" daemon_up
    check "$fault: no temporary directories remain" no_leftovers
done

setup
echo broken > "$LMS_HOME/.internal/internal-engine-index.json"
snapshot before
"$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
check "broken index stops the install early" '[[ $rc != 0 ]] && unchanged && [[ ! -e "$LMS_HOME/stub/calls" ]]'

setup
sed -i "s/\"name\":\"$OFFICIAL\"/\"name\":\"other\"/" "$LMS_HOME/.internal/internal-engine-index.json"
snapshot before
"$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
check "missing index entry stops the install early" '[[ $rc != 0 ]] && unchanged && [[ ! -e "$LMS_HOME/stub/calls" ]]'

setup
snapshot before
STUB_LOADED=1 "$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
check "loaded model stops the install" '[[ $rc != 0 ]] && unchanged && never_stopped'
STUB_LOADED=1 "$SCRIPT" install --force > "$ROOT/log" 2>&1; rc=$?
check "--force overrides a loaded model" '[[ $rc == 0 ]] && index_has_engine'

setup
snapshot before
mkdir "$LMS_HOME/extensions/.$ENGINE.staging"
exec 8>"$LMS_HOME/.internal/.prism-installer.lock"
flock 8
"$SCRIPT" install > "$ROOT/log" 2>&1; rc=$?
exec 8>&-
check "a second run is refused" '[[ $rc != 0 ]] && unchanged && grep -q "another run" "$ROOT/log"'
check "a second run keeps the staging directory of the active run" '[[ -d "$LMS_HOME/extensions/.$ENGINE.staging" ]]'

echo "Test data: $ROOT"
if [[ "$failures" != 0 ]]; then echo "$failures test(s) failed."; exit 1; fi
echo "All install-linux-llmster tests passed."
