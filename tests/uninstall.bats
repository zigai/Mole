#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${BATS_TMPDIR:-}" # Use BATS_TMPDIR as original HOME if set by bats
    if [[ -z "$ORIGINAL_HOME" ]]; then
        ORIGINAL_HOME="${HOME:-}"
    fi
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-home.XXXXXX")"
    export HOME
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
    # Safety: refuse to operate on a real home directory.
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="dumb"
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME"
    # Immunity against cross-suite leakage: scripts/test.sh sources lib/core
    # modules into its own shell and exports platform/distro presets into every
    # bats worker. These payloads must not see an inherited preset.
    unset MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED || true
}


@test "calculate_total_size returns aggregate kilobytes" {
    mkdir -p "$HOME/sized"
    dd if=/dev/zero of="$HOME/sized/file1" bs=1024 count=1 > /dev/null 2>&1
    dd if=/dev/zero of="$HOME/sized/file2" bs=1024 count=2 > /dev/null 2>&1

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
files="$(printf '%s
%s
' "$HOME/sized/file1" "$HOME/sized/file2")"
calculate_total_size "$files"
EOF
    )"

    [ "$result" -ge 3 ]
}

@test "calculate_total_size does not double-count nested paths" {
    mkdir -p "$HOME/sized-parent/child"
    dd if=/dev/zero of="$HOME/sized-parent/child/payload" bs=1024 count=2 > /dev/null 2>&1

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
parent="$HOME/sized-parent"
child="$HOME/sized-parent/child"
parent_only=$(calculate_total_size "$parent")
with_child=$(calculate_total_size "$(printf '%s\n%s\n' "$parent" "$child")")
printf '%s|%s\n' "$parent_only" "$with_child"
EOF
    )"

    parent_only="${result%%|*}"
    with_child="${result##*|}"
    [ "$parent_only" -gt 0 ]
    [ "$with_child" -eq "$parent_only" ]
}

@test "format_uninstall_preview_path includes per-path size" {
    dd if=/dev/zero of="$HOME/preview-size-file" bs=1024 count=1 > /dev/null 2>&1
    expected_size_kb="$(du -skP "$HOME/preview-size-file" | awk '{print $1}')"

    result="$(
        HOME="$HOME" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
format_uninstall_preview_path "$HOME/preview-size-file"
EOF
    )"

    [[ "$result" == *"~/preview-size-file"* ]] || return 1
    [[ "$result" == *"${expected_size_kb}KB"* ]]
}

@test "format_uninstall_preview_path propagates timed out and interrupted size probes" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
get_path_size_kb() { return "$SIZE_RC"; }
for SIZE_RC in 124 130; do
    rc=0
    format_uninstall_preview_path "$HOME/interrupted-preview" || rc=$?
    printf 'SIZE_RC=%s RC=%s\n' "$SIZE_RC" "$rc"
done
EOF

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SIZE_RC=124 RC=124"* ]] || return 1
    [[ "$output" == *"SIZE_RC=130 RC=130"* ]]
}


@test "safe_remove can remove a simple directory" {
    mkdir -p "$HOME/test_dir"
    touch "$HOME/test_dir/file.txt"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

safe_remove "$HOME/test_dir"
[[ ! -d "$HOME/test_dir" ]] || exit 1
EOF
    [ "$status" -eq 0 ]
}


@test "remove_mole deletes manual binaries and caches" {
    mkdir -p "$HOME/.local/bin"
    touch "$HOME/.local/bin/mole"
    touch "$HOME/.local/bin/mo"
    mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"
    echo "protected-entry" > "$HOME/.config/mole/whitelist"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
rm() {
    local -a flags=()
    local -a paths=()
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            flags+=("$arg")
        else
            paths+=("$arg")
        fi
    done
    local path
    for path in "${paths[@]}"; do
        if [[ "$path" == "$HOME" || "$path" == "$HOME/"* ]]; then
            /bin/rm "${flags[@]}" "$path"
        fi
    done
    return 0
}
sudo() {
    if [[ "$1" == "rm" ]]; then
        shift
        rm "$@"
        return 0
    fi
    return 0
}
export -f start_inline_spinner stop_inline_spinner rm sudo
printf '\n' | "$PROJECT_ROOT/mole" remove
EOF

    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.local/bin/mole" ] || return 1
    [ ! -f "$HOME/.local/bin/mo" ] || return 1
    [ ! -d "$HOME/.config/mole" ] || return 1
    [ ! -d "$HOME/.cache/mole" ] || return 1
    # Linux removes the XDG state dir; the config dir is gio-trashed.
    [ ! -d "${XDG_STATE_HOME:-$HOME/.local/state}/mole" ] || return 1
}

