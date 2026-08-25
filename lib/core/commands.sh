#!/bin/bash

# Shared command list for help text and completions.
MOLE_COMMANDS=(
    "clean:Free up disk space"
    "uninstall:Remove apps completely"
    "optimize:Refresh caches and services"
    "analyze:Explore disk usage"
    "status:Monitor system health"
    "history:Review cleanup activity"
    "purge:Remove old project artifacts"
    "installer:Find and remove installer files"
)

# Touch ID is a macOS PAM feature; keep it out of the linux help surface.
if [[ "${MOLE_PLATFORM:-darwin}" == "darwin" ]]; then
    MOLE_COMMANDS+=("touchid:Configure Touch ID for sudo")
fi

MOLE_COMMANDS+=(
    "completion:Setup shell tab completion"
    "update:Update to latest version"
    "remove:Remove Mole from system"
    "help:Show help"
    "version:Show version"
)
