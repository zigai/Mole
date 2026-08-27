#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-caches.XXXXXX")"
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

make_gh_cache_stub() {
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/gh" <<'SCRIPT'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_TRACE"
if [[ "${GH_TRACE_CACHE_ROOT:-0}" == "1" ]]; then
    printf 'ROOT:%s\n' "${XDG_CACHE_HOME:-<unset>}" >> "$GH_TRACE"
fi
if [[ "$*" == "config clear-cache --help" ]]; then
    if [[ -n "${GH_SWAP_LINK:-}" && -n "${GH_SWAP_TARGET:-}" ]]; then
        /bin/unlink "$GH_SWAP_LINK"
        /bin/ln -s "$GH_SWAP_TARGET" "$GH_SWAP_LINK"
    fi
    if [[ -n "${GH_REPLACE_ROOT:-}" && -n "${GH_REPLACE_TARGET:-}" ]]; then
        /bin/mv "$GH_REPLACE_ROOT" "$GH_REPLACE_ROOT-old"
        /bin/ln -s "$GH_REPLACE_TARGET" "$GH_REPLACE_ROOT"
    fi
    exit "${GH_HELP_RC:-0}"
fi
if [[ "$*" == "config clear-cache" ]]; then
    exit "${GH_CLEAR_RC:-0}"
fi
exit 2
SCRIPT
    chmod +x "$HOME/bin/gh"
}

@test "clean_github_cli_cache uses gh owner command for the default cache" {
    local trace="$HOME/gh-default.trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2
    printf 'CACHE:%s|%s\n' "$description" "$cache_path"
    "$@"
}
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    [ "$(grep -cFx 'config clear-cache' "$trace")" -eq 1 ] || return 1
}

@test "clean_github_cli_cache dry-run never invokes the mutating command" {
    local trace="$HOME/gh-dry-run.trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=true
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · would clean"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
}

@test "clean_github_cli_cache honors custom XDG cache whitelists" {
    local trace="$HOME/gh-xdg-whitelist.trace"
    local xdg_cache="$HOME/custom-cache"
    mkdir -p "$xdg_cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { [[ "$1" == "$XDG_CACHE_HOME/gh" ]]; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · skipped (whitelist)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache honors the physical target of a symlinked XDG root" {
    local trace="$HOME/gh-xdg-symlink.trace"
    local physical_cache="$HOME/physical-cache"
    mkdir -p "$physical_cache/gh"
    ln -s "$physical_cache" "$HOME/xdg-cache"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$HOME/xdg-cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" PHYSICAL_CACHE="$physical_cache/gh" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { [[ "$1" == "$PHYSICAL_CACHE" ]]; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"GitHub CLI cache · skipped (whitelist)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache binds the owner command to the verified physical root" {
    local trace="$HOME/gh-xdg-swap.trace"
    local physical_cache="$HOME/physical-cache"
    local swapped_cache="$HOME/swapped-cache"
    local xdg_link="$HOME/xdg-cache"
    rm -rf "$physical_cache" "$swapped_cache" "$xdg_link"
    mkdir -p "$physical_cache/gh" "$swapped_cache/gh"
    ln -s "$physical_cache" "$xdg_link"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$xdg_link" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" GH_TRACE_CACHE_ROOT=1 \
        GH_SWAP_LINK="$xdg_link" GH_SWAP_TARGET="$swapped_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx "ROOT:$physical_cache" "$trace")" -eq 2 ] || return 1
    run grep -qFx "ROOT:$swapped_cache" "$trace"
    [ "$status" -eq 1 ] || return 1
    local link_target
    link_target=$(readlink "$xdg_link" 2> /dev/null || true)
    [ "$link_target" = "$swapped_cache" ] || {
        printf 'expected swapped link %s, got %s\n' "$swapped_cache" "${link_target:-<missing>}"
        return 1
    }
}

@test "clean_github_cli_cache rejects a replaced physical root at the owner command" {
    local trace="$HOME/gh-physical-root-swap.trace"
    local physical_cache="$HOME/replaceable-cache"
    local swapped_cache="$HOME/replacement-cache"
    rm -rf "$physical_cache" "$physical_cache-old" "$swapped_cache"
    mkdir -p "$physical_cache/gh" "$swapped_cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="$physical_cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" \
        GH_REPLACE_ROOT="$physical_cache" GH_REPLACE_TARGET="$swapped_cache" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
    [ -L "$physical_cache" ] || return 1
    [ -d "$swapped_cache/gh" ] || return 1
}

@test "clean_github_cli_cache refuses when gh starts at the owner command boundary" {
    local trace="$HOME/gh-process-race.trace"
    rm -rf "$HOME/.cache/gh"
    rm -f "$trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
mole_defer_cleanup_family() { printf 'DEFER:%s\n' "$1"; }
pgrep_calls=0
pgrep() {
    pgrep_calls=$((pgrep_calls + 1))
    [[ $pgrep_calls -ge 2 ]]
}
clean_github_cli_cache
printf 'PGREP_CALLS=%s\n' "$pgrep_calls"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"DEFER:GitHub CLI"* ]] || return 1
    [[ "$output" == *"PGREP_CALLS=2"* ]] || return 1
    [ "$(grep -cFx 'config clear-cache --help' "$trace")" -eq 1 ] || return 1
    run grep -qFx 'config clear-cache' "$trace"
    [ "$status" -eq 1 ] || return 1
}