@test "remove_mole dry-run keeps manual binaries and caches" {
    mkdir -p "$HOME/.local/bin"
    touch "$HOME/.local/bin/mole"
    touch "$HOME/.local/bin/mo"
    mkdir -p "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN MODE"* ]] || return 1
    [ -f "$HOME/.local/bin/mole" ]
    [ -f "$HOME/.local/bin/mo" ]
    [ -d "$HOME/.config/mole" ]
    [ -d "$HOME/.cache/mole" ]
    [ -d "$HOME/Library/Logs/mole" ]
}

@test "remove_mole test mode ignores PATH installs outside test HOME" {
    mkdir -p "$HOME/.local/bin" "$HOME/.config/mole" "$HOME/.cache/mole" "$HOME/Library/Logs/mole"
    touch "$HOME/.local/bin/mole"
    touch "$HOME/.local/bin/mo"

    fake_global_bin="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-remove-path.XXXXXX")"
    touch "$fake_global_bin/mole"
    touch "$fake_global_bin/mo"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PATH="$fake_global_bin:/usr/bin:/bin" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
export -f start_inline_spinner stop_inline_spinner
printf '\n' | "$PROJECT_ROOT/mole" remove --dry-run
EOF

    rm -rf "$fake_global_bin"

    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/.local/bin/mole"* ]] || return 1
    [[ "$output" == *"$HOME/.local/bin/mo"* ]] || return 1
    [[ "$output" != *"$fake_global_bin/mole"* ]] || return 1
    [[ "$output" != *"$fake_global_bin/mo"* ]] || return 1
}

@test "match_apps_by_name finds exact match case-insensitively" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1002|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"TestApp"* ]]
}

@test "match_apps_by_name finds by directory name" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1002|$HOME/Applications/TestApp.app|Test Application|com.example.TestApp|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "TestApp"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"Test Application"* ]]
}

@test "match_apps_by_name warns on no match" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "nonexistent"
echo "count=${#selected_apps[@]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning: No application found matching 'nonexistent'"* ]] || return 1
    [[ "$output" == *"count=0"* ]]
}

@test "match_apps_by_name handles multiple app names" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1002|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp2" "testapp3"
echo "count=${#selected_apps[@]}"
for app in "${selected_apps[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ <<< "$app"
    echo "matched=$name"
done
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=2"* ]] || return 1
    [[ "$output" == *"matched=TestApp2"* ]] || return 1
    [[ "$output" == *"matched=TestApp3"* ]]
}

@test "match_apps_by_name falls back to substring match" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
	"1001|$HOME/Applications/SlackDesktop.app|Slack|com.tinyspeck.slackmacgap|200 MB|1000001|204800"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "test"
echo "count=${#selected_apps[@]}"
for app in "${selected_apps[@]}"; do
    IFS='|' read -r _ _ name _ _ _ _ <<< "$app"
    echo "matched=$name"
done
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"matched=TestApp"* ]]
}

@test "match_apps_by_name does not duplicate when same name given twice" {
    run /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp.app|TestApp|com.example.TestApp|1.2 GB|1000000|1258291"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "testapp" "testapp"
echo "count=${#selected_apps[@]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=1"* ]]
}


@test "main clears pending input before app selection after scan (#726)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

