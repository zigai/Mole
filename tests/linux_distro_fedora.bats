#!/usr/bin/env bats
# shellcheck disable=SC2016  # payloads intentionally evaluate vars in the inner bash

# Fedora/RHEL-family distro capability module: fedora.sh plans against
# stubbed dnf/journalctl/systemctl/flatpak tools. Fixtures:
# tests/fixtures/linux/platform/os-release/{fedora,rhel-idlike}
# The dnf and du stubs are generated per-run under $HOME/stub-src because
# they are fedora-specific and parameterized by environment.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    FIXTURE_ROOT="$PROJECT_ROOT/tests/fixtures/linux/platform"
    export FIXTURE_ROOT
}

setup() {
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-platform-fedora-home.XXXXXX")"
    export HOME
    # Immunity against cross-suite leakage: see linux_platform_distro.bats.
    unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
        MOLE_PLATFORM MOLE_DISTRO_ID MOLE_OS_RELEASE_FILE MOLE_LOG_ROTATED \
        MOLE_PKG_CACHE_DIR MOLE_LIBDNF5_CACHE_DIR MOLE_TIMEOUT_DISK_VERIFY_SEC || true

    STUB_SRC_DIR="$HOME/stub-src"
    mkdir -p "$STUB_SRC_DIR"
    cat > "$STUB_SRC_DIR/dnf" <<'EOF'
#!/bin/bash
# Stub dnf: emits the space-separated $MOLE_FAKE_DNF_ORPHANS list for
# repoquery --unneeded (default: two orphans; explicitly empty -> none).
if [[ "${1:-}" == "-q" && "${2:-}" == "repoquery" ]]; then
    # shellcheck disable=SC2086  # intentional word split of the fixture list
    printf '%s\n' ${MOLE_FAKE_DNF_ORPHANS-orphan-a orphan-b}
fi
exit 0
EOF
    cat > "$STUB_SRC_DIR/du" <<'EOF'
#!/bin/bash
# Stub du -sch: traces every invocation to $MOLE_DU_TRACE, reports 10M per
# operand and their sum as the grand total line.
printf 'DU:%s\n' "$*" >> "${MOLE_DU_TRACE:?MOLE_DU_TRACE must be set}"
total=0
for dir in "$@"; do
    [[ "$dir" == -* ]] && continue
    total=$((total + 10))
    printf '10M %s\n' "$dir"
done
printf '%sM total\n' "$total"
EOF
    chmod +x "$STUB_SRC_DIR/dnf" "$STUB_SRC_DIR/du"
}

teardown() {
    rm -rf "$HOME"
}

# Build a PATH dir holding exactly the given tools: absolute paths symlink
# through, bare names prefer the shared fixture bin dir and fall back to the
# generated stubs above. Keeps system tools like journalctl from leaking into
# have_cmd() probes.
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
        elif [[ -f "$FIXTURE_ROOT/bin/$tool" ]]; then
            ln -s "$FIXTURE_ROOT/bin/$tool" "$dest/$tool"
        else
            ln -s "$STUB_SRC_DIR/$tool" "$dest/$tool"
        fi
    done
    printf '%s\n' "$dest"
}

@test "ID=fedora selects the fedora module" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s\n" "$(distro_id)" "$(distro_pkg_manager)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "fedora|dnf" ]] || { echo "$output"; return 1; }
}

@test "ID=centos with ID_LIKE='rhel fedora' selects the fedora module" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/rhel-idlike"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s\n" "$(distro_id)" "$(distro_pkg_manager)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "fedora|dnf" ]] || { echo "$output"; return 1; }
}

@test "fedora distro_init caches optional tool detection once" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s|%s|%s\n" "$DISTRO_PKG_CACHE_TOOL" "$DISTRO_JOURNALCTL" "$DISTRO_SYSTEMCTL" "$DISTRO_FLATPAK"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "dnf|journalctl|systemctl|flatpak" ]] || { echo "$output"; return 1; }

    # Without any of the optional tools every probe stays empty.
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s|%s|%s\n" "$DISTRO_PKG_CACHE_TOOL" "$DISTRO_JOURNALCTL" "$DISTRO_SYSTEMCTL" "$DISTRO_FLATPAK"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "|||" ]] || { echo "$output"; return 1; }
}

@test "fedora package cache plan is a single dnf clean line" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
distro_pkg_cache_plan 3
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "sudo dnf clean packages" ]] || { echo "$output"; return 1; }
}

@test "fedora pkg cache summary bounds du via run_with_timeout and totals both caches" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/awk" du > /dev/null

    primary="$(mktemp -d)"
    extra="$(mktemp -d)"
    trace="$HOME/du.trace"
    : > "$trace"
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_PKG_CACHE_DIR="$primary" MOLE_LIBDNF5_CACHE_DIR="$extra" \
        MOLE_DU_TRACE="$trace" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
