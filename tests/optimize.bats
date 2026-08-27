#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	ORIGINAL_HOME="${HOME:-}"
	export ORIGINAL_HOME

	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize.XXXXXX")"
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

@test "execute_optimization rejects unknown action" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
execute_optimization unknown_action
EOF

	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"Unknown action"* ]] || return 1
}

@test "execute_optimization rejects unknown action before whitelist policy" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_whitelisted() { return 0; }
execute_optimization unknown_action
EOF

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown action"* ]]
}

@test "execute_optimization skips whitelisted task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
is_whitelisted() { [[ "$1" == "ssd_trim" ]]; }
opt_ssd_trim() { echo "UNEXPECTED_SSD_TRIM"; }
optimize_outcomes_reset
execute_optimization ssd_trim
[[ "$(optimize_outcome_count skipped)" == "1" ]] || exit 1
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"Skipped (whitelisted): SSD TRIM"* ]] || return 1
	[[ "$output" != *"UNEXPECTED_"* ]]
}

@test "optimize whitelist is loaded before system health checks" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
load_line=$(awk '/load_whitelist "optimize"/ { print NR; exit }' "$PROJECT_ROOT/bin/optimize.sh")
health_line=$(awk '/^[[:space:]]*show_system_health / { print NR; exit }' "$PROJECT_ROOT/bin/optimize.sh")
if [[ "$load_line" -lt "$health_line" ]]; then
    echo "ordered"
fi
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ordered"* ]]
}

@test "optimize interrupt cleanup disables the EXIT trap before cleanup" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
body=$(sed -n '/^handle_interrupt() {/,/^}/p' "$PROJECT_ROOT/bin/optimize.sh")
trap_line=$(printf '%s\n' "$body" | awk '/trap - EXIT/ { print NR; exit }')
cleanup_line=$(printf '%s\n' "$body" | awk '/^[[:space:]]*cleanup_all 130$/ { print NR; exit }')
[[ -n "$trap_line" && -n "$cleanup_line" && "$trap_line" -lt "$cleanup_line" ]]
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "show_system_health formats floats under comma-decimal locales (#1220)" {
	# Find an installed locale whose decimal separator is a comma.
	local comma_locale="" candidate
	for candidate in fr_FR.UTF-8 de_DE.UTF-8 pt_BR.UTF-8 es_ES.UTF-8 it_IT.UTF-8 nl_NL.UTF-8; do
		if [[ "$(LC_ALL="$candidate" /bin/bash -c 'printf "%.1f" 1' 2> /dev/null)" == "1,0" ]]; then
			comma_locale="$candidate"
			break
		fi
	done
	[[ -n "$comma_locale" ]] || skip "no comma-decimal locale installed"

	run env LC_ALL="$comma_locale" LANG="$comma_locale" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
eval "$(sed -n '/^json_get_value()/,/^}$/p' "$PROJECT_ROOT/bin/optimize.sh")"
eval "$(sed -n '/^show_system_health()/,/^}$/p' "$PROJECT_ROOT/bin/optimize.sh")"
ICON_ADMIN="*"
health_json='{"memory_used_gb": 5.70, "memory_total_gb": 8.00, "disk_used_gb": 287.86, "disk_total_gb": 351.19, "uptime_days": 6.1}'
show_system_health "$health_json"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"6/8 GB RAM"* ]] || return 1
	[[ "$output" == *"288/351 GB Disk"* ]] || return 1
	[[ "$output" == *"Uptime 6d"* ]]
}

@test "optimize whitelist items include task ids" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/manage/whitelist.sh"
get_optimize_whitelist_items
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"SSD TRIM|ssd_trim|optimize_task"* ]] || return 1
	[[ "$output" == *"DNS Cache Flush|dns_cache_flush|optimize_task"* ]]
}

@test "optimize_sudo_available returns false when sudo session was denied" {
	run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_OPTIMIZE_SUDO_AVAILABLE="false" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
if optimize_sudo_available; then
	echo "WRONG: returned true under denied sudo"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "optimize_sudo_available returns false in test mode regardless of optimize entrypoint" {
	# Ad-hoc task invocation under MOLE_TEST_NO_AUTH must hard-deny sudo
	# even when MOLE_OPTIMIZE_SUDO_AVAILABLE was never set by bin/optimize.sh.
	run env PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
unset MOLE_OPTIMIZE_SUDO_AVAILABLE
if optimize_sudo_available; then
	echo "WRONG: leaked sudo to test-mode caller"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "sudo-required optimize tasks short-circuit without invoking sudo when access denied" {
	run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_OPTIMIZE_SUDO_AVAILABLE="false" \
		MOLE_DRY_RUN="0" \
		/bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

trace="$HOME/sudo_calls.log"
: > "$trace"
sudo() {
	printf 'sudo %s\n' "$*" >> "$trace"
	return 0
}
export -f sudo

# Force the plan-producing branch so the sudo-gated plan line is reached.
command() {
	if [[ "$1" == "-v" && "$2" == "fstrim" ]]; then
		return 0
	fi
	builtin command "$@"
}
_linux_has_ssd_device() { return 0; }

execute_optimization ssd_trim 2>&1 || true

if [[ -s "$trace" ]]; then
	echo "WRONG: sudo invoked while denied:"
	cat "$trace"
	exit 1
fi
if [[ "$(optimize_outcome_count skipped)" != "1" ]]; then
	echo "WRONG: expected one skipped outcome"
	exit 1
fi
echo "ok"
EOF

	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]] || return 1
	[[ "$output" == *"Skipped (admin access required)"* ]]
}
