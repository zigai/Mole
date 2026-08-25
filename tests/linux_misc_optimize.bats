#!/usr/bin/env bats
# Linux optimize catalog registration and linux handler behavior.
# Handlers consume the distro capability contract via stubbed distro functions.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-opt-linux.XXXXXX")"
    export HOME

    FIXTURE_BIN="${BATS_TEST_DIRNAME}/fixtures/linux/misc/bin"
    export FIXTURE_BIN

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

@test "linux platform registers exactly the seven linux actions" {
    run env MOLE_PLATFORM=linux /bin/bash --noprofile --norc <<EOF
set -uo pipefail
source '$PROJECT_ROOT/lib/optimize/tasks.sh'
echo "count=\${#MOLE_OPTIMIZE_ACTIONS[@]}"
printf '%s\n' "\${MOLE_OPTIMIZE_ACTIONS[@]}"
for handler in opt_pkg_cache_trim opt_journal_vacuum opt_orphan_packages \
    opt_flatpak_unused opt_ssd_trim opt_failed_units_report opt_dns_cache_flush; do
    declare -F "\$handler" > /dev/null && echo "ok \$handler" || echo "MISSING \$handler"
done
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=7"* ]]
    for action in pkg_cache_trim journal_vacuum orphan_packages flatpak_unused ssd_trim failed_units_report dns_cache_flush; do
        grep -qx "$action" <<< "$output"
    done
    [[ "$output" != *"MISSING"* ]]
    [[ "$output" != *"system_maintenance"* ]]
}

@test "darwin keeps the historical action set untouched" {
    run env MOLE_PLATFORM=darwin /bin/bash --noprofile --norc <<EOF
set -uo pipefail
source '$PROJECT_ROOT/lib/optimize/catalog.sh'
echo "count=\${#MOLE_OPTIMIZE_ACTIONS[@]}"
printf '%s\n' "\${MOLE_OPTIMIZE_ACTIONS[@]}"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=21"* ]]
    [[ "$output" == *"system_maintenance"* ]]
    [[ "$output" == *"coreduet_cleanup"* ]]
    for action in pkg_cache_trim journal_vacuum orphan_packages flatpak_unused ssd_trim failed_units_report dns_cache_flush; do
        ! grep -qx "$action" <<< "$output"
    done
}

@test "unset platform defaults to the darwin catalog (legacy source path)" {
    run env -u MOLE_PLATFORM /bin/bash --noprofile --norc <<EOF
set -uo pipefail
source '$PROJECT_ROOT/lib/optimize/catalog.sh'
echo "count=\${#MOLE_OPTIMIZE_ACTIONS[@]}"
printf '%s\n' "\${MOLE_OPTIMIZE_ACTIONS[@]}" | grep -x system_maintenance
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"count=21"* ]]
}

@test "package cache trim previews the distro plan in dry-run" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux MOLE_DRY_RUN=1 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
distro_pkg_cache_plan() { printf 'sudo paccache -rk1\npaccache -ruk0\n'; }
distro_pkg_cache_summary() { echo 'Package cache: 2.1 GiB'; }
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization pkg_cache_trim
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Package cache: 2.1 GiB"* ]]
    [[ "$output" == *"Would run: sudo paccache -rk1"* ]]
    [[ "$output" == *"Would run: paccache -ruk0"* ]]
}

@test "orphan removal stays read-only without a TTY and reports attention" {
    local marker="$HOME/orphan-marker"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        MOLE_ORPHAN_MARKER="$marker" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
distro_orphans_list() { printf 'linux-header\nold-kernel\n'; }
distro_orphans_remove_plan() { echo "sudo touch $MOLE_ORPHAN_MARKER"; }
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization orphan_packages
[[ ! -e "$MOLE_ORPHAN_MARKER" ]] || { echo "MARKER_CREATED"; exit 1; }
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned packages (2)"* ]]
    [[ "$output" == *"linux-header"* ]]
    [[ "$output" == *"Review and rerun interactively"* ]]
    [[ "$output" != *"MARKER_CREATED"* ]]
}

@test "dns cache flush runs resolvectl when present" {
    local marker="$HOME/dns-marker"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        PATH="$FIXTURE_BIN:$PATH" MOLE_FIXTURE_MARKER="$marker" \
        MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT=5 \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization dns_cache_flush
EOF

    [ "$status" -eq 0 ]
    [ -f "$marker" ]
    grep -q 'resolvectl flush-caches' "$marker"
}

@test "failed units report lists units read-only" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        PATH="$FIXTURE_BIN:$PATH" \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
run_with_timeout() { local t=$1; shift; "$@"; }
export -f run_with_timeout
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization failed_units_report
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Failed systemd units (2)"* ]]
    [[ "$output" == *"nginx.service"* ]]
    [[ "$output" == *"docker.service"* ]]
}

@test "journal vacuum reports unavailable without a plan" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux \
        /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
distro_journal_vacuum_plan() { echo ""; }
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization journal_vacuum
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Journal vacuum unavailable"* ]]
}