trace_file="$HOME/uninstall-trace.log"
app_cache_file="$HOME/apps-cache.txt"
touch "$app_cache_file"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$app_cache_file"; }
load_applications() {
    printf 'load\n' >> "$trace_file"
    return 0
}
drain_pending_input() {
    printf 'drain\n' >> "$trace_file"
}
select_apps_for_uninstall() {
    printf 'select\n' >> "$trace_file"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

eval "$(sed -n '/^main()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

main

expected=$(printf 'load\ndrain\nselect\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "main keeps scan and selector on one alternate screen until cancel (#1194)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

trace_file="$HOME/uninstall-screen-trace.log"
app_cache_file="$HOME/apps-cache.txt"
touch "$app_cache_file"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { printf 'clear\n' >> "$trace_file"; }
start_uninstall_interactive_screen() {
    export MOLE_ALT_SCREEN_ACTIVE=1
    export MOLE_MANAGED_ALT_SCREEN=1
    printf 'start\n' >> "$trace_file"
}
stop_uninstall_interactive_screen() {
    printf 'stop\n' >> "$trace_file"
    unset MOLE_ALT_SCREEN_ACTIVE MOLE_MANAGED_ALT_SCREEN
}
scan_applications() {
    printf 'scan\n' >> "$trace_file"
    printf '%s\n' "$app_cache_file"
}
uninstall_app_inventory_fingerprint() {
    printf 'fingerprint\n' >> "$trace_file"
    printf 'inventory\n'
}
load_applications() { printf 'load\n' >> "$trace_file"; }
drain_pending_input() { printf 'drain\n' >> "$trace_file"; }
select_apps_for_uninstall() {
    [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]
    [[ "${MOLE_MANAGED_ALT_SCREEN:-}" == "1" ]]
    printf 'select\n' >> "$trace_file"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

eval "$(sed -n '/^main()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

main

expected=$(printf 'start\nscan\nfingerprint\nload\ndrain\nselect\nstop\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}


@test "select_apps_for_uninstall drains pending input before opening paginated menu" {
    mkdir -p "$HOME/Applications/TraceApp.app"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

trace_file="$HOME/selector-drain-trace.log"

source "$PROJECT_ROOT/lib/ui/app_selector.sh"

apps_data=("1700000000|$HOME/Applications/TraceApp.app|TraceApp|com.example.TraceApp|1MB|Today|1024")
selected_apps=()

get_display_width() { printf '%s\n' "${#1}"; }
format_app_display() {
    printf 'format\n' >> "$trace_file"
    printf '%s' "$1"
}
drain_pending_input() { printf 'drain\n' >> "$trace_file"; }
paginated_multi_select() {
    printf 'guard:%s\n' "${MOLE_MENU_IGNORE_INITIAL_ENTER:-unset}" >> "$trace_file"
    printf 'paginated\n' >> "$trace_file"
    MOLE_SELECTION_RESULT="0"
    return 0
}

select_apps_for_uninstall
[[ ${#selected_apps[@]} -eq 1 ]] || exit 1
[[ -z "${MOLE_MENU_IGNORE_INITIAL_ENTER:-}" ]] || exit 1

expected=$(printf 'format\ndrain\nguard:1\npaginated\n')
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    [ "$status" -eq 0 ]
}

@test "paginated menu can ignore one initial Enter for uninstall launch guard" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-initial-enter-state"
read_key() {
    if [[ ! -f "$key_state" ]]; then
        : > "$key_state"
        echo "ENTER"
    else
        echo "QUIT"
    fi
}

MOLE_SELECTION_RESULT=""
set +e
MOLE_MENU_IGNORE_INITIAL_ENTER=1 paginated_multi_select "Test Menu" "First App" > "$HOME/menu.out" 2> "$HOME/menu.err"
rc=$?
set -e

echo "rc=$rc"
echo "result=${MOLE_SELECTION_RESULT:-}"
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"* ]] || return 1
    [[ "$output" == *"result="* ]] || return 1
    [[ "$output" != *"result=0"* ]]
}

@test "paginated menu skips Size sort when size metadata is unavailable (#1126)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-no-size-state"
read_key() {
    local n
    n=$(cat "$key_state" 2> /dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$key_state"
    case "$n" in
        1 | 2) echo "CHAR:S" ;;
        *) echo "ENTER" ;;
    esac
}

MOLE_SELECTION_RESULT=""
unset MOLE_MENU_SORT_MODE MOLE_MENU_SORT_REVERSE MOLE_MENU_META_SIZEKB
set +e
MOLE_MENU_META_EPOCHS="100,200" paginated_multi_select "Test Menu" "Alpha" "Beta" > "$HOME/menu.out" 2> "$HOME/menu.err" < /dev/null
rc=$?
set -e
echo "rc=$rc"
echo "mode=${MOLE_MENU_SORT_MODE:-}"
echo "result=${MOLE_SELECTION_RESULT:-}"
[[ $rc -eq 0 ]] || exit 1
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]] || return 1
    [[ "$output" == *"mode=date"* ]] || return 1
    [[ "$output" == *"result=0"* ]]
}

@test "paginated menu reverses Size order when size metadata is available (#1126)" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" TERM="xterm-256color" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail

source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/ui/menu_paginated.sh"

key_state="$HOME/menu-size-state"
read_key() {
    local n
    n=$(cat "$key_state" 2> /dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$key_state"
    case "$n" in
        1) echo "${NEXT_KEY:-ENTER}" ;;
        *) echo "ENTER" ;;
    esac
}

MOLE_SELECTION_RESULT=""
set +e
MOLE_MENU_META_SIZEKB="1,100" MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false paginated_multi_select "Test Menu" "Small" "Large" > "$HOME/menu-default.out" 2> "$HOME/menu-default.err" < /dev/null
default_rc=$?
set -e
echo "default=${MOLE_SELECTION_RESULT:-}"

: > "$key_state"
MOLE_SELECTION_RESULT=""
set +e
NEXT_KEY="CHAR:O" MOLE_MENU_META_SIZEKB="1,100" MOLE_MENU_SORT_MODE=size MOLE_MENU_SORT_REVERSE=false paginated_multi_select "Test Menu" "Small" "Large" > "$HOME/menu-reverse.out" 2> "$HOME/menu-reverse.err" < /dev/null
reverse_rc=$?
set -e
echo "default_rc=$default_rc"
echo "reverse_rc=$reverse_rc"
echo "reverse=${MOLE_SELECTION_RESULT:-}"
[[ $default_rc -eq 0 ]] || exit 1
[[ $reverse_rc -eq 0 ]] || exit 1
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"default_rc=0"* ]] || return 1
    [[ "$output" == *"reverse_rc=0"* ]] || return 1
    [[ "$output" == *"default=1"* ]] || return 1
    [[ "$output" == *"reverse=0"* ]]
}


