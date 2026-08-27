#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-ai-cli-caches.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]] || {
        echo "FATAL: HOME is not a test temp dir: $HOME"
        exit 1
    }
    rm -rf "$HOME/.codex" "$HOME/.gemini" "$HOME/.claude"
}

assert_run_success() {
    [ "$status" -eq 0 ] || {
        echo "expected status 0, got $status"
        echo "$output"
        return 1
    }
}

assert_output_contains() {
    local expected="$1"
    [[ "$output" == *"$expected"* ]] || {
        echo "expected output to contain: $expected"
        echo "$output"
        return 1
    }
}

assert_output_not_contains() {
    local unexpected="$1"
    [[ "$output" != *"$unexpected"* ]] || {
        echo "expected output not to contain: $unexpected"
        echo "$output"
        return 1
    }
}

@test "clean_codex_cli skips codex state by default" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log" "$HOME/.codex/sessions"
    mkdir -p "$HOME/.codex/cache/codex_app_directory"
    touch "$HOME/.codex/cache/c.bin" "$HOME/.codex/cache/session_index.jsonl"
    touch "$HOME/.codex/cache/codex_app_directory/index.json" "$HOME/.codex/.tmp/t.bin" "$HOME/.codex/log/codex-tui.log"
    touch "$HOME/.codex/sessions/s.jsonl" "$HOME/.codex/auth.json" "$HOME/.codex/history.jsonl"
    touch "$HOME/.codex/state_5.sqlite" "$HOME/.codex/logs_2.sqlite" "$HOME/.codex/session_index.jsonl"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
    [ -f "$HOME/.codex/cache/session_index.jsonl" ]
    [ -f "$HOME/.codex/cache/codex_app_directory/index.json" ]
    [ -f "$HOME/.codex/.tmp/t.bin" ]
    [ -f "$HOME/.codex/log/codex-tui.log" ]
    [ -f "$HOME/.codex/sessions/s.jsonl" ]
    [ -f "$HOME/.codex/state_5.sqlite" ]
    [ -f "$HOME/.codex/logs_2.sqlite" ]
}

@test "clean_codex_cli is a no-op when ~/.codex is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_cli reports running Codex without cleaning state" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log"
    touch "$HOME/.codex/cache/c.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 0; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_antigravity_caches cleans antigravity browser caches" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Code Cache" "$ag/Default/GPUCache"
    mkdir -p "$ag/Default/DawnGraphiteCache" "$ag/Default/DawnWebGPUCache"
    mkdir -p "$ag/GraphiteDawnCache" "$ag/component_crx_cache" "$ag/extensions_crx_cache"
    mkdir -p "$ag/Default/Extensions" "$ag/Default/Storage"
    touch "$ag/Default/Cache/a.bin" "$ag/Default/Code Cache/b.bin" "$ag/Default/GPUCache/c.bin"
    touch "$ag/Default/DawnGraphiteCache/d.bin" "$ag/Default/DawnWebGPUCache/e.bin"
    touch "$ag/GraphiteDawnCache/f.bin" "$ag/component_crx_cache/g.bin" "$ag/extensions_crx_cache/h.bin"
    touch "$ag/Default/Extensions/x.js" "$ag/Default/Storage/y.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Antigravity browser cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity code cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity GPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Dawn cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity WebGPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Graphite cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity extension cache|"
    assert_output_contains "SWC:Antigravity"
    assert_output_not_contains "Default/Extensions"
    assert_output_not_contains "Default/Storage"
}

@test "clean_antigravity_caches is a no-op when the profile is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:Antigravity"
    assert_output_not_contains "SWC:"
}

@test "clean_antigravity_caches ignores an empty active profile" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Service Worker/CacheStorage"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }
clean_service_worker_cache() { echo "UNEXPECTED_SWC"; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_CLEAN"
    assert_output_not_contains "UNEXPECTED_SWC"
    assert_output_not_contains "process state unknown"
}