@test "clean_github_cli_cache preserves a symlinked cache leaf" {
    local trace="$HOME/gh-leaf-symlink.trace"
    local cache_target="$HOME/relocated-gh-cache"
    rm -rf "$HOME/.cache/gh" "$cache_target"
    mkdir -p "$HOME/.cache" "$cache_target"
    ln -s "$cache_target" "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
debug_log() { printf 'DEBUG:%s\n' "$*"; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cache leaf is not a real directory"* ]] || return 1
    [ -L "$HOME/.cache/gh" ] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_github_cli_cache rejects unsafe XDG paths before probing gh" {
    local trace="$HOME/gh-invalid-xdg.trace"
    make_gh_cache_stub

    run env HOME="$HOME" XDG_CACHE_HOME="relative/cache" PATH="$HOME/bin:/usr/bin:/bin" \
        PROJECT_ROOT="$PROJECT_ROOT" GH_TRACE="$trace" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
debug_log() { printf 'DEBUG:%s\n' "$*" >&2; }
clean_github_cli_cache
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"unsafe XDG_CACHE_HOME"* ]] || return 1
    [ ! -e "$trace" ] || return 1
}

@test "clean_dev_cloud continues when gh cache clearing fails" {
    local trace="$HOME/gh-failure.trace"
    rm -rf "$HOME/.cache/gh"
    rm -f "$trace"
    mkdir -p "$HOME/.cache/gh"
    make_gh_cache_stub

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        GH_TRACE="$trace" GH_CLEAR_RC=2 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf 'SAFE:%s\n' "$2"; }
clean_dev_cloud
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -cFx 'config clear-cache' "$trace")" -eq 1 ] || return 1
    [[ "$output" == *"GitHub CLI cache · stopped (owner cleanup failed)"* ]] || return 1
    [[ "$output" == *"SAFE:AWS CLI cache"* ]] || return 1
    [[ "$output" == *"SAFE:Google Cloud logs"* ]] || return 1
}

@test "clean_dev_cloud stops on GitHub CLI probe or clear cancellation" {
    local failure_phase failure_rc
    for failure_phase in help clear; do
        for failure_rc in 124 130; do
            local trace="$HOME/gh-$failure_phase-$failure_rc.trace"
            local help_rc=0
            local clear_rc=0
            if [[ "$failure_phase" == "help" ]]; then
                help_rc="$failure_rc"
            else
                clear_rc="$failure_rc"
            fi
            rm -rf "$HOME/.cache/gh"
            rm -f "$trace"
            mkdir -p "$HOME/.cache/gh"
            make_gh_cache_stub

            run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
                GH_TRACE="$trace" GH_HELP_RC="$help_rc" GH_CLEAR_RC="$clear_rc" \
                MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
                /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { printf 'UNEXPECTED:%s\n' "$2"; }
set +e
_run_developer_cleanup_step clean_dev_cloud
rc=$?
set -e
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
EOF

            [ "$status" -eq 0 ] || { echo "$output"; return 1; }
            [[ "$output" == *"RC=$failure_rc CANCEL=$failure_rc"* ]] || return 1
            [[ "$output" != *"UNEXPECTED:"* ]] || return 1
        done
    done
}

@test "clean_dev_npm prunes pnpm store without deleting orphaned global store" {
    # Real file on PATH so type -P prefers the stub over any host pnpm.
    mkdir -p "$HOME/bin"
    cat > "$HOME/bin/pnpm" <<'SCRIPT'
#!/bin/bash
case "${1:-}" in
    --version) echo "11.0.0"; exit 0 ;;
    store)
        [[ "${2:-}" == "path" ]] && { echo "/tmp/pnpm-store"; exit 0; }
        [[ "${2:-}" == "prune" ]] && exit 0
        ;;
esac
exit 2
SCRIPT
    chmod +x "$HOME/bin/pnpm"

    run env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { echo "$1|$2"; }
safe_clean() { echo "$2"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
pgrep() { return 1; }
npm() { return 0; }
export -f pgrep npm
clean_dev_npm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"pnpm cache|/tmp/pnpm-store"* ]] || return 1
    [[ "$output" != *"Orphaned pnpm store"* ]] || return 1
}

@test "clean_pnpm_stores skips when pnpm is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
debug_log() { printf 'DEBUG:%s\n' "$*"; }
pgrep() { return 0; }
pnpm() { echo "UNEXPECTED"; return 0; }
export -f pgrep pnpm
clean_pnpm_stores
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"skipping store prune"* ]] || return 1
    [[ "$output" != *"UNEXPECTED"* ]] || return 1
}

# Corepack and npm-installed pnpm run as `node .../pnpm.cjs`, so the busy
# guard has to match the invoked program, not the process name. `-x pnpm`
# saw only the standalone binary and let a prune race a live install.
@test "pnpm busy guard sees a corepack pnpm and ignores a lockfile mention" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"

# Stand in for the real process table: pgrep -f matches its pattern against
# each full argv line.
PROCESS_TABLE=""
pgrep() {
    [[ "$1" == "-f" ]] || return 1
    printf '%s\n' "$PROCESS_TABLE" | grep -qE "$2"
}

PROCESS_TABLE="node /Users/x/.cache/node/corepack/v1/pnpm/9.1.0/bin/pnpm.cjs install"
printf 'COREPACK=%s\n' "$(pnpm_process_blocks_prune && echo block || echo allow)"
PROCESS_TABLE="vim /Users/x/project/pnpm-lock.yaml"
printf 'LOCKFILE=%s\n' "$(pnpm_process_blocks_prune && echo block || echo allow)"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"COREPACK=block"* ]] || return 1
    [[ "$output" == *"LOCKFILE=allow"* ]]
}