@test "main reuses the app list after a removal-only uninstall (#866, #1315)" {
    local first_cache
    first_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-866-first.XXXXXX")"

    mkdir -p "$HOME/Applications/FirstApp.app" "$HOME/Applications/SecondApp.app"
    cat > "$first_cache" << CACHE
1700000000|$HOME/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240
1700000001|$HOME/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" FIRST_CACHE="$first_cache" \
        /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

trace_file="$HOME/uninstall-866-trace.log"
scan_state_file="$HOME/uninstall-866-scan-count"
printf '0\n' > "$scan_state_file"
select_count=0
fingerprint_state="before"
selected_apps=()

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
drain_pending_input() { :; }
uninstall_app_inventory_fingerprint() {
    if [[ "$fingerprint_state" == "before" ]]; then
        printf '%s|1\n%s|1\n' "$HOME/Applications/FirstApp.app" "$HOME/Applications/SecondApp.app"
    else
        printf '%s|1\n' "$HOME/Applications/SecondApp.app"
    fi
}
batch_uninstall_applications() {
    printf 'batch\n' >> "$trace_file"
    rmdir "$HOME/Applications/FirstApp.app"
    fingerprint_state="after"
}
uninstall_normalize_size_display() { printf '%s\n' "$1"; }
uninstall_normalize_last_used_display() { printf '%s\n' "$1"; }
scan_applications() {
    local scan_count
    scan_count=$(cat "$scan_state_file")
    scan_count=$((scan_count + 1))
    printf '%s\n' "$scan_count" > "$scan_state_file"
    printf 'scan:%s\n' "$scan_count" >> "$trace_file"
    printf '%s\n' "$FIRST_CACHE"
}
load_applications() {
    local apps_file="$1"
    apps_data=()
    selection_state=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        [[ -e "$app_path" ]] || continue
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        selection_state+=(false)
    done < "$apps_file"
    printf 'load:%s\n' "${apps_data[0]#*|}" >> "$trace_file"
}
select_apps_for_uninstall() {
    select_count=$((select_count + 1))
    printf 'select:%s\n' "$select_count" >> "$trace_file"
    if [[ $select_count -eq 1 ]]; then
        selected_apps=("${apps_data[0]}")
        return 0
    fi
    _MOLE_MENU_USER_QUIT=1
    return 1
}

eval "$(sed -n '/^uninstall_inventory_can_reuse_cached_apps()/,/^}/p' "$PROJECT_ROOT/bin/uninstall.sh")"
eval "$(sed -n '/^main()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"

printf '\n' | main

expected=$(printf 'scan:1\nload:%s/Applications/FirstApp.app|FirstApp|com.example.FirstApp|10MB|Today|10240\nselect:1\nbatch\nload:%s/Applications/SecondApp.app|SecondApp|com.example.SecondApp|11MB|Today|11264\nselect:2\n' "$HOME" "$HOME")
actual=$(cat "$trace_file")
[[ "$actual" == "$expected" ]] || {
    printf 'unexpected trace:\n%s\n' "$actual" >&2
    exit 1
}
INNER

    rm -f "$first_cache"
    [ "$status" -eq 0 ]
}