@test "clean_antigravity_caches recognizes root-level cache candidates" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/component_crx_cache"
    touch "$ag/component_crx_cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|$ag/component_crx_cache/candidate"
}

@test "clean_antigravity_caches never touches gemini tmp chat checkpoints" {
    mkdir -p "$HOME/.gemini/tmp"
    touch "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
    [[ -f "$HOME/.gemini/tmp/work.bin" ]]
}

@test "clean_antigravity_caches skips browser profile and gemini tmp while running" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$HOME/.gemini/tmp"
    touch "$ag/Default/Cache/a.bin" "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { echo "NOTE_ACTIVITY"; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "gemini" ]]
}
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "Antigravity/Gemini caches · skipped"
    assert_output_not_contains "NOTE_ACTIVITY"
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
}

@test "clean_dev_misc invokes Codex and Antigravity cleanup helpers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { :; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_codex_runtimes() { :; }
note_activity() { :; }
clean_codex_cli() { echo "CODEX_CLI_CALLED"; }
clean_antigravity_caches() { echo "ANTIGRAVITY_CALLED"; }
clean_dev_misc
EOF

    assert_run_success
    assert_output_contains "CODEX_CLI_CALLED"
    assert_output_contains "ANTIGRAVITY_CALLED"
}

@test "versioned agent retention preserves newline-containing pathnames" {
    local isolated_home="$HOME/agent-newline-path"
    local versions_root="$isolated_home/versions"
    local newline_version=$'2.0\njunk'
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$versions_root/$newline_version"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604300000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    touch -t 202604100000 "$versions_root/$newline_version"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

root="$HOME/versions"
newline_version=$'2.0\njunk'
_plan_versioned_agent_cleanup_targets "$root" 1 "$root/3.0"
[[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -eq 2 ]] || exit 1
found_old=false
found_newline=false
for target in "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}"; do
    [[ "$target" != "$root/2.0" ]] || { echo "WRONG_PLANNED_KEEP:$target"; exit 1; }
    [[ "$target" == "$root/1.0" ]] && found_old=true
    [[ "$target" == "$root/$newline_version" ]] && found_newline=true
done
[[ "$found_old" == "true" && "$found_newline" == "true" ]]
EOF

    assert_run_success
    assert_output_not_contains "WRONG_PLANNED_KEEP"
}

@test "versioned agent cleanup discards a partial inventory when find fails" {
    local isolated_home="$HOME/agent-partial-inventory"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$fake_bin"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
root="$1"
printf '%s\0' "$root/1.0" "$root/2.0" "$root/3.0"
exit 73
EOF
    chmod +x "$fake_bin/find"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "UNEXPECTED_DELETE:$1"; }
set +e
clean_versioned_agent_root "$HOME/versions" "Agent old version" 1
rc=$?
set -e
printf 'SCAN_RC:%s\n' "$rc"
[[ $rc -eq 73 ]]
EOF

    assert_run_success
    assert_output_contains "SCAN_RC:73"
    assert_output_not_contains "UNEXPECTED_DELETE"
}

@test "versioned agent delete guard rejects repeated partial active inventories" {
    local isolated_home="$HOME/agent-partial-active-inventory"
    local versions_root="$isolated_home/versions"
    local bin_dir="$isolated_home/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/agent" "$versions_root/2.0/agent" "$versions_root/3.0/agent"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/agent" "$bin_dir/agent"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
root="$HOME/versions"
scan_count=0
_materialize_versioned_agent_entries() {
    local versions_root="$1"
    local output_file="$2"
    scan_count=$((scan_count + 1))
    if [[ $scan_count -eq 1 || $scan_count -eq 3 ]]; then
        printf '%s\0' "$versions_root/1.0" "$versions_root/2.0" > "$output_file"
        return 73
    fi
    command find "$versions_root" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -print0 > "$output_file"
}
_MOLE_VERSIONED_AGENT_GUARD_ROOT="$root"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK="$HOME/bin/agent"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
_MOLE_VERSIONED_AGENT_GUARD_KEEP=1
set +e
_versioned_agent_delete_guard_allows "$root/1.0"
rc=$?
set -e
printf 'GUARD_RC:%s\n' "$rc"
[[ $rc -eq 73 ]]
EOF

    assert_run_success
    assert_output_contains "GUARD_RC:73"
}

