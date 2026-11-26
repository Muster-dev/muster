#!/usr/bin/env bash
# tests/test_group_picker.sh — Group deploy service picker → per-project filter
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test_helpers.sh"

GREEN="" YELLOW="" RED="" RESET="" BOLD="" DIM="" ACCENT="" ACCENT_BRIGHT="" WHITE="" GRAY=""
MUSTER_QUIET="true"
MUSTER_VERBOSE="false"

source "$MUSTER_ROOT/lib/core/colors.sh"
source "$MUSTER_ROOT/lib/core/logger.sh"
source "$MUSTER_ROOT/lib/core/utils.sh"
source "$MUSTER_ROOT/lib/commands/group.sh"

# Two projects that both have an "api" service, plus a remote project
# whose service list couldn't be fetched (placeholder item).
#   idx 0  ---:alpha
#   idx 1  api      (project 0)
#   idx 2  worker   (project 0)
#   idx 3  ---:beta
#   idx 4  api      (project 1)
#   idx 5  ---:gamma
#   idx 6  (all services) (project 2)
_items=("---:alpha" "api" "worker" "---:beta" "api" "---:gamma" "(all services)")
_picker_project_map=(0 0 1 2)
_picker_svc_map=(api worker api __all__)

# ────────────────────────────────────────
echo "  Group picker — per-project service filter"
# ────────────────────────────────────────

_group_svc_filter=()
_group_build_svc_filter 3 "1" "${_items[@]}"
_test_eq "selecting alpha/api keeps alpha filtered to api" "api" "${_group_svc_filter[0]}"
_test_eq "same-named beta/api is not selected" "__none__" "${_group_svc_filter[1]}"
_test_eq "unselected placeholder project is skipped" "__none__" "${_group_svc_filter[2]}"

_group_svc_filter=()
_group_build_svc_filter 3 "1 2 4 6" "${_items[@]}"
_test_eq "multiple services in one project" "api worker" "${_group_svc_filter[0]}"
_test_eq "beta/api selected by index" "api" "${_group_svc_filter[1]}"
_test_eq "selected placeholder deploys all services" "" "${_group_svc_filter[2]}"

_group_svc_filter=()
_group_build_svc_filter 3 "" "${_items[@]}"
_test_eq "nothing selected skips alpha" "__none__" "${_group_svc_filter[0]}"
_test_eq "nothing selected skips beta" "__none__" "${_group_svc_filter[1]}"

_test_summary
