#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-probes.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-probes."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "sudo-gated trim is skipped when admin access is denied" {
	run env HOME="$TEST_HOME/admin" PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_TEST_NO_AUTH MOLE_TEST_MODE

mkdir -p "$HOME/bin"
printf '#!/bin/bash\necho UNEXPECTED_FSTRIM\n' > "$HOME/bin/fstrim"
chmod +x "$HOME/bin/fstrim"
PATH="$HOME/bin:$PATH"
_linux_has_ssd_device() { return 0; }

execute_optimization ssd_trim
[[ "$(optimize_outcome_count skipped)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count failed)" == "0" ]] || exit 2
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"admin access required"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_FSTRIM"* ]] || return 1
}

@test "failed plan command reports a failed task outcome" {
	run env HOME="$TEST_HOME/flush-fail" PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE=false /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 9\n' > "$HOME/bin/resolvectl"
chmod +x "$HOME/bin/resolvectl"
PATH="$HOME/bin:$PATH"

execute_optimization dns_cache_flush
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed (exit=9): resolvectl flush-caches"* ]] || return 1
}

@test "missing distro capabilities report unavailable outcomes" {
	run env HOME="$TEST_HOME/unavailable" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
PATH=/nonexistent

execute_optimization ssd_trim
execute_optimization dns_cache_flush
[[ "$(optimize_outcome_count unavailable)" == "2" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"unavailable"* ]] || return 1

}
@test "orphan scan without findings reports an unchanged outcome" {
	run env HOME="$TEST_HOME/orphans-clean" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
distro_orphans_list() { :; }
distro_orphans_remove_plan() { echo "UNEXPECTED_PLAN"; }

execute_optimization orphan_packages
[[ "$(optimize_outcome_count unchanged)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"No orphaned packages found"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_PLAN"* ]] || return 1
}

@test "failed units report renders findings as attention" {
	run env HOME="$TEST_HOME/units" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/bin"
cat > "$HOME/bin/systemctl" <<'STUB'
#!/bin/bash
echo "nginx.service    loaded failed failed  A failed unit"
echo "docker.service   loaded failed failed  Another failed unit"
STUB
chmod +x "$HOME/bin/systemctl"
PATH="$HOME/bin:$PATH"

execute_optimization failed_units_report
[[ "$(optimize_outcome_count attention)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed systemd units (2)"* ]] || return 1
	[[ "$output" == *"Inspect with: systemctl --failed"* ]] || return 1
}

@test "dry-run plans report applied outcomes without executing" {
	run env HOME="$TEST_HOME/dry-run" PROJECT_ROOT="$PROJECT_ROOT" MOLE_DRY_RUN=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

mkdir -p "$HOME/bin"
printf '#!/bin/bash\necho UNEXPECTED_FSTRIM\n' > "$HOME/bin/fstrim"
chmod +x "$HOME/bin/fstrim"
PATH="$HOME/bin:$PATH"
_linux_has_ssd_device() { return 0; }

execute_optimization ssd_trim
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Would run: sudo fstrim -av"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_FSTRIM"* ]] || return 1
}

@test "optimize external probes use bounded execution" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
tasks_file="$PROJECT_ROOT/lib/optimize/tasks.sh"

plan_body=$(sed -n '/^_opt_linux_execute_plan() {/,/^}/p' "$tasks_file")
units_body=$(sed -n '/^opt_failed_units_report() {/,/^}/p' "$tasks_file")

[[ "$plan_body" == *'run_with_timeout "$MOLE_OPTIMIZE_LINUX_CMD_TIMEOUT"'* ]] || exit 1
[[ "$units_body" == *'run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC"'* ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize tasks never toggle the caller errexit option" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
tasks_file="$PROJECT_ROOT/lib/optimize/tasks.sh"
if grep -nE '^[[:space:]]*set [+-]e([[:space:]]|$)' "$tasks_file"; then
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
