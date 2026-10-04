#!/usr/bin/env bash
# Run the selected DGX Spark development setup modules.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: sudo ./setup-dev.sh [MODULE ...]
       ./setup-dev.sh --dry-run [MODULE ...]
       ./setup-dev.sh --list

Run all modules by default, or only the named modules, in filename order.
All selected preflight checks run before any system settings change.

Options:
  --dry-run  Show configuration and commands without changing system settings.
  --list     List available modules (or only the named modules).
  -h, --help Show this help.
EOF
}

SETUP_DRY_RUN=false
list_modules=false
requested_modules=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) SETUP_DRY_RUN=true ;;
        --list) list_modules=true ;;
        -h|--help) usage; exit 0 ;;
        -*) die "Unknown option: $arg" ;;
        *) requested_modules+=("$arg") ;;
    esac
done
readonly SETUP_DRY_RUN

declare -A module_paths=()
module_names=()
shopt -s nullglob
for module_path in "$script_dir"/modules/[0-9][0-9]-*.sh; do
    module_name=${module_path##*/}
    module_name=${module_name#*-}
    module_name=${module_name%.sh}
    [[ -n "$module_name" ]] || die "Empty module name: $module_path"
    [[ ! -v module_paths[$module_name] ]] || die "Duplicate module name: $module_name"
    module_paths["$module_name"]=$module_path
    module_names+=("$module_name")
done
(( ${#module_names[@]} > 0 )) || die 'No modules found in modules/NN-name.sh.'

declare -A selected=()
for module_name in "${requested_modules[@]}"; do
    [[ -v module_paths[$module_name] ]] || die "Unknown module: $module_name (see --list)."
    selected["$module_name"]=true
done

# Retain discovery order and run repeated module arguments only once.
selected_modules=()
for module_name in "${module_names[@]}"; do
    if (( ${#requested_modules[@]} == 0 )) || [[ -v selected[$module_name] ]]; then
        selected_modules+=("$module_name")
    fi
done

# Each invocation gets an isolated shell: module functions and variables cannot
# leak into another module. Checks and application also run in separate shells.
run_module() (
    local module_name=$1 action=$2 hook
    # shellcheck source=/dev/null
    source "${module_paths[$module_name]}"
    for hook in module_description module_check module_apply; do
        declare -F "$hook" >/dev/null || die "$module_name is missing $hook()."
    done

    case "$action" in
        describe) module_description ;;
        check) module_check ;;
        apply)
            SETUP_WORK_DIR=$(mktemp -d)
            readonly SETUP_WORK_DIR
            trap 'rm -rf -- "$SETUP_WORK_DIR"' EXIT
            module_apply
            ;;
    esac
)

if "$list_modules"; then
    for module_name in "${selected_modules[@]}"; do
        printf '%-20s ' "$module_name"
        run_module "$module_name" describe
    done
    exit 0
fi

if ! "$SETUP_DRY_RUN" && (( EUID != 0 )); then
    die 'Run with sudo: sudo ./setup-dev.sh (or preview with --dry-run).'
fi
require_commands mktemp

for module_name in "${selected_modules[@]}"; do
    printf '\nChecking %s...\n' "$module_name"
    run_module "$module_name" check
done
for module_name in "${selected_modules[@]}"; do
    printf '\nApplying %s...\n' "$module_name"
    run_module "$module_name" apply
done

if "$SETUP_DRY_RUN"; then
    printf '\nDry run complete. No system settings changed.\n'
else
    printf '\nSelected setup modules completed.\n'
fi