@test "versioned agent inventory has a wall-clock timeout" {
    local isolated_home="$HOME/agent-inventory-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
for arg do
    [[ "$arg" == */versions ]] || continue
    sleep 30
    exit
done
exec /usr/bin/find "$@"
EOF
    chmod +x "$fake_bin/find"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'INVENTORY_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "INVENTORY_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent stat probes share the inventory deadline" {
    local isolated_home="$HOME/agent-stat-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/stat" <<'EOF'
#!/bin/bash
sleep 30
EOF
    chmod +x "$fake_bin/stat"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'STAT_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "STAT_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent cleanup rechecks the active symlink after sizing" {
    local isolated_home="$HOME/agent-active-symlink-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"

get_cleanup_path_size_kb() {
    rm -f "$HOME/.local/bin/claude"
    ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (retention changed)"
}

@test "versioned agent cleanup rechecks the active symlink after retention planning" {
    local isolated_home="$HOME/agent-active-plan-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
get_cleanup_path_size_kb() {
    : > "$HOME/arm-active-plan-race"
    echo 1
}
_versioned_agent_entry_mtime() {
    if [[ -e "$HOME/arm-active-plan-race" && ! -e "$HOME/flipped-active-plan-race" ]]; then
        : > "$HOME/flipped-active-plan-race"
        rm -f "$HOME/.local/bin/claude"
        ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    fi
    command stat "${_MOLE_STAT_MTIME_FLAG}" "$1"
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (active version changed)"
}

@test "clean_codex_marketplace_staging removes only aged staging prefixes (#1389)" {
    local tmp="$HOME/.codex/.tmp"
    local bundled="$tmp/bundled-marketplaces"
    local staging="$tmp/marketplaces/.staging"
    mkdir -p "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$bundled/openai-bundled.staging-fresh" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    touch "$bundled/openai-bundled/KEEP" \
        "$bundled/openai-bundled.staging-old/GONE" \
        "$bundled/openai-bundled.staging-fresh/KEEP" \
        "$tmp/marketplaces/my-marketplace/KEEP" \
        "$staging/marketplace-upgrade-old/GONE" \
        "$staging/marketplace-add-old/GONE" \
        "$staging/marketplace-backup-old/KEEP"
    touch -t 202001010000 \
        "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    # Fresh staging must stay (age gate).
    touch "$bundled/openai-bundled.staging-fresh"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
# The staging cleanup has no engine-absent fallback (see the audited-count
# gate in clean_core.bats), so a standalone case supplies the guard itself.
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    safe_clean "$@"
}
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$bundled/openai-bundled.staging-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-upgrade-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-add-old"* ]] || return 1
    [[ "$output" != *"openai-bundled|"* ]] || return 1
    [[ "$output" != *"openai-bundled.staging-fresh"* ]] || return 1
    [[ "$output" != *"my-marketplace"* ]] || return 1
    [[ "$output" != *"marketplace-backup-old"* ]] || return 1
}

@test "clean_codex_marketplace_staging defers while Codex runtime is active" {
    local staging="$HOME/.codex/.tmp/marketplaces/.staging"
    mkdir -p "$staging/marketplace-upgrade-old"
    touch "$staging/marketplace-upgrade-old/payload"
    touch -t 202001010000 "$staging/marketplace-upgrade-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() {
    if [[ "$*" == *codex* ]]; then
        return 0
    fi
    return 1
}
lsof() { return 1; }
safe_clean() { echo "UNEXPECTED:$1"; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED:"* ]] || return 1
    [[ -f "$staging/marketplace-upgrade-old/payload" ]]
}
