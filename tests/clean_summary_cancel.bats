#!/usr/bin/env bats

# Regression for #1342: when a cleanup scan/size check hits its internal
# timeout (exit 124), `mo clean` must still print the final summary with an
# explicit reason instead of exiting silently mid-run.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel.XXXXXX")"
    export HOME

    mkdir -p "$HOME/.cache"
    mkdir -p "$HOME/.config/mole"
    for i in 1 2 3 4 5; do
        mkdir -p "$HOME/.cache/cachedir$i"
    done
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel."* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-clean-summary-cancel."* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
}

run_perform_cleanup_with() {
    export SECTION_RC="$1"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
for fn in clean_linux_user_cache_sweep clean_linux_trash \
    clean_linux_browser_caches clean_developer_tools \
    clean_linux_aur_caches clean_linux_system_maintenance \
    report_linux_orphan_packages; do
    eval "$fn() { return 0; }"
done
clean_linux_user_cache_sweep() { return "$SECTION_RC"; }
perform_cleanup
EOF
}

@test "sizing timeout (124) still prints the summary (#1342)" {
    run_perform_cleanup_with 124

    [ "$status" -eq 124 ]
    [[ "$output" == *"Cleanup cancelled"* ]]
    [[ "$output" == *"timed out (exit 124)"* ]]
    [[ "$output" == *"Remaining cleanup was skipped"* ]]
}

@test "interrupted section (>=128) prints an interrupted summary" {
    run_perform_cleanup_with 130

    [ "$status" -eq 130 ]
    [[ "$output" == *"Cleanup interrupted"* ]]
    [[ "$output" == *"was interrupted (exit 130)"* ]]
}

@test "successful run still prints a complete summary" {
    run_perform_cleanup_with 0

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup complete"* ]]
    [[ "$output" != *"Cleanup cancelled"* ]]
}

@test "run with removal timeouts completes and reports them (#1384)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
for fn in clean_linux_user_cache_sweep clean_linux_trash \
    clean_linux_browser_caches clean_developer_tools \
    clean_linux_aur_caches clean_linux_system_maintenance \
    report_linux_orphan_packages; do
    eval "$fn() { return 0; }"
done
clean_linux_user_cache_sweep() { MOLE_CLEAN_REMOVAL_TIMEOUTS=3; return 0; }
perform_cleanup
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup complete"* ]]
    [[ "$output" != *"Cleanup cancelled"* ]]
    [[ "$output" == *"3 item(s) exceeded the 30s removal budget"* ]]
}

@test "sizing timeouts still clean and the summary reports the under-count (#1374)" {
    mkdir -p "$HOME/.cache/cache1374"
    printf x > "$HOME/.cache/cache1374/file.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
source "$PROJECT_ROOT/bin/clean.sh"
# Stub every section so perform_cleanup never scans the real machine.
for fn in clean_linux_trash clean_linux_browser_caches \
    clean_developer_tools clean_linux_aur_caches \
    clean_linux_system_maintenance report_linux_orphan_packages; do
    eval "$fn() { return 0; }"
done
# Force every size check to hit the sizing budget.
get_cleanup_path_size_kb() { return 124; }
clean_linux_user_cache_sweep() {
    safe_clean "$HOME/.cache/cache1374" "User app cache"
}
perform_cleanup
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"Cleanup complete"* ]] || return 1
    [[ "$output" != *"Cleanup cancelled"* ]] || return 1
    [[ "$output" == *"size-check budget"* ]] || return 1
    [[ "$output" == *"under-reported"* ]] || return 1
    [[ ! -e "$HOME/.cache/cache1374" ]]
}