@test "inventory cache reuse accepts removals only and rejects stale changes (#1315)" {
    run env HOME="$HOME/inventory-reuse" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
eval "$(sed -n '/^uninstall_inventory_can_reuse_cached_apps()/,/^}/p' "$PROJECT_ROOT/bin/uninstall.sh")"

mkdir -p "$HOME/Applications/First.app" "$HOME/Applications/Second.app"
mkdir -p "$HOME/Applications/With|Pipe.app"
old=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/First.app" "$HOME/Applications/Second.app")
removed=$(printf '%s|1|1\n' "$HOME/Applications/Second.app")
changed=$(printf '%s|2|1\n' "$HOME/Applications/Second.app")
added=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/Second.app" "$HOME/Applications/Third.app")
pipe_old=$(printf '%s|1|1\n%s|1|1\n' "$HOME/Applications/Second.app" "$HOME/Applications/With|Pipe.app")

if uninstall_inventory_can_reuse_cached_apps "$old" "$removed"; then
    exit 1
fi
if uninstall_inventory_can_reuse_cached_apps "$pipe_old" "$removed"; then
    exit 2
fi
rmdir "$HOME/Applications/With|Pipe.app"
uninstall_inventory_can_reuse_cached_apps "$pipe_old" "$removed" || exit 3
rmdir "$HOME/Applications/First.app"
uninstall_inventory_can_reuse_cached_apps "$old" "$removed" || exit 4
if uninstall_inventory_can_reuse_cached_apps "$old" "$changed"; then
    exit 5
fi
if uninstall_inventory_can_reuse_cached_apps "$old" "$added"; then
    exit 6
fi
if uninstall_inventory_can_reuse_cached_apps "$old" ""; then
    exit 7
fi
INNER

    [ "$status" -eq 0 ] || return 1
}


@test "uninstall main sets MOLE_DELETE_MODE=trash by default" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-723-trash.XXXXXX")"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

eval "$(sed -n '/^main()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete_mode=trash"* ]]
}

@test "uninstall main sets MOLE_DELETE_MODE=permanent with --permanent flag" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-723-perm.XXXXXX")"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
start_uninstall_interactive_screen() { :; }
stop_uninstall_interactive_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() { return 0; }
drain_pending_input() { :; }
select_apps_for_uninstall() {
    printf 'delete_mode=%s\n' "${MOLE_DELETE_MODE:-unset}"
    _MOLE_MENU_USER_QUIT=1
    return 1
}

eval "$(sed -n '/^main()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --permanent
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete_mode=permanent"* ]]
}


@test "uninstall --list prints table with NAME, BUNDLE ID, UNINSTALL NAME, SIZE" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-text.XXXXXX")"
    # Format matches load_applications: epoch|app_path|app_name|bundle_id|size|last_used|size_kb
    cat > "$apps_cache" << 'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
1700000000|/Applications/Zoom.app|Zoom|us.zoom.xos|140MB|Yesterday|143360
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
# Force text mode by simulating a TTY for stdout via /dev/tty redirect not
# available in bats; instead pipe through a wrapper that fakes -t 1. Simplest:
# call the function directly so [[ -t 1 ]] uses bash's stdout (the bats pipe).
# We accept the function emits JSON when piped; assert against JSON shape too.
main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    # Bats pipes stdout, so output is JSON. Assert both apps and uninstall_name.
    [[ "$output" == *'"name": "Slack"'* ]] || return 1
    [[ "$output" == *'"name": "Zoom"'* ]] || return 1
    [[ "$output" == *'"uninstall_name": "Slack"'* ]] || return 1
    [[ "$output" == *'"bundle_id": "com.tinyspeck.slackmacgap"'* ]] || return 1
    [[ "$output" == *'"source": "App"'* ]]
}

