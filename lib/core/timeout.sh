#!/bin/bash
# Mole - Timeout Control
# Command execution with timeout support

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_TIMEOUT_LOADED=1

# ============================================================================
# Timeout Command Initialization
# ============================================================================

# Initialize the timeout command (GNU coreutils).
# Sets MO_TIMEOUT_BIN to the resolved timeout binary.
if [[ -z "${MO_TIMEOUT_INITIALIZED:-}" ]]; then
    MO_TIMEOUT_BIN=""
    if command -v timeout > /dev/null 2>&1; then
        MO_TIMEOUT_BIN="$(command -v timeout)"
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Using command: $MO_TIMEOUT_BIN" >&2
        fi
    fi

    # Log warning if no timeout command available
    if [[ -z "$MO_TIMEOUT_BIN" ]] && [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] No timeout command found, using shell fallback" >&2
    fi

    # Export so child processes inherit detected values and skip re-detection.
    # Without this, children that inherit MO_TIMEOUT_INITIALIZED=1 skip the init
    # block but have empty bin vars, forcing the slow shell fallback.
    export MO_TIMEOUT_BIN
    export MO_TIMEOUT_INITIALIZED=1
fi

# ============================================================================
# Timeout Execution
# ============================================================================

_mole_cleanup_timeout_killer() {
    local killer_pid="${1:-}"
    [[ "$killer_pid" =~ ^[0-9]+$ ]] || return 0

    local child_pids=""
    if command -v pgrep > /dev/null 2>&1; then
        child_pids=$(pgrep -P "$killer_pid" 2> /dev/null || true)
    fi

    kill "$killer_pid" 2> /dev/null || true

    if [[ -n "$child_pids" ]]; then
        local child_pid
        while IFS= read -r child_pid; do
            [[ "$child_pid" =~ ^[0-9]+$ ]] || continue
            kill "$child_pid" 2> /dev/null || true
        done <<< "$child_pids"
    fi

    wait "$killer_pid" 2> /dev/null || true
}

mole_tty_is_foreground() {
    # Non-terminal input cannot trigger SIGTTIN; preserve scripted/test flows.
    [[ -t 0 ]] || return 0

    # Compare the terminal's foreground process group (tpgid) with our own.
    # If ps cannot answer, assume foreground: a wrong "yes" only risks SIGTTIN,
    # while a wrong "no" would suppress an interactive prompt.
    local tty_pgrp="" my_pgrp=""
    tty_pgrp=$(ps -o tpgid= -p "$$" 2> /dev/null | tr -d '[:space:]') || return 0
    my_pgrp=$(ps -o pgrp= -p "$$" 2> /dev/null | tr -d '[:space:]') || return 0
    [[ -n "$tty_pgrp" && "$tty_pgrp" =~ ^[0-9]+$ && "$tty_pgrp" == "$my_pgrp" ]]
}

