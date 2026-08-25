#!/usr/bin/env bats
# shellcheck disable=SC2016  # payloads intentionally evaluate vars in the inner bash

# Distro capability modules: arch.sh plans against stubbed tools,
# generic.sh safe subset. Fixtures: tests/fixtures/linux/platform/

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
	FIXTURE_ROOT="$PROJECT_ROOT/tests/fixtures/linux/platform"
	export FIXTURE_ROOT
}

setup() {
	HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-platform-distro-home.XXXXXX")"
	export HOME
	# Immunity against cross-suite leakage: scripts/test.sh sources
	# lib/core/file_ops.sh into its own shell, which exports MOLE_PLATFORM
	# (and friends) into every bats worker. Detection must follow the
	# stubbed uname/os-release fixtures, not an inherited preset.
	unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
		MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED || true
}

teardown() {
	rm -rf "$HOME"
}

# Build a PATH dir holding exactly the given tools: bare names link to the
# fixture stub bin dir, absolute paths link through. Keeps system tools like
# journalctl from leaking into have_cmd() probes.
make_stub_path() {
	local dest="$1"
	shift
	mkdir -p "$dest"
	local tool name
	# platform.sh shells out to uname during detection.
	ln -s "$(command -v uname)" "$dest/uname"
	for tool in "$@"; do
		if [[ "$tool" == */* ]]; then
			name="$(basename "$tool")"
			ln -s "$tool" "$dest/$name"
		else
			ln -s "$FIXTURE_ROOT/bin/$tool" "$dest/$tool"
		fi
	done
	printf '%s\n' "$dest"
}

@test "arch distro_init caches optional tool detection once" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman paccache journalctl systemctl flatpak yay paru "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s|%s|%s|%s\n" "$DISTRO_PKG_CACHE_TOOL" "$DISTRO_JOURNALCTL" "$DISTRO_SYSTEMCTL" "$DISTRO_FLATPAK" "$DISTRO_AUR_HELPER"
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "paccache|journalctl|systemctl|flatpak|paru" ]] || { echo "$output"; return 1; }
}

@test "arch package cache plan uses paccache when available" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman paccache "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_pkg_cache_plan 3
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	printf '%s\n' "$output" | grep -Fxq 'sudo paccache -rk3' || { echo "$output"; return 1; }
	printf '%s\n' "$output" | grep -Fxq 'sudo paccache -ruk0' || { echo "$output"; return 1; }
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ] || { echo "$output"; return 1; }
}

@test "arch package cache plan falls back to pacman -Sc without paccache" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_pkg_cache_plan 5
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == 'sudo pacman -Sc --noconfirm' ]] || { echo "$output"; return 1; }
}

@test "arch orphans list and remove plan reflect pacman -Qtdq output" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman paccache "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
echo "--list--"
distro_orphans_list
echo "--plan--"
distro_orphans_remove_plan
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"--list--"$'\n'"orphan-a"$'\n'"orphan-b"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"--plan--"$'\n'"sudo pacman -Rns --noconfirm orphan-a orphan-b"* ]] || { echo "$output"; return 1; }
	# The remove plan must be a single line.
	[[ "$output" != *"--noconfirm orphan-a"$'\n'"orphan-b"* ]] || { echo "$output"; return 1; }
}

@test "arch orphans plans stay empty when pacman reports none" {
	stub_dir="$(mktemp -d)"
	mkdir -p "$stub_dir"
	ln -s "$FIXTURE_ROOT/bin-noorphans/pacman" "$stub_dir/pacman"
	ln -s "$(command -v uname)" "$stub_dir/uname"
	for tool in tr sed cut du; do
		ln -s "$(command -v "$tool")" "$stub_dir/$tool"
	done
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s]\n" "$(distro_orphans_list)" "$(distro_orphans_remove_plan)"
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "[][]" ]] || { echo "$output"; return 1; }
}

@test "arch journal vacuum and flatpak plans follow detected tools" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
echo "--journal--"
distro_journal_vacuum_plan
echo "--flatpak--"
distro_flatpak_unused_plan
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == *"--journal--"$'\n'"sudo journalctl --vacuum-size=100M --vacuum-time=2weeks"$'\n'"--flatpak--"$'\n'"flatpak uninstall --unused --noninteractive"* ]] || { echo "$output"; return 1; }
}

@test "arch journal and flatpak plans are empty when the tools are missing" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s]\n" "$(distro_journal_vacuum_plan)" "$(distro_flatpak_unused_plan)"
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "[][]" ]] || { echo "$output"; return 1; }
}

@test "arch AUR cache dirs follow detected helpers" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" yay paru "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc <<EOF
set -euo pipefail
PATH="$stub_dir:\$PATH"
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_aur_cache_dirs
EOF

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "$HOME/.cache/yay"$'\n'"$HOME/.cache/paru" ]] || { echo "$output"; return 1; }

	# Without any helper the same query echoes nothing.
	stub_dir2="$(mktemp -d)"
	make_stub_path "$stub_dir2" pacman "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir2" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
out="$(distro_aur_cache_dirs)"
printf "[%s]\n" "$out"
'
	rm -rf "$stub_dir" "$stub_dir2"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "[]" ]] || { echo "$output"; return 1; }
}

@test "arch pkg cache summary reports size or stays empty" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" pacman "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" "/usr/bin/du" "/usr/bin/timeout" > /dev/null

	# Existing cache dir: human one-liner with the du size.
	fake_cache="$(mktemp -d)"
	dd if=/dev/zero of="$fake_cache/pkg.cache" bs=1k count=64 status=none
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" MOLE_PKG_CACHE_DIR="$fake_cache" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
# distro_pkg_cache_summary bounds du through run_with_timeout, which
# production loads via lib/core/common.sh; platform.sh standalone does not
# provide it, so pull in the same helper the production loader uses.
source "$PROJECT_ROOT/lib/core/timeout.sh"
distro_pkg_cache_summary
'
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	local line
	line="$(printf '%s\n' "$output")"
	[[ "$line" == "Pacman package cache: "* && -n "$line" ]] || { echo "$output"; return 1; }

	# Missing cache dir: empty output, success.
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" MOLE_PKG_CACHE_DIR="$HOME/does-not-exist" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/arch"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s]\n" "$(distro_pkg_cache_summary)"
'
	rm -rf "$stub_dir" "$fake_cache"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "[]" ]] || { echo "$output"; return 1; }
}

@test "generic module keeps package and journal surface inert but honors flatpak" {
	stub_dir="$(mktemp -d)"
	make_stub_path "$stub_dir" flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
	run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/no-id"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s\n" "$(distro_id)" "$(distro_pkg_manager)"
out=""
out+="[$(distro_pkg_cache_plan 3)]"
out+="[$(distro_orphans_list)]"
out+="[$(distro_orphans_remove_plan)]"
out+="[$(distro_journal_vacuum_plan)]"
out+="[$(distro_aur_cache_dirs)]"
printf "inert:%s\n" "$out"
printf "flatpak:%s\n" "$(distro_flatpak_unused_plan)"
'
	rm -rf "$stub_dir"

	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	[[ "$output" == "generic|"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"inert:[][][][][]"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"flatpak:flatpak uninstall --unused --noninteractive"* ]] || { echo "$output"; return 1; }
}
