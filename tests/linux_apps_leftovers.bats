#!/usr/bin/env bats
# Linux leftover discovery: XDG + dotfile forms, safe vs review tiering,
# pacman-ownership skips, and the running-app tri-state (contract §5).

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-linux-apps-leftovers-home.XXXXXX")"
    export HOME

    FIXTURE_BIN="${BATS_TEST_DIRNAME}/fixtures/linux/apps/bin"
    export FIXTURE_BIN

    MOLE_TEST_NO_AUTH=1
    export MOLE_TEST_NO_AUTH
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi

    FAKE_DB="$(mktemp -d "${HOME}/fake-pacman-db.XXXXXX")"
    export FAKE_DB
    : > "$FAKE_DB/packages.tsv"
    : > "$FAKE_DB/owned.txt"
    export MOLE_FAKE_PACMAN_DB="$FAKE_DB"

    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_STATE_HOME="$HOME/.local/state"

    # Fake pgrep driven by MOLE_FAKE_PGREP_RC for the running-state tri-state.
    mkdir -p "$HOME/fake-bin"
    cat > "$HOME/fake-bin/pgrep" <<PGREP
#!/usr/bin/env bash
exit "\${MOLE_FAKE_PGREP_RC:-1}"
PGREP
    chmod +x "$HOME/fake-bin/pgrep"
}

@test "safe tier finds exact-id dirs under every XDG root and home dotfiles" {
    mkdir -p "$XDG_CONFIG_HOME/myapp" "$XDG_DATA_HOME/myapp" \
        "$XDG_CACHE_HOME/myapp" "$XDG_STATE_HOME/myapp" \
        "$HOME/myapp" "$HOME/.myapp" "$HOME/.myapprc"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/leftovers.sh
leftovers_exact_paths myapp | LC_ALL=C sort
EOF

    [ "$status" -eq 0 ]
    local expected_file
    expected_file="$(mktemp)"
    {
        echo "$HOME/.myapp"
        echo "$HOME/.myapprc"
        echo "$HOME/myapp"
        echo "$XDG_CACHE_HOME/myapp"
        echo "$XDG_CONFIG_HOME/myapp"
        echo "$XDG_DATA_HOME/myapp"
        echo "$XDG_STATE_HOME/myapp"
    } | LC_ALL=C sort > "$expected_file"
    diff -u "$expected_file" <(printf '%s\n' "$output")
    rm -f "$expected_file"
}

@test "review tier matches display names exactly and rejects generic words" {
    mkdir -p "$XDG_CONFIG_HOME/Cool Tool" "$XDG_CONFIG_HOME/cooltool.cfg" \
        "$XDG_CONFIG_HOME/Terminal"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/leftovers.sh
echo "--- cool tool:"
leftovers_review_paths "Cool Tool"
echo "--- suffix:"
leftovers_review_paths "cooltool"
echo "--- generic:"
leftovers_review_paths "Terminal"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cool Tool"* ]]
    [[ "$output" == *"$XDG_CONFIG_HOME/cooltool.cfg"* ]]
    local generic_section
    generic_section="${output##*--- generic:}"
    [[ -z "${generic_section//[[:space:]]/}" ]]
}

@test "classification: exact-id is safe, data-protected id is review-only" {
    mkdir -p "$XDG_CONFIG_HOME/firefox" "$XDG_CONFIG_HOME/plainapp"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/leftovers.sh
printf '%s\n' "\$(leftovers_classify_path "$XDG_CONFIG_HOME/plainapp" id)"
printf '%s\n' "\$(leftovers_classify_path "$XDG_CONFIG_HOME/firefox" id)"
EOF

    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | sed -n 1p)" == "safe" ]]
    [[ "$(printf '%s\n' "$output" | sed -n 2p)" == "review" ]]
}

@test "classification: pacman-owned paths are always skipped" {
    printf '%s\n' "$XDG_DATA_HOME/ownedapp" > "$FAKE_DB/owned.txt"
    mkdir -p "$XDG_DATA_HOME/ownedapp"

    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$FIXTURE_BIN:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
export MOLE_PLATFORM=linux
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/leftovers.sh
leftovers_classify_path "$XDG_DATA_HOME/ownedapp" id
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == "skip" ]]
}

@test "running state reports the fake pgrep tri-state" {
    run /bin/bash <<EOF
set -uo pipefail
export HOME="$HOME"
export PATH="$HOME/fake-bin:\$PATH"
export MOLE_FAKE_PACMAN_DB="$FAKE_DB"
cd "$PROJECT_ROOT"
source lib/core/common.sh
source lib/uninstall/leftovers.sh

MOLE_FAKE_PGREP_RC=0 leftovers_running_state myapp My App || rc=\$?
echo "rc-running=\${rc:-0}"

rc=0
MOLE_FAKE_PGREP_RC=1 leftovers_running_state myapp My App || rc=\$?
echo "rc-clear=\$rc"

rc=0
MOLE_FAKE_PGREP_RC=2 leftovers_running_state myapp My App || rc=\$?
echo "rc-unknown=\$rc"
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"rc-running=0"* ]]
    [[ "$output" == *"rc-clear=1"* ]]
    [[ "$output" == *"rc-unknown=2"* ]]
}
