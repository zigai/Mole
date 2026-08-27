#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-removals.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-removals."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "package cache trim applies the distro plan" {
	run env HOME="$TEST_HOME/pkg-cache" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

distro_pkg_cache_summary() { echo "Package cache: 1.2G"; }
distro_pkg_cache_plan() { printf 'pacman -Sc --noconfirm\n'; }
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/pacman"
chmod +x "$HOME/bin/pacman"
PATH="$HOME/bin:$PATH"

execute_optimization pkg_cache_trim
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Package cache: 1.2G"* ]] || return 1
	[[ "$output" == *"Ran: pacman -Sc --noconfirm"* ]] || return 1
}

@test "flatpak cleanup reports a failed uninstall command" {
	run env HOME="$TEST_HOME/flatpak-fail" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"

distro_flatpak_unused_plan() { printf 'flatpak uninstall --unused --assumeyes\n'; }
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nexit 4\n' > "$HOME/bin/flatpak"
chmod +x "$HOME/bin/flatpak"
PATH="$HOME/bin:$PATH"

execute_optimization flatpak_unused
[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Failed (exit=4): flatpak uninstall --unused --assumeyes"* ]] || return 1
}

@test "journal vacuum without systemd support is unavailable" {
	run env HOME="$TEST_HOME/journal-none" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/tasks.sh"
distro_journal_vacuum_plan() { :; }

execute_optimization journal_vacuum
[[ "$(optimize_outcome_count unavailable)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Journal vacuum unavailable (systemd not present)"* ]] || return 1
}