# distro_pkg_cache_summary bounds du through run_with_timeout, which
# production loads via lib/core/common.sh; platform.sh standalone does not
# provide it, so pull in the same helper the production loader uses, then
# wrap it to prove the bounded-call contract was honored.
source "$PROJECT_ROOT/lib/core/timeout.sh"
run_with_timeout() {
    local duration="$1"
    shift
    printf "RWT:%s:%s\n" "$duration" "$*" >> "$MOLE_DU_TRACE"
    "$@"
}
distro_pkg_cache_summary
'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "DNF package cache: 20M" ]] || { echo "$output"; return 1; }
    grep -Fqx "RWT:15:du -sch $primary $extra" "$trace" || { echo "$(<"$trace")"; return 1; }

    # Only the primary cache exists: single-du path still totals cleanly.
    : > "$trace"
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_PKG_CACHE_DIR="$primary" MOLE_LIBDNF5_CACHE_DIR="$HOME/no-such-libdnf5" \
        MOLE_DU_TRACE="$trace" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
run_with_timeout() { shift; "$@"; }
distro_pkg_cache_summary
'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "DNF package cache: 10M" ]] || { echo "$output"; return 1; }

    # Neither cache exists: silent success, du never invoked.
    : > "$trace"
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_PKG_CACHE_DIR="$HOME/no-such-dnf" MOLE_LIBDNF5_CACHE_DIR="$HOME/no-such-libdnf5" \
        MOLE_DU_TRACE="$trace" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
source "$PROJECT_ROOT/lib/core/timeout.sh"
run_with_timeout() { shift; "$@"; }
printf "[%s]\n" "$(distro_pkg_cache_summary)"
'
    rc=$?
    rm -rf "$stub_dir" "$primary" "$extra"

    [ "$rc" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[]" ]] || { echo "$output"; return 1; }
    [ ! -s "$trace" ] || { echo "$(<"$trace")"; return 1; }
}

@test "fedora orphans list passes repoquery through and joins the remove plan onto one line" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
echo "--list--"
distro_orphans_list
echo "--plan--"
distro_orphans_remove_plan
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"--list--"$'\n'"orphan-a"$'\n'"orphan-b"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"--plan--"$'\n'"sudo dnf -y remove orphan-a orphan-b"* ]] || { echo "$output"; return 1; }
    # The remove plan must be a single line.
    [[ "$output" != *"-y remove orphan-a"$'\n'"orphan-b"* ]] || { echo "$output"; return 1; }
}

@test "fedora orphan queries stay empty when dnf reports none" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" \
        MOLE_FAKE_DNF_ORPHANS="" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s][%s]\n" "$(distro_orphans_list)" "$(distro_orphans_remove_plan)" "$(distro_aur_cache_dirs)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[][][]" ]] || { echo "$output"; return 1; }
}

@test "fedora journal vacuum and flatpak plans follow detected tools" {
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf journalctl systemctl flatpak "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
echo "--journal--"
distro_journal_vacuum_plan
echo "--flatpak--"
distro_flatpak_unused_plan
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"--journal--"$'\n'"sudo journalctl --vacuum-size=100M --vacuum-time=2weeks"$'\n'"--flatpak--"$'\n'"flatpak uninstall --unused --noninteractive"* ]] || { echo "$output"; return 1; }

    # Without the tools both plans stay empty.
    stub_dir="$(mktemp -d)"
    make_stub_path "$stub_dir" dnf "/usr/bin/tr" "/usr/bin/sed" > /dev/null
    run env PROJECT_ROOT="$PROJECT_ROOT" FIXTURE_ROOT="$FIXTURE_ROOT" PATH="$stub_dir" /bin/bash --noprofile --norc -c '
set -euo pipefail
export MOLE_OS_RELEASE_FILE="$FIXTURE_ROOT/os-release/fedora"
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "[%s][%s]\n" "$(distro_journal_vacuum_plan)" "$(distro_flatpak_unused_plan)"
'
    rm -rf "$stub_dir"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "[][]" ]] || { echo "$output"; return 1; }
}

@test "live Fedora host resolves the fedora module against the real os-release" {
    if [[ ! -f /etc/dnf/dnf.conf && ! -x /usr/bin/dnf ]]; then
        skip "host has no dnf"
    fi
    local host_id
    host_id="$(sed -n 's/^ID=//p' /etc/os-release 2> /dev/null || true)"
    [[ "$host_id" == fedora* ]] || skip "host is not Fedora: ${host_id:-unknown}"

    run env PROJECT_ROOT="$PROJECT_ROOT" HOME="$HOME" /bin/bash --noprofile --norc -c '
set -euo pipefail
unset MOLE_OS_RELEASE_FILE
source "$PROJECT_ROOT/lib/platform/platform.sh"
printf "%s|%s\n" "$(distro_id)" "$(distro_pkg_manager)"
'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "fedora|dnf" ]] || { echo "$output"; return 1; }
}
