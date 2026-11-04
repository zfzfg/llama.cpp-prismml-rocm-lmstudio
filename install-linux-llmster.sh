#!/usr/bin/env bash
# Registers PrismML llama.cpp Vulkan as an extra llmster runtime on Linux.
# This uses undocumented llmster internals and is experimental.
#
#   ./install-linux-llmster.sh install     install and select the runtime
#   ./install-linux-llmster.sh uninstall   remove it and select the official Vulkan runtime
#
# Both stop the daemon, which unloads models, so they refuse to run while a model
# is loaded. Pass --force to run anyway. A failure restores the previous state.
set -euo pipefail

TAG="prism-b12128-d7b2896"
ASSET="llama-prism-b12128-d7b2896-bin-ubuntu-vulkan-x64.tar.gz"
SHA256="a73a76f26b161e2fff3815cc3ae6f1daeee5991e1269982561aa620e8e07cca4"
ENGINE="llama.cpp-linux-x86_64-prism-vulkan-b12128"
VERSION="2.67.0"
OFFICIAL="llama.cpp-linux-x86_64-vulkan-avx2"

LMS_HOME="${LMS_HOME:-$HOME/.lmstudio}"
LMS="$LMS_HOME/bin/lms"
BACKENDS="$LMS_HOME/extensions/backends"
INTERNAL="$LMS_HOME/.internal"
TARGET="$BACKENDS/$ENGINE-$VERSION"
# The daemon registers every directory in backends, hidden ones too, so these stay outside it.
STAGE="$LMS_HOME/extensions/.$ENGINE.staging"
REMOVING="$LMS_HOME/extensions/.$ENGINE.removing"
STATE_FILES=(internal-engine-index.json backend-preferences-v2.json)
FORCE=0

die() { echo "error: $*" >&2; exit 1; }

# The daemon outlives this script, and an inherited lock descriptor would hold the lock forever.
run_lms() { "$LMS" "$@" 9>&-; }

find_official() {
    # Version sort picks the newest installed official runtime.
    local found
    [[ -d "$BACKENDS" ]] || die "$BACKENDS not found"
    found="$(find "$BACKENDS" -maxdepth 1 -type d -name "$OFFICIAL-*" | sort -V | tail -n 1)"
    [[ -n "$found" ]] || die "official runtime $OFFICIAL not found, run: lms runtime get"
    echo "$found"
}

# The daemon restart stops the API server, so it is started again if it was running.
SERVER_WAS_RUNNING=0
stop_daemon() {
    local status
    status="$(run_lms server status 2>&1 || true)"
    if [[ "$status" == *"is running"* ]]; then SERVER_WAS_RUNNING=1; fi
    run_lms daemon down >/dev/null 2>&1 || true
    sleep 2
}
start_daemon() {
    run_lms daemon up >/dev/null
    sleep 3
    if [[ "$SERVER_WAS_RUNNING" == 1 ]]; then run_lms server start >/dev/null; fi
}

preflight() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "this runtime needs Linux on x86_64"
    [[ "$(id -u)" != 0 ]] || die "run this as the user who owns llmster, not as root"
    local tool
    for tool in python3 curl tar sha256sum flock timeout; do
        command -v "$tool" >/dev/null || die "$tool is required"
    done
    [[ -x "$LMS" ]] || die "lms not found at $LMS"
    [[ -d "$INTERNAL" ]] || die "$INTERNAL not found, start llmster once first"
    exec 9>"$INTERNAL/.prism-installer.lock"
    flock -n 9 || die "another run of this installer is active"
    LOCK_HELD=1
}

require_idle() {
    # Anything but the known empty message counts as loaded, so a changed message stops the run.
    local models
    models="$(run_lms ps 2>&1 || true)"
    [[ "$FORCE" == 1 || "$models" == *"No models are currently loaded"* ]] \
        || die "stopping the daemon would unload running models, unload them or pass --force"
}

check_index() {
    python3 -I - "$INTERNAL/internal-engine-index.json" "$OFFICIAL" <<'PY' || die "the engine index cannot be updated, nothing was changed"
import json, sys
path, official = sys.argv[1:]
entries = json.load(open(path))["json"]
entry = next((e for e in entries if e["manifest"]["name"] == official), None)
if entry is None:
    sys.exit(f"{official} is not in {path}")
for key in ("libLmStudioPath", "launchInfo", "dirPath"):
    if key not in entry:
        sys.exit(f"{official} has no {key} in {path}")
PY
}

