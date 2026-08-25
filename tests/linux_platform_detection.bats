#!/usr/bin/env bats

# shellcheck disable=SC2016  # payloads intentionally evaluate vars in the inner bash
# Platform detection, distro module selection, and path resolvers.
# Fixtures: tests/fixtures/linux/platform/

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
	FIXTURE_ROOT="$PROJECT_ROOT/tests/fixtures/linux/platform"
	export FIXTURE_ROOT
}

setup() {
	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-platform-home.XXXXXX")"
	export HOME
	# Immunity against cross-suite leakage: scripts/test.sh sources
	# lib/core/file_ops.sh into its own shell, which exports MOLE_PLATFORM
	# (and friends) into every bats worker. Detection tests must see the
	# uname stubs, not an inherited preset.
	unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
		MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED || true
}

teardown() {
	rm -rf "$HOME"
}

@test "platform detects linux on a Linux kernel and selects generic for unknown distro" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/unknown"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf '%s|%s|%s\n' "$MOLE_PLATFORM" "$MOLE_DISTRO_ID" "$(distro_id)"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "linux|mysterix|generic" ]] || { echo "$output"; return 1; }
}

@test "platform refuses an unsupported kernel with a clear message" {
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$FIXTURE_ROOT/uname-sunos:$PATH" /bin/bash --noprofile --norc -c '
set -euo pipefail
source "$PROJECT_ROOT/lib/platform/platform.sh"
'
	[ "$status" -eq 1 ]
	[[ "$output" == *"mole: unsupported platform"* ]] || { echo "$output"; return 1; }
}

@test "platform detects darwin via uname and keeps the legacy macOS state dir" {
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$FIXTURE_ROOT/uname-darwin:$PATH" /bin/bash --noprofile --norc -c '
set -euo pipefail
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s\n" "$MOLE_PLATFORM" "$(mole_state_dir)"
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "darwin|$HOME/Library/Logs/mole" ]] || { echo "$output"; return 1; }
}

@test "distro detection selects the module matching os-release ID" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf '%s|%s\n' "$MOLE_DISTRO_ID" "$(distro_id)"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "arch|arch" ]] || { echo "$output"; return 1; }
}

@test "distro detection falls back through the ID_LIKE chain" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/idlike-arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf '%s|%s\n' "$MOLE_DISTRO_ID" "$(distro_id)"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# MOLE_DISTRO_ID stays the real ID; the capability module comes from ID_LIKE.
	[[ "$output" == "endeavouros|arch" ]] || { echo "$output"; return 1; }
}

@test "distro detection falls back to generic when no module matches ID or ID_LIKE" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/unknown"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf '%s|%s|%s\n' "$MOLE_DISTRO_ID" "$(distro_id)" "$(distro_pkg_manager)"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "mysterix|generic|" ]] || { echo "$output"; return 1; }
}

@test "distro detection falls back to generic when os-release has no ID" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/no-id"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf '%s|%s\n' "${MOLE_DISTRO_ID-unset}" "$(distro_id)"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "|generic" ]] || { echo "$output"; return 1; }
}

@test "path resolvers honor temp HOME and XDG overrides" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/no-id"
source "$PROJECT_ROOT/lib/platform/platform.sh"
a="$(mole_state_dir)|$(mole_cache_dir)|$(mole_config_dir)|$(linux_trash_dir)"
XDG_STATE_HOME="$HOME/xdg-state"
XDG_CACHE_HOME="$HOME/xdg-cache"
XDG_CONFIG_HOME="$HOME/xdg-config"
XDG_DATA_HOME="$HOME/xdg-data"
b="$(mole_state_dir)|$(mole_cache_dir)|$(mole_config_dir)|$(linux_trash_dir)"
printf 'A:%s\nB:%s\n' "$a" "$b"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"A:$HOME/.local/state/mole|$HOME/.cache/mole|$HOME/.config/mole|$HOME/.local/share/Trash"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"B:$HOME/xdg-state/mole|$HOME/xdg-cache/mole|$HOME/xdg-config/mole|$HOME/xdg-data/Trash"* ]] || { echo "$output"; return 1; }
}

@test "mole_trash_cmd echoes gio only when gio is available" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/no-id"
source "$PROJECT_ROOT/lib/platform/platform.sh"
with_gio="$(mole_trash_cmd)"
restricted_path="$(mktemp -d)"
ln -s "$(command -v uname)" "$restricted_path/uname"
ln -s "$(command -v dirname)" "$restricted_path/dirname"
without_gio="$(PATH="$restricted_path" /bin/bash -c 'source "$PROJECT_ROOT/lib/platform/platform.sh"; mole_trash_cmd')"
printf '%s|%s\n' "$with_gio" "$without_gio"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "gio|" ]] || { echo "$output"; return 1; }
}

@test "common.sh sources platform between base and log so log paths follow the state dir" {
	run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/no-id"
source "$PROJECT_ROOT/lib/core/common.sh"
declare -F mole_state_dir > /dev/null || exit 1
expected_state="$HOME/.local/state/mole"
[[ "$LOG_FILE" == "$expected_state/mole.log" ]] || exit 1
[[ "$DEBUG_LOG_FILE" == "$expected_state/mole_debug_session.log" ]] || exit 1
[[ "$OPERATIONS_LOG_FILE" == "$expected_state/operations.log" ]] || exit 1
printf 'OK %s\n' "$MOLE_PLATFORM"
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == OK* ]] || { echo "$output"; return 1; }
}

@test "log paths stay under ~/Library/Logs/mole on darwin (byte-equivalent to legacy)" {
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$FIXTURE_ROOT/uname-darwin:$PATH" /bin/bash --noprofile --norc -c '
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
source "$PROJECT_ROOT/lib/core/log.sh"
printf "%s|%s|%s\n" "$LOG_FILE" "$DEBUG_LOG_FILE" "$OPERATIONS_LOG_FILE"
'

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local expected="$HOME/Library/Logs/mole"
	[[ "$output" == "$expected/mole.log|$expected/mole_debug_session.log|$expected/operations.log" ]] || { echo "$output"; return 1; }
}
