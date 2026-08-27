#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    # Immunity against cross-suite leakage: scripts/test.sh sources
    # lib/core/file_ops.sh into its own shell, which exports MOLE_PLATFORM
    # (and friends) into every bats worker. Unpinned payloads must not
    # depend on leaked platform overrides.
    unset MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED || true
}

@test "optimize exposes no manual memory purge task (#1309)" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

for action in "${MOLE_OPTIMIZE_ACTIONS[@]}"; do
    [[ "$action" != "memory_pressure_relief" ]] || exit 1
done
if declare -F is_memory_pressure_high > /dev/null 2>&1; then
    exit 2
fi
if declare -F opt_memory_pressure_relief > /dev/null 2>&1; then
    exit 3
fi
if command grep -nE '(^|[^[:alnum:]_])(/usr/sbin/)?purge([[:space:]]|$)' "$PROJECT_ROOT/lib/optimize/tasks.sh"; then
    exit 4
fi
EOF

	[ "$status" -eq 0 ] || return 1
}

@test "default optimize catalog never restarts Dock (#1300)" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"

if optimize_catalog_handler_for dock_refresh >/dev/null 2>&1; then
    echo "Dock refresh is still registered"
    exit 1
fi
if grep -nE 'killall[[:space:]]+Dock' "$PROJECT_ROOT/lib/optimize/tasks.sh"; then
    echo "Optimize still terminates Dock"
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize catalog preserves the complete public task contract" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"

expected=$(cat <<'CONTRACT'
pkg_cache_trim|opt_pkg_cache_trim|Package Cache Trim|Package Cache Trim|Trim package manager cache, keeping recent versions|true
journal_vacuum|opt_journal_vacuum|Journal Vacuum|Journal Vacuum|Shrink the systemd journal to 100M / 2 weeks|true
orphan_packages|opt_orphan_packages|Orphaned Packages|Orphaned Packages|Report packages orphaned by upgrades and offer their removal|true
flatpak_unused|opt_flatpak_unused|Flatpak Cleanup|Flatpak Cleanup|Uninstall unused Flatpak runtimes and extensions|true
ssd_trim|opt_ssd_trim|SSD TRIM|SSD TRIM|Discard unused blocks on SSDs via fstrim -av|true
failed_units_report|opt_failed_units_report|Failed Units Report|Failed Units Report|List failed systemd units (read-only)|true
dns_cache_flush|opt_dns_cache_flush|DNS Cache Flush|DNS Cache Flush|Flush the systemd-resolved DNS cache|true
CONTRACT
)

actual=""
for ((index = 0; index < ${#MOLE_OPTIMIZE_ACTIONS[@]}; index++)); do
    printf -v row '%s|%s|%s|%s|%s|%s' \
        "${MOLE_OPTIMIZE_ACTIONS[$index]}" \
        "${MOLE_OPTIMIZE_HANDLERS[$index]}" \
        "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}" \
        "${MOLE_OPTIMIZE_WHITELIST_NAMES[$index]}" \
        "${MOLE_OPTIMIZE_DESCRIPTIONS[$index]}" \
        "${MOLE_OPTIMIZE_SAFE_VALUES[$index]}"
    actual+="${actual:+$'\n'}$row"
done

[[ "$actual" == "$expected" ]] || { diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"); exit 1; }
optimize_catalog_validate || exit 1
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize catalog resolves handler and display ownership together" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"

[[ "$(optimize_catalog_handler_for journal_vacuum)" == "opt_journal_vacuum" ]] || exit 1
[[ "$(optimize_catalog_health_name_for journal_vacuum)" == "Journal Vacuum" ]] || exit 1
if optimize_catalog_health_name_for unknown_action; then
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize whitelist preserves every public task label and action" {
    run env HOME="$BATS_TEST_TMPDIR/home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"

expected=$(cat <<'WHITELIST'
Package Cache Trim|pkg_cache_trim|optimize_task
Journal Vacuum|journal_vacuum|optimize_task
Orphaned Packages|orphan_packages|optimize_task
Flatpak Cleanup|flatpak_unused|optimize_task
SSD TRIM|ssd_trim|optimize_task
Failed Units Report|failed_units_report|optimize_task
DNS Cache Flush|dns_cache_flush|optimize_task
WHITELIST
)

actual=$(get_optimize_whitelist_items)
[[ "$actual" == "$expected" ]] || { diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"); exit 1; }
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize catalog rejects duplicate identities and unsafe tasks" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail

if /bin/bash --noprofile --norc < <(
    awk '!changed && /opt_journal_vacuum/ {sub(/opt_journal_vacuum/, "opt_pkg_cache_trim"); changed=1} {print}' \
        "$PROJECT_ROOT/lib/optimize/catalog.sh"
); then
    echo "duplicate handler passed validation"
    exit 1
fi

if /bin/bash --noprofile --norc < <(
    awk '!changed && / true$/ {sub(/ true$/, " false"); changed=1} {print}' \
        "$PROJECT_ROOT/lib/optimize/catalog.sh"
); then
    echo "unsafe task passed validation"
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Duplicate optimize task handler: opt_pkg_cache_trim"* ]] || return 1
    [[ "$output" == *"Optimize task is not safe for automatic execution: pkg_cache_trim"* ]] || return 1
}

@test "optimize catalog resolves handlers by exact action id" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"

if ! handler=$(optimize_catalog_handler_for dns_cache_flush); then
    echo "known action did not resolve"
    exit 1
fi
[[ "$handler" == "opt_dns_cache_flush" ]] || exit 1
if optimize_catalog_handler_for unknown_action; then
    echo "unknown action resolved"
    exit 1
fi
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimization task module implements every catalog handler" {
    run env HOME="$BATS_TEST_TMPDIR/home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

[[ ${#MOLE_OPTIMIZE_ACTIONS[@]} -eq 7 ]] || exit 1
for handler in "${MOLE_OPTIMIZE_HANDLERS[@]}"; do
    if ! declare -F "$handler" >/dev/null; then
        echo "missing handler: $handler"
        exit 1
    fi
done
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize catalog consumers can be sourced repeatedly" {
    run env HOME="$BATS_TEST_TMPDIR/home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
source "$PROJECT_ROOT/lib/check/health_json.sh"
source "$PROJECT_ROOT/lib/check/health_json.sh"

declare -F execute_optimization >/dev/null || exit 1
declare -F generate_health_json >/dev/null || exit 1
EOF

    [[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