# Rollback state. ROLLBACK_ACTION stays empty until the first change to llmster.
LOCK_HELD=0
WORK=""
ROLLBACK_ACTION=""
TARGET_MOVED=0

snapshot_state() {
    mkdir "$WORK/state"
    local file
    for file in "${STATE_FILES[@]}"; do
        if [[ -e "$INTERNAL/$file" ]]; then cp -p "$INTERNAL/$file" "$WORK/state/$file"; fi
    done
}

rollback() {
    echo "error: restoring the previous state" >&2
    run_lms daemon down >/dev/null 2>&1
    sleep 2
    if [[ "$ROLLBACK_ACTION" == install && "$TARGET_MOVED" == 1 ]]; then rm -rf "$TARGET"; fi
    if [[ "$ROLLBACK_ACTION" == uninstall && "$TARGET_MOVED" == 1 ]]; then mv "$REMOVING" "$TARGET"; fi
    local file
    for file in "${STATE_FILES[@]}"; do
        if [[ -e "$WORK/state/$file" ]]; then
            cp -p "$WORK/state/$file" "$INTERNAL/$file"
        else
            rm -f "$INTERNAL/$file"
        fi
    done
    start_daemon || echo "error: the daemon did not start, run: lms daemon up" >&2
}

on_exit() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ "$status" != 0 && -n "$ROLLBACK_ACTION" ]]; then rollback; fi
    # A refused second run must not touch the staging directory of the active run.
    if [[ "$LOCK_HELD" == 1 ]]; then rm -rf "$STAGE"; fi
    if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
    exit "$status"
}

update_index() {
    # The index is superjson encoded. meta.values keys start with the entry position
    # and LM Studio rejects the file when they do not line up.
    python3 -I - "$1" "$INTERNAL/internal-engine-index.json" "$ENGINE" "$OFFICIAL" "$TARGET" <<'PY'
import json, os, sys
action, path, engine, official, target = sys.argv[1:]
data = json.load(open(path))
entries = data["json"]
values = data["meta"]["values"]
meta = [{k.split(".", 1)[1]: v for k, v in values.items() if k.split(".", 1)[0] == str(i)} for i in range(len(entries))]
keep = [i for i, e in enumerate(entries) if e["manifest"]["name"] != engine]
new_entries = [entries[i] for i in keep]
new_meta = [meta[i] for i in keep]
if action == "add":
    source = next(i for i in keep if entries[i]["manifest"]["name"] == official)
    entry = json.loads(json.dumps(entries[source]))
    entry["dirPath"] = target
    entry["libLmStudioPath"] = os.path.join(target, os.path.basename(entry["libLmStudioPath"]))
    entry["launchInfo"]["engineLibPath"] = os.path.join(target, os.path.basename(entry["launchInfo"]["engineLibPath"]))
    entry["manifest"] = json.load(open(os.path.join(target, "backend-manifest.json")))
    entry["displayData"] = json.load(open(os.path.join(target, "display-data.json")))
    new_entries.append(entry)
    new_meta.append(meta[source])
data["json"] = new_entries
kept = {k: v for k, v in values.items() if not k.split(".", 1)[0].isdigit()}
for i, item in enumerate(new_meta):
    for key, value in item.items():
        kept[f"{i}.{key}"] = value
data["meta"]["values"] = kept
with open(path + ".tmp", "w") as out:
    json.dump(data, out)
os.replace(path + ".tmp", path)
PY
}