@test "clean_dev_npm cleans default npm residual directories" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "$HOME/.npm"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm npx cache|$HOME/.npm/_npx/*"* ]] || return 1
    [[ "$output" == *"npm logs|$HOME/.npm/_logs/*"* ]] || return 1
    [[ "$output" == *"npm prebuilds|$HOME/.npm/_prebuilds/*"* ]]
}

@test "clean_dev_jvm never enters daemon cleanup while Gradle is running" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 0; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"SAFE_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle workers"* ]]
}

@test "clean_dev_jvm fails closed for every Gradle target when the process probe errors" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 2; }
safe_clean() { echo "SAFE_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Gradle targets · skipped (process state unknown)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Gradle"* ]] || return 1
}

@test "clean_dev_jvm defers every Gradle target while Gradle is running" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Gradle"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle"* ]] || return 1
}

@test "clean_dev_jvm cleans every Gradle target when idle" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_CLEAN:Gradle build cache|"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Gradle notifications cache|"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:"*".gradle/daemon/8.14"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:"*".gradle/workers/worker-1"* ]] || return 1
    rm -rf "$HOME/.gradle"
}

@test "clean_dev_jvm stops remaining Gradle cleanup when the delete guard refuses" {
    rm -rf "$HOME/.gradle/caches" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
    mkdir -p "$HOME/.gradle/caches/build-cache-1" "$HOME/.gradle/notifications" "$HOME/.gradle/daemon/8.14" "$HOME/.gradle/workers/worker-1"
    touch "$HOME/.gradle/caches/build-cache-1/entry" "$HOME/.gradle/notifications/entry" "$HOME/.gradle/daemon/8.14/entry" "$HOME/.gradle/workers/worker-1/entry"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
gradle_daemon_running() { return 1; }
_dev_process_delete_guard_allows() { return 1; }
defer_cleanup_family() { echo "DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Gradle"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle"* ]] || return 1
    rm -rf "$HOME/.gradle"
}

@test "clean_dev_jvm ignores empty Gradle daemon roots while active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -rf "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
mkdir -p "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:${!#}"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle daemon"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN:Gradle workers"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_dev_jvm ignores active whitelist-only Gradle daemon entries" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
rm -rf "$HOME/.gradle/daemon" "$HOME/.gradle/workers"
mkdir -p "$HOME/.gradle/daemon"
target="$HOME/.gradle/daemon/whitelisted"
touch "$target"
is_path_whitelisted() { [[ "$1" == "$target" ]]; }
gradle_daemon_running() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { :; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER:Gradle"* ]]
}

@test "clean_conda_metadata_caches honors package cache whitelist before conda clean" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
WHITELIST_PATTERNS=("$HOME/anaconda3/pkgs")
conda() { echo "conda called"; return 0; }
export -f conda
clean_conda_metadata_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"conda index/tarball/log caches · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"conda called"* ]]
}

@test "clean_dev_npm cleans custom npm cache path when detected" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "/tmp/mole-custom-npm-cache"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm cache directory (custom path)|/tmp/mole-custom-npm-cache/_cacache/*"* ]] || return 1
    [[ "$output" == *"npm npx cache (custom path)|/tmp/mole-custom-npm-cache/_npx/*"* ]] || return 1
    [[ "$output" == *"npm logs (custom path)|/tmp/mole-custom-npm-cache/_logs/*"* ]] || return 1
    [[ "$output" == *"npm prebuilds (custom path)|/tmp/mole-custom-npm-cache/_prebuilds/*"* ]]
}

@test "clean_dev_npm falls back to default cache when npm path is invalid" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "relative-cache"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" != *"(custom path)"* ]]
}

@test "clean_dev_npm treats default cache path with trailing slash as same path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() {
    if [[ "$1" == "config" && "$2" == "get" && "$3" == "cache" ]]; then
        echo "$HOME/.npm/"
        return 0
    fi
    return 0
}
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm cache directory|$HOME/.npm/_cacache/*"* ]] || return 1
    [[ "$output" != *"(custom path)"* ]]
}

@test "clean_dev_npm cleans default bun cache when bun is unavailable" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() { return 1; }
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bun cache|$HOME/.bun/install/cache/*"* ]] || return 1
    [[ "$output" != *"bun cache|bun cache bun pm cache rm"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm uses bun cache command for default bun cache path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "$HOME/.bun/install/cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" != *"Bun cache|$HOME/.bun/install/cache/*"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm cleans orphaned default bun cache when custom path is configured" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "/tmp/mole-bun-cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" == *"Orphaned bun cache|$HOME/.bun/install/cache/*"* ]]
}

@test "clean_dev_npm treats default bun cache path with trailing slash as same path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "$HOME/.bun/install/cache/"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"bun cache"* ]] || return 1
    [[ "$output" != *"Orphaned bun cache"* ]]
}

@test "clean_dev_npm falls back to filesystem cleanup when bun cache command fails" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
clean_tool_cache() { :; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
npm() { return 0; }
bun() {
    if [[ "$1" == "--version" ]]; then
        echo "1.2.0"
        return 0
    fi
    if [[ "$1" == "pm" && "$2" == "cache" && "${3:-}" == "rm" ]]; then
        return 1
    fi
    if [[ "$1" == "pm" && "$2" == "cache" ]]; then
        echo "/tmp/mole-bun-cache"
        return 0
    fi
    return 0
}
export -f npm bun
clean_dev_npm
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Bun cache|/tmp/mole-bun-cache/*"* ]] || return 1
    [[ "$output" == *"Orphaned bun cache|$HOME/.bun/install/cache/*"* ]]
}

@test "clean_dev_docker skips daemon-managed cleanup by default" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2"; }
note_activity() { :; }
debug_log() { :; }
docker() { echo "docker called"; return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker unused data · review with docker system df"* ]] || return 1
    [[ "$output" == *"Docker BuildX cache"* ]] || return 1
    [[ "$output" != *"docker called"* ]]
}

@test "clean_dev_docker keeps BuildX cache cleanup" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { echo "$2|$1"; }
note_activity() { :; }
debug_log() { :; }
docker() { return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker BuildX cache|$HOME/.docker/buildx/cache/*"* ]]
}

@test "clean_dev_docker no longer depends on whitelist to avoid prune" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
clean_tool_cache() { echo "$1|$*"; }
safe_clean() { :; }
note_activity() { :; }
debug_log() { :; }
is_path_whitelisted() {
    [[ "$1" == "$HOME/.docker" ]] && return 0
    return 1
}
export -f is_path_whitelisted
docker() { echo "docker called"; return 0; }
export -f docker
clean_dev_docker
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker unused data · review with docker system df"* ]] || return 1
    [[ "$output" != *"whitelisted"* ]] || return 1
    [[ "$output" != *"mo clean --whitelist"* ]] || return 1
    [[ "$output" != *"docker called"* ]]
}

@test "clean_codex_runtimes reports active runtime for manual review" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · manual review (1M)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/codex-primary-runtime"* ]]
}

@test "clean_codex_runtimes cleans only stale incomplete runtime dirs" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin"
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/incomplete-old"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:Codex CLI runtimes|$HOME/.cache/codex-runtimes/codex-primary-runtime"* ]]
}

@test "clean_codex_runtimes skips all runtimes while Codex is running" {
    mkdir -p "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin"
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/runtime.json"
    touch "$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 0; }
is_path_whitelisted() { return 1; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Codex runtimes · skipped"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "clean_codex_runtimes skips incomplete runtimes while lowercase Codex CLI is running" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { [[ "$*" == "-x codex" ]]; }
is_path_whitelisted() { return 1; }
safe_clean() { echo "UNEXPECTED_SAFE_CLEAN:$2|$1"; }
defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SAFE_CLEAN"* ]]
}

@test "clean_codex_runtimes respects whitelist" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { [[ "$1" == "$HOME/.cache/codex-runtimes"* || "$1" == "$HOME/.cache/codex-runtimes/incomplete-old" ]]; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "clean_codex_runtimes respects child runtime whitelist" {
    mkdir -p "$HOME/.cache/codex-runtimes/incomplete-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
is_path_whitelisted() { [[ "$1" == "$HOME/.cache/codex-runtimes/incomplete-old" ]]; }
get_path_size_kb() { echo "1024"; }
bytes_to_human() { echo "1M"; }
note_activity() { :; }
clean_codex_runtimes
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Codex runtimes · manual review"* ]] || return 1
    [[ "$output" == *"Codex runtimes · skipped (whitelist)"* ]] || return 1
    [[ "$output" != *"SAFE_CLEAN:"* ]]
}

@test "staging open-file probe treats lsof exit one with stderr as unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
lsof() { return 1; }
run_with_timeout() {
    echo "lsof: cannot stat test path" >&2
    return 1
}
probe_rc=0
staging_root_has_open_files "$HOME/missing" || probe_rc=$?
[[ $probe_rc -eq 2 ]] || { echo "WRONG_LSOF_RC:$probe_rc"; exit 1; }
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

@test "clean_dev_mise respects MISE_CACHE_DIR and only targets cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MISE_CACHE_DIR="/tmp/mise-cache" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_tool_cache() { :; }
note_activity() { :; }
run_with_timeout() { shift; "$@"; }
clean_dev_mise
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"mise cache|/tmp/mise-cache/*"* ]] || return 1
    [[ "$output" != *".local/share/mise"* ]]
}

@test "clean_dev_other_langs cleans the legacy composer cache path" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"PHP Composer cache (legacy)|"* ]]
}

@test "clean_dev_rust honors CARGO_HOME and RUSTUP_HOME when absolute" {
    # mise and friends relocate cargo/rustup via env; hardcoded ~/.cargo misses
    # the live cache (issue #1378). Scope stays redundant download copies only.
    mkdir -p \
        "$HOME/.local/share/mise/cargo/registry/cache" \
        "$HOME/.local/share/mise/cargo/registry/src" \
        "$HOME/.local/share/mise/cargo/git"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        CARGO_HOME="$HOME/.local/share/mise/cargo" \
        RUSTUP_HOME="$HOME/.local/share/mise/rustup" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Rust cargo cache|$HOME/.local/share/mise/cargo/registry/cache/*"* ]] || return 1
    # registry/src keeps offline builds working after registry/cache is emptied.
    [[ "$output" != *"/registry/src"* ]] || return 1
    # Cargo owns age-aware GC for git checkouts; Mole must not sweep the store.
    [[ "$output" != *"/cargo/git"* ]] || return 1
    [[ "$output" == *"Rustup downloads cache|$HOME/.local/share/mise/rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"/registry/index/"* ]] || return 1
    [[ "$output" != *"/.cargo/"* ]] || return 1
    [[ "$output" != *"/.rustup/"* ]] || return 1
}

@test "clean_dev_rust rejects a registry cache root that escapes CARGO_HOME" {
    cargo_home="$HOME/custom-cargo"
    outside_root="$HOME/outside-registry-cache"
    mkdir -p "$cargo_home/registry" "$outside_root/crate-data"
    ln -s "$outside_root" "$cargo_home/registry/cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" CARGO_HOME="$cargo_home" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
note_activity() { :; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust cargo cache · stopped (cache path leaves CARGO_HOME)"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ -d "$outside_root/crate-data" ]]
}

@test "clean_dev_rust falls back to default homes without env" {
    mkdir -p \
        "$HOME/.cargo/registry/cache" \
        "$HOME/.cargo/registry/src" \
        "$HOME/.cargo/git"

    run env -u CARGO_HOME -u RUSTUP_HOME \
        HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
unset CARGO_HOME RUSTUP_HOME
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Rust cargo cache|$HOME/.cargo/registry/cache/*"* ]] || return 1
    [[ "$output" != *"/registry/src"* ]] || return 1
    [[ "$output" != *"/.cargo/git"* ]] || return 1
    [[ "$output" == *"Rustup downloads cache|$HOME/.rustup/downloads/*"* ]] || return 1
    [[ "$output" != *"/registry/index/"* ]] || return 1
}

@test "clean_dev_rust skips dependency caches while cargo is active" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 0; }
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER=Rust"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ "$output" != *"DELETE=Cargo git cache"* ]] || return 1
    [[ "$output" == *"DELETE=Rustup downloads cache"* ]]
}

@test "clean_dev_rust fails closed when process state is unknown" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 2; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
note_activity() { :; }
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust dependency cache · stopped (process state unknown)"* ]] || return 1
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ "$output" != *"DELETE=Rust crate sources"* ]] || return 1
    [[ "$output" != *"DELETE=Cargo git cache"* ]] || return 1
    [[ "$output" == *"DELETE=Rustup downloads cache"* ]]
}

@test "clean_dev_rust rechecks cargo at the deletion boundary" {
    mkdir -p "$HOME/.cargo/registry/cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
probe_calls=0
rust_build_process_state() {
    probe_calls=$((probe_calls + 1))
    [[ $probe_calls -eq 1 ]] && return 1
    return 0
}
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    safe_clean "$@"
}
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"DEFER=Rust"* ]] || return 1
    [[ "$output" != *"DELETE="* ]]
}

@test "clean_dev_rust rechecks Cargo cache containment at the deletion boundary" {
    cache_root="$HOME/.cargo/registry/cache"
    outside_root="$HOME/outside-rust-cache"
    mkdir -p "$cache_root/crate" "$outside_root/private-data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 0; }
rust_build_process_state() { return 1; }
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
safe_clean() { printf 'DELETE=%s|%s\n' "$2" "$1"; }
safe_clean_guarded() {
    local guard="$1"
    shift
    if [[ "$_MOLE_RUST_CACHE_ROOT" == "$HOME/.cargo/registry/cache" ]]; then
        mv "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/cache-original"
        ln -s "$HOME/outside-rust-cache" "$HOME/.cargo/registry/cache"
    fi
    "$guard" || return 75
    safe_clean "$@"
}
clean_dev_rust
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Rust cargo cache · stopped (process or cache path state unknown)"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"DELETE=Rust cargo cache"* ]] || return 1
    [[ -d "$outside_root/private-data" ]]
}

@test "clean_dev_rust binds each Cargo cache leaf to its checked root" {
    cargo_home="$HOME/bound-cargo"
    cache_root="$cargo_home/registry/cache"
    outside_root="$HOME/outside-rust-cache-after-guard"
    mkdir -p "$cache_root/crate" "$outside_root/crate"
    printf 'inside\n' > "$cache_root/crate/inside-marker"
    printf 'outside\n' > "$outside_root/crate/outside-marker"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
rust_build_process_state() { return 1; }

# Swap the checked Cargo root after the guard returns but before the real
# safe_remove sink performs its final identity comparison.
eval "$(declare -f safe_remove | sed '1s/safe_remove/_real_safe_remove/')"
swapped=0
safe_remove() {
    if [[ $swapped -eq 0 ]]; then
        swapped=1
        mv "$HOME/bound-cargo/registry/cache" "$HOME/bound-cargo/registry/cache-original"
        ln -s "$HOME/outside-rust-cache-after-guard" "$HOME/bound-cargo/registry/cache"
    fi
    _real_safe_remove "$@"
}

clean_rust_dependency_cache_root \
    "$HOME/bound-cargo" \
    "$HOME/bound-cargo/registry/cache" \
    "Rust cargo cache"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -f "$cache_root-original/crate/inside-marker" ]] || return 1
    [[ -f "$outside_root/crate/outside-marker" ]] || return 1
    [[ "$output" != *"Rust cargo cache ·"* ]]
}

@test "resolve_tool_home rejects relative and traversal env values" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
fail=0
expect() {
    local got
    got=$(resolve_tool_home "$1" "$HOME/.cargo")
    if [[ "$got" != "$2" ]]; then
        printf 'UNEXPECTED: env=%q got=%q want=%q\n' "$1" "$got" "$2"
        fail=1
    fi
}
expect "" "$HOME/.cargo"
expect "$HOME/.local/share/mise/cargo" "$HOME/.local/share/mise/cargo"
expect "relative/cargo" "$HOME/.cargo"
expect "$HOME/../evil" "$HOME/.cargo"
expect "/tmp/foo/../bar" "$HOME/.cargo"
exit $fail
EOF

    [ "$status" -eq 0 ]
}

@test "clean_developer_tools runs key stages" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/clean/dev.sh"
stop_section_spinner() { :; }
clean_dev_npm() { echo "npm"; }
clean_project_caches() { :; }
clean_dev_python() { :; }
clean_dev_go() { :; }
clean_dev_mise() { echo "mise"; }
clean_dev_rust() { :; }
check_rust_toolchains() { :; }
clean_dev_ruby() { :; }
clean_dev_perl() { :; }
clean_dev_docker() { :; }
clean_dev_cloud() { :; }
clean_dev_nix() { :; }
clean_dev_shell() { :; }
clean_dev_frontend() { :; }
clean_dev_jvm() { :; }
clean_dev_ai_agents() { :; }
clean_dev_other_langs() { :; }
clean_dev_cicd() { :; }
clean_dev_network() { :; }
clean_dev_misc() { :; }
clean_dev_elixir() { :; }
clean_dev_ocaml() { :; }
clean_editor_obsolete_extensions() { :; }
safe_clean() { :; }
debug_log() { :; }
clean_developer_tools
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"npm"* ]] || return 1
    [[ "$output" == *"mise"* ]] || return 1
}

@test "clean_dev_ruby cleans rbenv, gem, and bundler caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_ruby
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"rbenv download cache|"* ]] || return 1
    [[ "$output" == *"gem spec cache|"* ]] || return 1
    [[ "$output" == *"gem package cache|"* ]] || return 1
    [[ "$output" == *"Ruby Bundler cache|"* ]]
}

@test "clean_dev_perl clears the CPAN build tree but keeps the source store" {
    # ~/.cpan/sources holds the distribution tarballs CPAN installs from and
    # reuses across installs, so dropping it costs a re-download. The build
    # tree next to it is throwaway scratch.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_perl
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CPAN build artifacts|"* ]] || return 1
    [[ "$output" != *"/.cpan/sources"* ]]
}

@test "clean_dev_other_langs no longer includes Ruby Bundler cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Ruby Bundler cache"* ]]
}

@test "clean_dev_python keeps downloaded model weights and run artifacts" {
    # Hugging Face, PyTorch, TensorFlow and Weights & Biases store multi-GB
    # downloads and experiment output, not rebuildable build products. Only
    # ~/.cache/huggingface was ever covered by DEFAULT_WHITELIST_PATTERNS, and
    # that array stops applying once a user saves their own whitelist file, so
    # the other three were deleted for everyone.
    mkdir -p "$HOME/.cache/huggingface/hub" "$HOME/.cache/torch/hub" \
        "$HOME/.cache/tensorflow/datasets" "$HOME/.cache/wandb/run-1"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_tool_cache() { echo "$1|$2"; }
clean_uv_cache() { :; }
clean_conda_metadata_caches() { :; }
note_activity() { :; }
clean_dev_python
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"huggingface"* ]] || return 1
    [[ "$output" != *"/.cache/torch"* ]] || return 1
    [[ "$output" != *"/.cache/tensorflow"* ]] || return 1
    [[ "$output" != *"/.cache/wandb"* ]] || return 1
    # The rebuildable linter and type-checker caches next to them still go.
    [[ "$output" == *"Ruff cache"* ]] || return 1
    [[ "$output" == *"MyPy cache"* ]]
}

@test "clean_dev_go refuses a symlinked module root but still clears the build cache" {
    # `go clean -modcache` removes the module root directory itself, so handing
    # it the resolved physical path of a symlinked GOMODCACHE deletes the target
    # and leaves the owner's root dangling for the next build. `go clean -cache`
    # empties GOCACHE in place, so a symlinked build root stays supported.
    local module_physical="$HOME/go-module-physical"
    local module_link="$HOME/go-module-link"
    local build_root="$HOME/go-build-cache"
    local trace="$HOME/go-clean.trace"
    mkdir -p "$module_physical" "$build_root"
    ln -s "$module_physical" "$module_link"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_link" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        case "$3" in
            GOMODCACHE) printf '%s\n' "$GO_MODULE_ROOT" ;;
            GOCACHE) printf '%s\n' "$GO_BUILD_ROOT" ;;
        esac
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · stopped (symlinked module root)"* ]] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Go build cache"* ]] || return 1
    # Nothing may be handed to the owner command for the symlinked root, and
    # the physical directory the link points at must survive.
    ! grep -q -- "-modcache" "$trace" || return 1
    [[ -d "$module_physical" ]] || return 1
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    rm -f "$trace" "$module_link"
    rm -rf "$module_physical" "$build_root"
}

@test "clean_dev_go refuses a module root that becomes a symlink after entry" {
    # The entry check only proves the root was a real directory when the caller
    # looked. Swap it for a link afterwards and the parent/target identity
    # comparison still passes, so the owner command would run against whatever
    # the link resolves to.
    local module_root="$HOME/go-module-swap"
    local outside_root="$HOME/go-outside-target"
    local build_root="$HOME/go-build-swap"
    local trace="$HOME/go-clean-swap.trace"
    mkdir -p "$module_root" "$outside_root" "$build_root"
    printf 'keep\n' > "$outside_root/victim.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        case "$3" in
            GOMODCACHE) printf '%s\n' "$GO_MODULE_ROOT" ;;
            GOCACHE) printf '%s\n' "$GO_BUILD_ROOT" ;;
        esac
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
note_activity() { :; }
# Fires inside the bound command, after the entry check has passed.
swapped=0
go_cache_process_state() {
    if [[ "${1:-}" == "GOMODCACHE" && $swapped -eq 0 ]]; then
        swapped=1
        rmdir "$GO_MODULE_ROOT" 2> /dev/null || true
        ln -s "$HOME/go-outside-target" "$GO_MODULE_ROOT"
    fi
    return 1
}
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · stopped (symlinked module root)"* ]] || {
        echo "$output"
        return 1
    }
    ! grep -q -- "-modcache" "$trace" || {
        cat "$trace"
        return 1
    }
    [[ -f "$outside_root/victim.txt" ]] || return 1
    # The concurrency-safe build cache is unaffected by the module-root swap.
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    rm -f "$trace" "$module_root"
    rm -rf "$outside_root" "$build_root"
}

@test "clean_dev_go uses owner dry-run for the same cache roots" {
    local module_root="$HOME/go-module-dry"
    local build_root="$HOME/go-build-dry"
    local trace="$HOME/go-clean-dry.trace"
    mkdir -p "$module_root" "$build_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=true
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        if [[ "$3" == "GOMODCACHE" ]]; then
            printf '%s\n' "$GO_MODULE_ROOT"
        else
            printf '%s\n' "$GO_BUILD_ROOT"
        fi
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go module cache · would clean"* ]] || return 1
    [[ "$output" == *"Go build cache · would clean"* ]] || return 1
    grep -qFx "env GOMODCACHE=$module_root go clean -n -modcache" "$trace" || return 1
    grep -qFx "env GOCACHE=$build_root go clean -n -cache" "$trace" || return 1
    rm -f "$trace"
    rm -rf "$module_root" "$build_root"
}

@test "clean_dev_go keeps module and build cache whitelist decisions independent" {
    local module_root="$HOME/go-module-whitelist"
    local build_root="$HOME/go-build-whitelist"
    local trace="$HOME/go-clean-whitelist.trace"
    mkdir -p "$module_root" "$build_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" GO_BUILD_ROOT="$build_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        if [[ "$3" == "GOMODCACHE" ]]; then
            printf '%s\n' "$GO_MODULE_ROOT"
        else
            printf '%s\n' "$GO_BUILD_ROOT"
        fi
        return 0
    fi
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { [[ "$1" == "$GO_MODULE_ROOT" ]]; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
clean_tool_cache() { printf 'SKIP=%s|%s\n' "$1" "$2"; }
note_activity() { :; }
clean_dev_go
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP=Go module cache|$module_root"* ]] || return 1
    grep -qFx "env GOCACHE=$build_root go clean -cache" "$trace" || return 1
    [[ "$(cat "$trace")" != *"-modcache"* ]] || return 1
    rm -f "$trace"
    rm -rf "$module_root" "$build_root"
}

@test "Go process gating does not block the concurrency-safe build cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_pgrep_any() {
    printf 'PROBE=%s\n' "$*"
    return 0
}
build_rc=0
module_rc=0
go_cache_process_state GOCACHE || build_rc=$?
go_cache_process_state GOMODCACHE || module_rc=$?
printf 'build=%s module=%s\n' "$build_rc" "$module_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"PROBE=-x go -x gopls"* ]] || return 1
    [[ "$output" == *"build=1 module=0"* ]]
}

@test "clean_dev_go propagates owner cleanup cancellation" {
    local module_root="$HOME/go-module-cancel"
    mkdir -p "$module_root"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_MODULE_ROOT="$module_root" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    if [[ "$1" == "go" && "$2" == "env" ]]; then
        [[ "$3" == "GOMODCACHE" ]] && printf '%s\n' "$GO_MODULE_ROOT" || return 1
        return 0
    fi
    return 124
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
clean_rc=0
clean_dev_go || clean_rc=$?
printf 'rc=%s\n' "$clean_rc"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"rc=124"* ]] || return 1
    rm -rf "$module_root"
}

@test "clean_go_cache_root refuses a path replaced before the owner command" {
    local cache_root="$HOME/go-cache-swap"
    local outside_root="$HOME/go-cache-outside"
    local trace="$HOME/go-clean-swap.trace"
    mkdir -p "$cache_root" "$outside_root/private"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        GO_CACHE_ROOT="$cache_root" GO_OUTSIDE_ROOT="$outside_root" GO_TRACE="$trace" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
go() { :; }
run_with_timeout() {
    shift
    printf '%s\n' "$*" >> "$GO_TRACE"
}
is_path_whitelisted() { return 1; }
should_protect_path() { return 1; }
go_cache_process_state() { return 1; }
note_activity() { :; }
eval "$(declare -f _run_go_cache_clean_bound | sed '1s/_run_go_cache_clean_bound/_original_run_go_cache_clean_bound/')"
_run_go_cache_clean_bound() {
    mv "$GO_CACHE_ROOT" "$GO_CACHE_ROOT-old"
    ln -s "$GO_OUTSIDE_ROOT" "$GO_CACHE_ROOT"
    _original_run_go_cache_clean_bound "$@"
}
clean_go_cache_root "$GO_CACHE_ROOT" GOCACHE -cache "Go build cache"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Go build cache · stopped (cache path state unknown)"* ]] || return 1
    [ ! -e "$trace" ] || return 1
    [ -d "$outside_root/private" ] || return 1
    rm -f "$cache_root"
    rm -rf "$cache_root-old" "$outside_root"
}

@test "clean_dev_jvm keeps the Ivy store and the sbt toolchain" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
mole_cleanup_targets_exist() { return 1; }
safe_clean() { echo "$2|$1"; }
clean_dev_jvm
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"/.ivy2/"* ]] || return 1
    [[ "$output" != *"/.sbt/"* ]]
}

@test "clean_dev_other_langs keeps the Deno module store" {
    # DENO_DIR mixes remote imports with origin storage and runtime payloads;
    # the owner clean command resets the whole root rather than a narrow leaf.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Deno"* ]] || return 1
    [[ "$output" != *"Caches/deno"* ]] || return 1
    [[ "$output" == *"Zig cache"* ]]
}

@test "clean_dev_other_langs keeps the NuGet global packages folder" {
    # ~/.nuget/packages is the restore target itself, the .NET counterpart of
    # ~/.m2/repository, which clean_large_files only reports for review.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2|$1"; }
clean_dev_other_langs
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *".nuget"* ]] || return 1
    [[ "$output" != *"NuGet"* ]] || return 1
    [[ "$output" == *"Zig cache"* ]]
}

@test "clean_project_caches cleans flutter .dart_tool and build directories" {
    mkdir -p "$HOME/Code/flutter_app/.dart_tool" "$HOME/Code/flutter_app/build"
    touch "$HOME/Code/flutter_app/.dart_tool/cache.bin"
    touch "$HOME/Code/flutter_app/build/output.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
create_temp_file() { mktemp; }
safe_clean() { echo "$2|$1"; }
DRY_RUN=false
clean_project_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Flutter build cache (.dart_tool)"* ]] || return 1
    [[ "$output" == *"Flutter build cache (build/)"* ]]
}

@test "project cache processing stops after a Python size timeout" {
    local python_root="$HOME/Code/A"
    local next_root="$HOME/Code/B"
    mkdir -p "$python_root/__pycache__" "$next_root/.next/cache"
    touch "$python_root/__pycache__/module.pyc" "$next_root/.next/cache/output"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/caches.sh"
matches_file=$(mktemp)
printf '%s\t%s\n' "$HOME/Code/A" "$HOME/Code/A/__pycache__" > "$matches_file"
printf '%s\t%s\n' "$HOME/Code/B" "$HOME/Code/B/.next" >> "$matches_file"
get_path_size_kb() { return 124; }
safe_clean() { echo "UNEXPECTED_CONTINUATION:$2|$1"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; }

set +e
process_project_cache_matches "$matches_file"
rc=$?
set -e
rm -f "$matches_file"
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
[[ $rc -eq 124 && $MOLE_CLEAN_CANCEL_STATUS -eq 124 ]]
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"RC=124 CANCEL=124"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CONTINUATION"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_DELETE"* ]]
}

@test "clean_dev_misc includes Chrome DevTools MCP cache when server not running" {
    mkdir -p "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache"
    touch "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
pgrep() { return 1; }
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Chrome DevTools MCP browser cache"* ]] || return 1
    [[ "$output" != *"Chrome DevTools MCP cache"* ]]
}

@test "clean_dev_misc skips Chrome DevTools MCP cache when server is running" {
    mkdir -p "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache"
    touch "$HOME/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache/data"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
pgrep() { return 0; }
safe_clean() { echo "$2"; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_dev_misc
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"Chrome DevTools MCP caches · skipped"* ]] || return 1
    [[ "$output" != *"Chrome DevTools MCP browser cache"* ]]
}

@test "clean_chrome_devtools_mcp_caches preserves profile state" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    mkdir -p "$profile/Default/Cache" "$profile/Default/Code Cache" "$profile/Default/GPUCache"
    mkdir -p "$profile/Default/Service Worker/CacheStorage"
    mkdir -p "$profile/Default/Local Storage/leveldb"
    touch "$profile/Default/Cache/data" "$profile/Default/Code Cache/data" "$profile/Default/GPUCache/data"
    touch "$profile/Default/Service Worker/CacheStorage/data"
    touch "$profile/Default/Cookies" "$profile/Default/Local Storage/leveldb/state"
    touch "$profile/Local State"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1|$2"; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP browser cache|$profile/Default/Cache/"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP code cache|$profile/Default/Code Cache/"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP GPU cache|$profile/Default/GPUCache/"* ]] || return 1
    [[ "$output" == *"SWC:Chrome DevTools MCP|$profile/Default/Service Worker/CacheStorage"* ]] || return 1
    [[ "$output" != *"Cookies"* ]] || return 1
    [[ "$output" != *"Local Storage"* ]] || return 1
    [[ "$output" != *"Local State"* ]]
}

@test "clean_chrome_devtools_mcp_caches ignores an empty active profile" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    rm -rf "$profile"
    mkdir -p "$profile/Default/Cache" "$profile/Default/Service Worker/CacheStorage"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }
clean_service_worker_cache() { echo "UNEXPECTED_SWC"; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"UNEXPECTED_DEFER"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_CLEAN"* ]] || return 1
    [[ "$output" != *"UNEXPECTED_SWC"* ]] || return 1
    [[ "$output" != *"process state unknown"* ]]
}

@test "clean_chrome_devtools_mcp_caches recognizes root-level cache candidates" {
    profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    rm -rf "$profile"
    mkdir -p "$profile/extensions_crx_cache"
    touch "$profile/extensions_crx_cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { :; }
clean_chrome_devtools_mcp_caches
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"SAFE_CLEAN:Chrome DevTools MCP extension cache|$profile/extensions_crx_cache/candidate"* ]]
}


@test "clean_editor_obsolete_extensions removes only dirs listed in .obsolete (#910)" {
    local ext_root="$HOME/.vscode/extensions"
    mkdir -p "$ext_root/pub.ext-old-1.0.0" "$ext_root/pub.ext-new-1.1.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "pub.ext-old-1.0.0": true
}
JSON

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "CLEAN:$1"; }
clean_editor_obsolete_extensions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$HOME/.vscode/extensions/pub.ext-old-1.0.0"* ]] || return 1
    [[ "$output" != *"pub.ext-new-1.1.0"* ]]
}

@test "clean_editor_obsolete_extensions rejects path-traversal keys in .obsolete (#910)" {
    rm -rf "$HOME/.vscode" "$HOME/.vscode-insiders" "$HOME/.cursor"
    local ext_root="$HOME/.cursor/extensions"
    mkdir -p "$ext_root"
    mkdir -p "$HOME/obsolete-victim"
    # A legitimate entry alongside the malicious ones. Without it the function has
    # nothing to clean, output is empty, and "no CLEAN: line" cannot distinguish
    # "traversal rejected" from "never ran".
    mkdir -p "$ext_root/publisher.legit-1.0.0"
    cat > "$ext_root/.obsolete" << 'JSON'
{
  "../../obsolete-victim": true,
  "..": true,
  "publisher.legit-1.0.0": true
}
JSON

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "CLEAN:$1"; }
clean_editor_obsolete_extensions
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"CLEAN:$ext_root/publisher.legit-1.0.0"* ]] || return 1
    [[ "$output" != *"obsolete-victim"* ]] || return 1
    [[ "$output" != *"CLEAN:$HOME/.cursor\""* ]] || return 1
    [ -d "$HOME/obsolete-victim" ]
}
