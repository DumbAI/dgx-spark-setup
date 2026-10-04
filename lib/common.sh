#!/usr/bin/env bash
# Shared helpers sourced by setup-dev.sh and available to every module.

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || die "Required command not found: $cmd"
    done
}

require_systemd() {
    [[ -d /run/systemd/system ]] || die 'This module requires a host running systemd.'
}

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if ! "$SETUP_DRY_RUN"; then
        "$@"
    fi
}

install_config() {
    if "$SETUP_DRY_RUN"; then
        printf '\nConfiguration for %s:\n' "$2"
        cat "$1"
    fi
    run install -D -o root -g root -m 0644 "$1" "$2"
}
