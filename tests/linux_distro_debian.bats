#!/usr/bin/env bats
# shellcheck disable=SC2016  # payloads intentionally evaluate vars in the inner bash

# Debian/Ubuntu distro capability module: debian.sh plans against a stubbed
# apt-get. Fixtures: tests/fixtures/linux/platform/ (os-release/debian,
# os-release/ubuntu); the apt-get stub is generated per test below and reads
# its --simulate transcript from $MOLE_FAKE_APT_SIMULATE.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    FIXTURE_ROOT="$PROJECT_ROOT/tests/fixtures/linux/platform"
    export FIXTURE_ROOT
}

setup() {
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-platform-debian-home.XXXXXX")"
    export HOME
    # Immunity against cross-suite leakage, mirroring
    # tests/linux_platform_distro.bats: detection must follow the stubbed
    # uname/os-release fixtures, not an inherited preset.
    unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
        MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED \
        MOLE_FAKE_APT_SIMULATE || true
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

# Write the fake apt-get into $1; $2 is a transcript file whose Remv lines
# drive the --simulate output via MOLE_FAKE_APT_SIMULATE.
install_apt_stub() {
    local dest_dir="$1" transcript="$2"
    cat > "$dest_dir/apt-get" <<'STUB'
#!/bin/bash
# Stub apt-get for Debian platform tests. Only autoremove --simulate emits
# anything; every other invocation stays silent and succeeds. Builtins only:
# the restricted test PATH carries no coreutils.
if [[ "${1:-}" == "autoremove" && "${2:-}" == "--simulate" && -n "${MOLE_FAKE_APT_SIMULATE:-}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
    done < "$MOLE_FAKE_APT_SIMULATE"
fi
exit 0
STUB
    chmod +x "$dest_dir/apt-get"
}

@test "debian module selected directly by ID=debian with apt tool detection" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s|%s|%s|%s|%s\n" "$(distro_id)" "$(distro_pkg_manager)" \
    "$DISTRO_PKG_CACHE_TOOL" "$DISTRO_JOURNALCTL" "$DISTRO_SYSTEMCTL" "$DISTRO_FLATPAK"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "debian|apt|apt|journalctl|systemctl|flatpak" ]] || { echo "$output"; return 1; }
}

@test "ubuntu ID resolves through the ID_LIKE=debian walk" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/ubuntu"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s|%s\n" "$MOLE_DISTRO_ID" "$(distro_id)" "$(distro_pkg_manager)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "ubuntu|debian|apt" ]] || { echo "$output"; return 1; }
}

@test "debian package cache plan echoes one sudo apt-get clean regardless of keep" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_pkg_cache_plan 5
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "sudo apt-get clean" ]] || { echo "$output"; return 1; }
    # Exactly one plan line: keep has no per-version retention knob here.
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ] || { echo "$output"; return 1; }
}

@test "debian package cache plan is empty when apt-get is absent" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s]\n" "$(distro_pkg_cache_plan 3)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[]" ]] || { echo "$output"; return 1; }
}

@test "debian pkg cache summary bounds du through run_with_timeout" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" "/usr/bin/du" > /dev/null

    fake_cache="$(mktemp -d)"
    dd if=/dev/zero of="$fake_cache/archive.deb" bs=1k count=64 status=none
    trace="$HOME/du.trace"
    touch "$trace"

    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_PKG_CACHE_DIR="$fake_cache" DU_TRACE="$trace" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
# distro_pkg_cache_summary bounds du through run_with_timeout, which
# production loads via lib/core/common.sh; platform.sh standalone does not
# provide it, so pull in the same helper the production loader uses, then
# wrap it to record the exact command line it was handed.
source "$PROJECT_ROOT/lib/core/timeout.sh"
run_with_timeout() {
    local duration="$1"
    shift
    echo "CALL:$*" >> "$DU_TRACE"
    "$@"
}
distro_pkg_cache_summary
'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "APT package cache: "* ]] || { echo "$output"; return 1; }
    local traced
    traced="$(cat "$trace")"
    [[ "$traced" == "CALL:du -sh $fake_cache" ]] || { echo "trace: $traced"; return 1; }

    # Missing cache dir: silent success, no du call at all.
    : > "$trace"
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_PKG_CACHE_DIR="$HOME/does-not-exist" DU_TRACE="$trace" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
printf "[%s]\n" "$(distro_pkg_cache_summary)"
'
    rm -rf "$stub_dir" "$fake_cache"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[]" ]] || { echo "$output"; return 1; }
    [ ! -s "$trace" ] || { echo "unexpected du call: $(cat "$trace")"; return 1; }
}

@test "debian orphans list parses Remv lines from the autoremove simulation" {
    stub_dir="$(mktemp -d)"
    transcript="$HOME/apt-simulate.txt"
    cat > "$transcript" <<'SIM'
Reading package lists...
Building dependency tree...
Reading state information...
The following packages will be REMOVED:
  libfake1 libfake2 fake-cli
Remv libfake1 [1.0-1]
Remv libfake2 [2.3-4]
Remv fake-cli [0.9]
0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded.
SIM
    install_apt_stub "$stub_dir" "$transcript"
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_FAKE_APT_SIMULATE="$transcript" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_orphans_list
'
    rm -rf "$stub_dir" "$transcript"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "libfake1"$'\n'"libfake2"$'\n'"fake-cli" ]] || { echo "$output"; return 1; }
}

@test "debian orphans remove plan joins names into one remove line" {
    stub_dir="$(mktemp -d)"
    transcript="$HOME/apt-simulate.txt"
    cat > "$transcript" <<'SIM'
The following packages will be REMOVED:
  libfake1 libfake2
Remv libfake1 [1.0-1]
Remv libfake2 [2.3-4]
SIM
    install_apt_stub "$stub_dir" "$transcript"
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_FAKE_APT_SIMULATE="$transcript" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_orphans_remove_plan
'
    rm -rf "$stub_dir" "$transcript"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Single line, remove (not purge): dpkg conffiles survive, matching Mole's
    # conservatism elsewhere.
    [[ "$output" == "sudo apt-get -y remove libfake1 libfake2" ]] || { echo "$output"; return 1; }
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" != *purge* ]] || { echo "$output"; return 1; }
}

@test "debian orphans plans stay empty when apt reports none" {
    stub_dir="$(mktemp -d)"
    transcript="$HOME/apt-simulate.txt"
    printf 'Reading package lists...\n0 upgraded, 0 newly installed, 0 to remove.\n' > "$transcript"
    install_apt_stub "$stub_dir" "$transcript"
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_FAKE_APT_SIMULATE="$transcript" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s]\n" "$(distro_orphans_list)" "$(distro_orphans_remove_plan)"
'
    rm -rf "$stub_dir" "$transcript"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[][]" ]] || { echo "$output"; return 1; }
}

@test "debian orphans queries yield empty output without apt-get" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" flatpak "/usr/bin/tr" "/usr/bin/sed" "/usr/bin/cut" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s]\n" "$(distro_orphans_list)" "$(distro_orphans_remove_plan)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[][]" ]] || { echo "$output"; return 1; }
}

@test "debian journal vacuum and flatpak plans follow detected tools" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
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

@test "debian journal and flatpak plans are empty when the tools are missing" {
    stub_dir="$(mktemp -d)"
    install_apt_stub "$stub_dir" /dev/null
    make_stub_path "$stub_dir" "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/debian"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s][%s]\n" "$(distro_journal_vacuum_plan)" "$(distro_flatpak_unused_plan)" "$(distro_aur_cache_dirs)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[][][]" ]] || { echo "$output"; return 1; }
}
