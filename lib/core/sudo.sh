#!/bin/bash
# Sudo Session Manager
# Unified sudo authentication and keepalive management

set -euo pipefail

# ============================================================================
# Password Prompt
# ============================================================================
# Prompt for the sudo password on the controlling TTY.
_request_password() {
    local tty_path="$1"

    sudo -k 2> /dev/null

    local stty_orig
    stty_orig=$(stty -g < "$tty_path" 2> /dev/null || echo "")
    trap '[[ -n "${stty_orig:-}" ]] && stty "${stty_orig:-}" < "$tty_path" 2> /dev/null || true' RETURN

    echo -e "${PURPLE}${ICON_ARROW}${NC} Enter your credentials:" > "$tty_path"
    # shellcheck disable=SC2024,SC2094
    # Intentionally route sudo's native prompt to the same TTY device it reads from.
    if sudo -v < "$tty_path" > /dev/null 2> "$tty_path"; then
        return 0
    fi

    return 1
}

request_sudo_access() {
    local prompt_msg="${1:-Admin access required}"

    # Tests must never trigger real password prompts.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Check if already have sudo access
    if sudo -n true 2> /dev/null; then
        return 0
    fi

    # Detect if running in a TTY environment; without one there is no way to
    # prompt for credentials.
    local tty_path="/dev/tty"
    if [[ ! -r "$tty_path" || ! -w "$tty_path" ]]; then
        tty_path=$(tty 2> /dev/null || echo "")
        if [[ -z "$tty_path" || ! -r "$tty_path" || ! -w "$tty_path" ]]; then
            return 1
        fi
    fi

    echo -e "${PURPLE}${ICON_ARROW}${NC} ${prompt_msg}"
    if _request_password "$tty_path"; then
        # Clear all prompt lines (use safe clearing method)
        safe_clear_lines 3 "$tty_path"
        return 0
    fi
    return 1
}


request_sudo_access_with_password() {
    local password="$1"
    local prompt_msg="${2:-Admin access required}"

    # Tests must never trigger real password prompts.
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    if [[ -z "$password" ]]; then
        request_sudo_access "$prompt_msg"
        return $?
    fi

    sudo -k 2> /dev/null

    if printf '%s\n' "$password" | sudo -S -p "" -v > /dev/null 2>&1; then
        unset password
        return 0
    fi

    unset password
    return 1
}

# ============================================================================
# Sudo Session Management
# ============================================================================

# Global state
MOLE_SUDO_KEEPALIVE_PID=""
MOLE_SUDO_ESTABLISHED="false"

# Start sudo keepalive
_start_sudo_keepalive() {
    # Start background keepalive process with all outputs redirected
    # This is critical: command substitution waits for all file descriptors to close
    (
        # Initial delay to let sudo cache stabilize after password entry
        # This prevents immediately triggering Touch ID again
        sleep 2

        while true; do
            if ! sudo -n -v 2> /dev/null; then
                # A failed refresh is harmless and often transient (authd
                # busy, machine waking). Giving up after a few misses is what
                # let the timestamp lapse minutes into a long install and
                # forced a second authentication prompt; `-n` never prompts,
                # so retrying costs nothing. Exit only with the parent.
                kill -0 "$$" 2> /dev/null || exit
                sleep 5
                continue
            fi
            sleep 30
            kill -0 "$$" 2> /dev/null || exit
        done
    ) > /dev/null 2>&1 &

    local pid=$!
    echo $pid
}

# Stop sudo keepalive
_stop_sudo_keepalive() {
    local pid="${1:-}"
    if [[ -n "$pid" ]]; then
        kill "$pid" 2> /dev/null || true
        wait "$pid" 2> /dev/null || true
    fi
}

# Check if sudo session is active
has_sudo_session() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    sudo -n true 2> /dev/null
}

adopt_sudo_session() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    if [[ "$MOLE_SUDO_ESTABLISHED" == "true" && -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        if has_sudo_session; then
            return 0
        fi
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
        MOLE_SUDO_ESTABLISHED="false"
    fi

    if ! sudo -n -v 2> /dev/null; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)
    MOLE_SUDO_ESTABLISHED="true"
    return 0
}

# Request administrative access
request_sudo() {
    local prompt_msg="${1:-Admin access required}"

    if has_sudo_session; then
        return 0
    fi

    # Use the robust implementation from common.sh
    if request_sudo_access "$prompt_msg"; then
        return 0
    else
        return 1
    fi
}

# Maintain active sudo session with keepalive
ensure_sudo_session() {
    local prompt="${1:-Admin access required}"

    # Check if already established
    if has_sudo_session && [[ "$MOLE_SUDO_ESTABLISHED" == "true" ]]; then
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    # Stop old keepalive if exists
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    # Request sudo access
    if ! request_sudo "$prompt"; then
        MOLE_SUDO_ESTABLISHED="false"
        return 1
    fi

    # Start keepalive
    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)

    MOLE_SUDO_ESTABLISHED="true"
    return 0
}

ensure_sudo_session_with_password() {
    local password="$1"
    local prompt="${2:-Admin access required}"

    # Check if already established
    if has_sudo_session && [[ "$MOLE_SUDO_ESTABLISHED" == "true" ]]; then
        unset password
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        MOLE_SUDO_ESTABLISHED="false"
        unset password
        return 1
    fi

    # Stop old keepalive if exists
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi

    # Request sudo access
    if ! request_sudo_access_with_password "$password" "$prompt"; then
        MOLE_SUDO_ESTABLISHED="false"
        unset password
        return 1
    fi

    unset password

    # Start keepalive
    MOLE_SUDO_KEEPALIVE_PID=$(_start_sudo_keepalive)

    MOLE_SUDO_ESTABLISHED="true"
    return 0
}

# Stop sudo session and cleanup
stop_sudo_session() {
    if [[ -n "$MOLE_SUDO_KEEPALIVE_PID" ]]; then
        _stop_sudo_keepalive "$MOLE_SUDO_KEEPALIVE_PID"
        MOLE_SUDO_KEEPALIVE_PID=""
    fi
    MOLE_SUDO_ESTABLISHED="false"
}
