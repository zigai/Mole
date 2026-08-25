#!/usr/bin/env bats
# update.sh fork endpoint assertions: no tw93 endpoint may be reachable from
# any linux (or darwin) code path, and channel logic stays script-only on linux.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-upd-linux.XXXXXX")"
    export HOME

    FIXTURES="${BATS_TEST_DIRNAME}/fixtures/linux/misc"
    export FIXTURES
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "update.sh contains no tw93 endpoint URLs" {
    run grep -E 'raw\.githubusercontent\.com/tw93|api\.github\.com/repos/tw93|github\.com/tw93/mole\.git' \
        "$PROJECT_ROOT/lib/manage/update.sh"

    [ "$status" -eq 1 ]
}

@test "version discovery queries only zigai/Mole" {
    local url_log="$HOME/curl.log"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux VERSION=1.0.0 \
        URL_LOG="$url_log" \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
record_url() { printf '%s\n' "$*" >> "$URL_LOG"; }
curl() { record_url "curl $*"; printf '{"tag_name": "V9.9.9"}\n'; return 0; }
wget() { record_url "wget $*"; return 0; }
git() { record_url "git $*"; return 1; }
source "$PROJECT_ROOT/lib/manage/update.sh"
get_latest_version > /dev/null
get_latest_version_from_github > /dev/null
get_latest_commit_from_github api-only > /dev/null
cat "$URL_LOG"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *zigai/Mole* ]]
    [[ "$output" != *tw93* ]]
    grep -q 'raw.githubusercontent.com/zigai/Mole/main/mole' <<< "$output"
    grep -q 'api.github.com/repos/zigai/Mole/releases/latest' <<< "$output"
    grep -q 'api.github.com/repos/zigai/Mole/commits/main' <<< "$output"
}

@test "installer URL helper targets the fork for tags and main" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux VERSION=1.0.0 \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
source "$PROJECT_ROOT/lib/manage/update.sh"
update_installer_url main
update_installer_url "V1.52.0"
EOF

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | while IFS= read -r line; do
        [[ "$line" == "https://raw.githubusercontent.com/zigai/Mole/"*"/install.sh" ]]
    done
    grep -qx 'https://raw.githubusercontent.com/zigai/Mole/main/install.sh' <<< "$output"
    grep -qx 'https://raw.githubusercontent.com/zigai/Mole/V1.52.0/install.sh' <<< "$output"
}

@test "nightly commit resolution uses the fork remote" {
    local git_log="$HOME/git.log"
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux VERSION=1.0.0 \
        GIT_LOG="$git_log" MOLE_TIMEOUT_MEDIUM_PROBE_SEC=5 \
        PATH="${BATS_TEST_DIRNAME}/fixtures/linux/misc/bin:$PATH" \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
curl() { return 1; }
export -f curl
run_with_timeout() { local t=$1; shift; "$@"; }
export -f run_with_timeout
source "$PROJECT_ROOT/lib/manage/update.sh"
get_latest_commit_from_github > /dev/null
cat "$GIT_LOG"
EOF

    [ "$status" -eq 0 ]
    grep -q 'credential.helper=' <<< "$output"
    grep -q 'https://github.com/zigai/Mole.git refs/heads/main' <<< "$output"
    [[ "$output" != *tw93* ]]
}

@test "AUR hint fires on arch-like hosts after update and stays silent elsewhere" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux VERSION=1.0.0 ICON_INFO='ℹ' \
        /bin/bash --noprofile --norc <<EOF
set -uo pipefail
source "\$PROJECT_ROOT/lib/manage/update.sh"
export MOLE_OS_RELEASE_FILE="\$FIXTURES/os-release-arch"
_update_print_linux_aur_hint
echo "---"
export MOLE_OS_RELEASE_FILE="\$FIXTURES/os-release-fedora"
_update_print_linux_aur_hint
echo "end"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"AUR package"* ]]
    [[ "$output" == *"end" ]]
    # Exactly one hint: fedora must not print one.
    [[ $(grep -c 'AUR package' <<< "$output") -eq 1 ]]
}

@test "linux skips the Homebrew update channel even when brew exists" {
    local fake_bin="$HOME/fakebin"
    mkdir -p "$fake_bin"
    printf '#!/bin/bash\nexit 0\n' > "$fake_bin/brew"
    chmod +x "$fake_bin/brew"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_PLATFORM=linux VERSION=1.0.0 \
        PATH="$fake_bin:$PATH" MOLE_TEST_NO_AUTH=1 CURL_LOG="$HOME/update.log" \
        /bin/bash --noprofile --norc <<'EOF'
set -uo pipefail
# Minimal core shims so update_mole can start without the full entrypoint.
log_error() { echo "ERR:$*"; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
resolve_mole_source_path() { printf '%s\n' "${HOME:-}/bin/mole"; }
mkdir -p "$HOME/bin" && printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/mole" && chmod +x "$HOME/bin/mole"
curl() { echo "CURL $*" >> "${CURL_LOG:?}"; return 28; }
source "$PROJECT_ROOT/lib/manage/update.sh"
update_mole false false || true
grep -q brew "$CURL_LOG" && echo "BREW_CHANNEL_USED"
exit 0
EOF

    [ "$status" -eq 0 ]
    [[ "$output" != *"BREW_CHANNEL_USED"* ]]
}
