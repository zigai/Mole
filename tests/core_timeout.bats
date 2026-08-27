#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    export MO_DEBUG=0
}

@test "run_with_timeout: command completes before timeout" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'success'
    ")
    [[ "$result" == "success" ]]
}

@test "run_with_timeout: zero timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 0 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: invalid timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout invalid echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: negative timeout runs command normally" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout -5 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: preserves command exit code on success" {
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true
    "
    exit_code=$?
    [[ $exit_code -eq 0 ]]
}

@test "run_with_timeout: preserves command exit code on failure" {
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 false
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 1 ]]
}

@test "run_with_timeout: returns 124 on timeout (if using gtimeout)" {
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 1 sleep 3
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 124 ]]
}

@test "run_with_timeout: kills long-running command" {
    start_time=$(date +%s)
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 2 sleep 5
    " >/dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 10 ]]
}

@test "run_with_timeout: handles fast-completing commands" {
    start_time=$(date +%s)
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 10 echo 'fast'
    " >/dev/null 2>&1
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    [[ $duration -lt 3 ]]
}

@test "run_with_timeout: works in pipefail mode" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'pipefail_test'
    ")
    [[ "$result" == "pipefail_test" ]]
}

@test "run_with_timeout: doesn't cause unintended exits" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true || true
        echo 'survived'
    ")
    [[ "$result" == "survived" ]]
}

@test "run_with_timeout: handles commands with arguments" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'arg1' 'arg2' 'arg3'
    ")
    [[ "$result" == "arg1 arg2 arg3" ]]
}

@test "run_with_timeout: handles commands with spaces in arguments" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'hello world'
    ")
    [[ "$result" == "hello world" ]]
}

@test "run_with_timeout: debug logging when MO_DEBUG=1" {
    output=$(/bin/bash -c "
        set -euo pipefail
        export MO_DEBUG=1
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test' 2>&1
    ")
    [[ "$output" =~ TIMEOUT ]]
}

@test "run_with_timeout: no debug logging when MO_DEBUG=0" {
    output=$(/bin/bash -c "
        set -euo pipefail
        export MO_DEBUG=0
        unset MO_TIMEOUT_INITIALIZED
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test'
    " 2>/dev/null)
    [[ "$output" == "test" ]]
}

@test "timeout.sh: prevents multiple sourcing" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo 'loaded'
    ")
    [[ "$result" == "loaded" ]]
}

@test "timeout.sh: sets MOLE_TIMEOUT_LOADED flag" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo \"\$MOLE_TIMEOUT_LOADED\"
    ")
    [[ "$result" == "1" ]]
}


@test "run_with_timeout: shell fallback preserves command exit code" {
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        run_with_timeout 5 sh -c 'exit 7'
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 7 ]]
}

@test "run_with_timeout: shell fallback kills long-running command" {
    start_time=$(date +%s)
    set +e
    /bin/bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        run_with_timeout 2 sleep 8
    " > /dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    [[ $duration -lt 7 ]]
}

@test "run_with_timeout: shell fallback preserves caller INT trap" {
    result=$(/bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=''
        trap 'echo caller-trap' INT
        run_with_timeout 2 true
        trap -p INT
    ")
    [[ "$result" == *"caller-trap"* ]]
}

@test "run_with_timeout: shell fallback cleans up watchdog sleep" {
    /bin/bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        MO_TIMEOUT_BIN=''
        MO_TIMEOUT_PERL_BIN=''
        run_with_timeout 287 true
        sleep 0.1
        leaked=''
        for pid in \$(pgrep -x sleep 2>/dev/null || true); do
            command_line=\$(ps -p \"\$pid\" -o command= 2>/dev/null || true)
            if [[ \"\$command_line\" == 'sleep 287' ]]; then
                leaked=\"\$pid\"
                kill \"\$pid\" 2>/dev/null || true
            fi
        done
        [[ -z \"\$leaked\" ]] || return 1
    "
}

# A directory-sizing `du` on a stalled network mount or a huge tree wedges the
# whole scan: it has no internal bound and the caller usually pipes it into a
# command substitution that just waits. Every `du -s*` in lib/ and bin/ must
# therefore run under run_with_timeout or the shared bounded sudo helper. This
# test pins that so a new sizing site cannot be added unbounded.
@test "every du sizing call in lib/ and bin/ runs under run_with_timeout" {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    unbounded=""
    while IFS=: read -r file line text; do
        [[ "$text" =~ ^[[:space:]]*# ]] && continue
        local first_line=$((line > 2 ? line - 2 : 1))
        local context=""
        context=$(sed -n "${first_line},${line}p" "$file")
        if ! grep -Eq 'run_with_timeout|_mole_bounded_sudo' <<< "$context"; then
            unbounded+="${file}:${line}:${text}"$'\n'
        fi
    done < <(grep -rn -- 'du -s' "$PROJECT_ROOT/lib" "$PROJECT_ROOT/bin" || true)
    if [[ -n "$unbounded" ]]; then
        echo "Unbounded du call sites:" >&2
        echo "$unbounded" >&2
        return 1
    fi
}