write_metadata() {
    # The official libraries stay beside the adapter because libllm_engine.so links them.
    # PrismML lives in prism/ and finds its own libraries through RUNPATH $ORIGIN.
    python3 -I - "$1" "$ENGINE" "$VERSION" <<'PY'
import json, os, sys
stage, engine, version = sys.argv[1:]
manifest_path = os.path.join(stage, "backend-manifest.json")
manifest = json.load(open(manifest_path))
manifest["name"] = engine
manifest["version"] = version
manifest["engine_protocol_server"]["executable_relative_path"] = "prism/llama-server"
json.dump(manifest, open(manifest_path, "w"), indent=2)
files = []
for root, _, names in os.walk(os.path.join(stage, "prism")):
    for name in names:
        if name == "llama-server" or ".so" in name:
            files.append({"relative_path": os.path.relpath(os.path.join(root, name), stage), "executable": name == "llama-server"})
files.sort(key=lambda item: item["relative_path"])
json.dump({"schema_version": 1, "runtime_kind": "llama-server", "executable_relative_path": "prism/llama-server", "files": files},
          open(os.path.join(stage, "engine-protocol-server-artifacts.json"), "w"), indent=2)
display = [["en", {"langKey": "en", "displayName": "Prism ML b12128 Vulkan llama.cpp (Linux)", "description": "PrismML llama.cpp over Vulkan. Experimental.", "releaseNotes": []}]]
json.dump(display, open(os.path.join(stage, "display-data.json"), "w"), indent=2)
PY
}

install_runtime() {
    [[ ! -e "$TARGET" ]] || die "$TARGET already exists, run uninstall first"
    local official help file
    official="$(find_official)"
    check_index
    require_idle
    WORK="$(mktemp -d)"

    curl --proto '=https' --tlsv1.2 --retry 3 -fsSL -o "$WORK/$ASSET" "https://github.com/PrismML-Eng/llama.cpp/releases/download/$TAG/$ASSET"
    echo "$SHA256  $WORK/$ASSET" | sha256sum -c --quiet
    mkdir "$WORK/x"
    tar -xzf "$WORK/$ASSET" -C "$WORK/x"

    rm -rf "$STAGE"
    mkdir "$STAGE"
    find "$official" -maxdepth 1 -type f ! -name llama-server -exec cp -p {} "$STAGE/" \;
    mv "$WORK/x/llama-prism-b12128-d7b2896" "$STAGE/prism"
    write_metadata "$STAGE"

    timeout 20 "$STAGE/prism/llama-server" --version >/dev/null 2>&1 || die "staged llama-server does not start"
    help="$(timeout 20 "$STAGE/prism/llama-server" --help 2>/dev/null || true)"
    [[ "$help" == *"--lazy-mode"* ]] || die "staged llama-server lacks --lazy-mode"

    snapshot_state
    ROLLBACK_ACTION=install
    stop_daemon
    for file in "${STATE_FILES[@]}"; do
        [[ -e "$INTERNAL/$file.bak-prism-original" ]] || cp -p "$INTERNAL/$file" "$INTERNAL/$file.bak-prism-original"
    done
    mv "$STAGE" "$TARGET"
    TARGET_MOVED=1
    update_index add
    start_daemon
    run_lms runtime select "$ENGINE@$VERSION"
    ROLLBACK_ACTION=""
    run_lms runtime ls
}

uninstall_runtime() {
    local registered official
    registered="$(python3 -I - "$INTERNAL/internal-engine-index.json" "$ENGINE" <<'PY'
import json, sys
print(any(e["manifest"]["name"] == sys.argv[2] for e in json.load(open(sys.argv[1]))["json"]))
PY
)"
    if [[ ! -e "$TARGET" && "$registered" == False ]]; then
        echo "$ENGINE is not installed, nothing to do"
        return
    fi
    official="$(find_official)"
    check_index
    require_idle
    WORK="$(mktemp -d)"

    snapshot_state
    ROLLBACK_ACTION=uninstall
    stop_daemon
    if [[ -e "$TARGET" ]]; then
        rm -rf "$REMOVING"
        mv "$TARGET" "$REMOVING"
        TARGET_MOVED=1
    fi
    update_index remove
    start_daemon
    run_lms runtime select "$OFFICIAL@${official##*-}"
    ROLLBACK_ACTION=""
    rm -rf "$REMOVING"
    run_lms runtime ls
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${2:-}" == --force ]]; then
    FORCE=1
elif [[ -n "${2:-}" ]]; then
    echo "usage: $0 install|uninstall [--force]" >&2
    exit 2
fi

case "${1:-}" in
    install) preflight; install_runtime ;;
    uninstall) preflight; uninstall_runtime ;;
    *) echo "usage: $0 install|uninstall [--force]" >&2; exit 2 ;;
esac