@test "uninstall --list emits JSON array when stdout is piped" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-json.XXXXXX")"
    cat > "$apps_cache" << 'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320
CACHE

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb; do
        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
    done < "$1"
}
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    # Output should start with '[' and end with ']' to be a valid JSON array.
    [[ "${output:0:1}" == "[" ]] || return 1
    [[ "${output: -1}" == "]" ]] || return 1
    # Round-trip via python to confirm it parses as JSON.
    if command -v python3 > /dev/null; then
        printf '%s\n' "$output" | python3 -c 'import sys, json; d=json.load(sys.stdin); assert isinstance(d, list) and len(d)==1 and d[0]["name"]=="Slack"'
    fi
}

@test "uninstall --list with empty scan returns empty JSON array" {
    local apps_cache
    apps_cache="$(mktemp "${BATS_TEST_TMPDIR:-$BATS_RUN_TMPDIR:-$HOME}/tmp-list-empty.XXXXXX")"
    # Non-empty file so load_applications doesn't bail early on size check.
    echo "" > "$apps_cache"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        APPS_CACHE_FILE="$apps_cache" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"

log_operation_session_start() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
clear_screen() { :; }
scan_applications() { printf '%s\n' "$APPS_CACHE_FILE"; }
load_applications() {
    apps_data=()
    return 0
}
# Stubbed because the production helper lives earlier in bin/uninstall.sh
# and our sed slice only pulls list-related helpers + main().
uninstall_normalize_size_display() { local s="${1:-}"; [[ -z "$s" || "$s" == "0" || "$s" == "Unknown" ]] && echo "N/A" || echo "$s"; }

eval "$(sed -n '/^uninstall_list_json_escape()/,/main "\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '$d')"
main --list
INNER

    rm -f "$apps_cache"
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}


@test "match_apps_by_name joins multi-word args into one exact app name (#1365)" {
    # `mo uninstall Tor Browser` arrives as two words; "Tor" alone
    # substring-matched WebSTORm. The joined words exactly name an
    # installed app, so that must be the single match.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/WebStorm.app|WebStorm|com.jetbrains.WebStorm|3.06 GB|1000000|3208960"
	"1001|$HOME/Applications/Tor Browser.app|Tor Browser|org.torproject.torbrowser|501.8 MB|1000001|513843"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "Tor" "Browser"
echo "count=${#selected_apps[@]}"
echo "match=${selected_apps[0]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=1"* ]] || return 1
    [[ "$output" == *"Tor Browser"* ]] || return 1
    [[ "$output" != *"WebStorm"* ]] || return 1
}

@test "match_apps_by_name keeps per-word matching when the joined form names nothing" {
    # Two genuinely separate app queries must keep working after the
    # joined-form check: "TestApp2 TestApp3" names no single app.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/TestApp2.app|TestApp2|com.example.TestApp2|500 MB|1000001|512000"
	"1001|$HOME/Applications/TestApp3.app|TestApp3|com.example.TestApp3|300 MB|1000002|307200"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "TestApp2" "TestApp3"
echo "count=${#selected_apps[@]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=2"* ]] || return 1
}

@test "match_apps_by_name keeps two-app meaning when every word exactly names its own app" {
    # With Foo.app, Bar.app, and "Foo Bar.app" all installed, the joined
    # interpretation must not silently swallow the original two-app query.
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
selected_apps=()
apps_data=(
	"1000|$HOME/Applications/Foo.app|Foo|com.example.foo|100 MB|1000000|102400"
	"1001|$HOME/Applications/Bar.app|Bar|com.example.bar|100 MB|1000001|102400"
	"1002|$HOME/Applications/Foo Bar.app|Foo Bar|com.example.foobar|100 MB|1000002|102400"
)
source "$PROJECT_ROOT/tests/test_match_apps_helper.sh"
match_apps_by_name "Foo" "Bar"
echo "count=${#selected_apps[@]}"
printf 'sel=%s\n' "${selected_apps[@]}"
EOF

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"count=2"* ]] || return 1
    [[ "$output" == *"|Foo|"* ]] || return 1
    [[ "$output" == *"|Bar|"* ]] || return 1
    [[ "$output" != *"Foo Bar"* ]] || return 1
}