# Run command with timeout
# Uses GNU timeout if available, falls back to shell-based implementation
#
# Args:
#   $1 - duration in seconds (0 or invalid = no timeout)
#   $@ - command and arguments to execute
#
# Returns:
#   Command exit code, or 124 if timed out (matches timeout behavior)
#
# Environment:
#   MO_DEBUG - Set to 1 to enable debug logging to stderr
#
# Implementation notes:
#   - Prefers GNU timeout for reliability
#   - Shell fallback uses SIGTERM → SIGKILL escalation
#   - Attempts process group cleanup to handle child processes
#   - Returns exit code 124 on timeout (standard timeout exit code)
#
# Known limitations of shell-based fallback:
#   - Race condition: If command exits during signal delivery, the signal
#     may target a reused PID (very rare, requires quick PID reuse)
#   - Zombie processes: Brief zombies until wait completes
#   - Nested children: SIGKILL may not reach all descendants
#   - No process group: Cannot guarantee cleanup of detached children
#
# For mission-critical timeouts, install coreutils.
run_with_timeout() {
    local duration="${1:-0}"
    shift || true

    # No timeout if duration is invalid or zero. The regex already forbids a
    # leading sign, so "<= 0" reduces to "is zero"; match that in pure bash
    # rather than shelling out to an arithmetic helper.
    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$duration" =~ ^0+(\.0+)?$ ]]; then
        "$@"
        return $?
    fi

    # Use GNU timeout when available (preferred path).
    #
    # This backend has no owner-death detection, and that asymmetry is
    # deliberate. SIGKILLing the calling worker leaves timeout and its child
    # alive, but both still die when timeout's own deadline fires, so the
    # orphan window is capped by the caller's timeout budget (2-30s here)
    # rather than unbounded. Ctrl-C already reaches them, since the signal
    # goes to the whole foreground process group. Backgrounding the backend
    # and polling it would reopen the terminal-handoff class behind
    # #1222/#1218; not worth a window the deadline already bounds.
    if [[ -n "${MO_TIMEOUT_BIN:-}" ]]; then
        local timeout_bin="$MO_TIMEOUT_BIN"
        if [[ "$timeout_bin" != */* ]]; then
            timeout_bin=$(command -v "$timeout_bin" 2> /dev/null || true)
        fi
        if [[ -z "$timeout_bin" || ! -x "$timeout_bin" ]]; then
            timeout_bin=""
        fi
    fi
    if [[ -n "${timeout_bin:-}" ]]; then
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Running with ${duration}s timeout: $*" >&2
        fi
        "$timeout_bin" "$duration" "$@"
        return $?
    fi


    # ========================================================================
    # Shell-based fallback implementation
    # ========================================================================

    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo "[TIMEOUT] Shell fallback, ${duration}s: $*" >&2
    fi

    # Start command in background
    "$@" &
    local cmd_pid=$!

    # Start timeout killer in background.
    # Redirect all FDs to /dev/null so orphaned child processes (e.g. sleep $duration)
    # do not inherit open file descriptors from the caller and block output pipes
    # (notably bats output capture pipes that wait for all writers to close).
    (
        # Wait for timeout duration
        sleep "$duration"

        # Check if process still exists
        if kill -0 "$cmd_pid" 2> /dev/null; then
            # Try to kill process group first (negative PID), fallback to single process
            # Process group kill is best effort - may not work if setsid was used
            kill -TERM -"$cmd_pid" 2> /dev/null || kill -TERM "$cmd_pid" 2> /dev/null || true

            # Grace period for clean shutdown
            sleep 2

            # Escalate to SIGKILL if still alive
            if kill -0 "$cmd_pid" 2> /dev/null; then
                kill -KILL -"$cmd_pid" 2> /dev/null || kill -KILL "$cmd_pid" 2> /dev/null || true
            fi
        fi
    ) < /dev/null > /dev/null 2>&1 &
    local killer_pid=$!

    local interrupted=0
    local previous_int_trap
    previous_int_trap=$(trap -p INT || true)

    # Forward SIGINT to the command while preserving the caller's trap.
    trap 'interrupted=1; kill -INT "$cmd_pid" 2>/dev/null || true; _mole_cleanup_timeout_killer "$killer_pid"' INT

    # Wait for command to complete
    local exit_code=0
    set +e
    wait "$cmd_pid" 2> /dev/null
    exit_code=$?
    set -e

    if [[ -n "$previous_int_trap" ]]; then
        # eval: restore previous trap captured by $(trap -p INT)
        eval "$previous_int_trap"
    else
        trap - INT
    fi

    _mole_cleanup_timeout_killer "$killer_pid"

    if [[ $interrupted -eq 1 ]]; then
        return 130
    fi

    # Check if command was killed by timeout (exit codes 143=SIGTERM, 137=SIGKILL)
    if [[ $exit_code -eq 143 || $exit_code -eq 137 ]]; then
        # Command was killed by timeout
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            echo "[TIMEOUT] Command timed out after ${duration}s" >&2
        fi
        return 124
    fi

    # Command completed normally (or with its own error)
    return "$exit_code"
}
