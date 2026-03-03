#!/usr/bin/env bash
# muster/lib/commands/trust.sh — Fleet Trust CLI command handler

source "$MUSTER_ROOT/lib/core/trust.sh"

cmd_trust() {
  case "${1:-}" in
    request)    shift; _trust_cmd_request "$@" ;;
    verify)     shift; _trust_cmd_verify "$@" ;;
    requests)   shift; _trust_cmd_requests "$@" ;;
    accept)     shift; _trust_cmd_accept "$@" ;;
    reject)     shift; _trust_cmd_reject "$@" ;;
    trusted)    shift; _trust_cmd_trusted "$@" ;;
    revoke)     shift; _trust_cmd_revoke "$@" ;;
    identity)   shift; _trust_cmd_identity "$@" ;;
    --help|-h)  _trust_cmd_help ;;
    "")
      if [[ -t 0 ]]; then
        _trust_cmd_manager
      else
        _trust_cmd_help
      fi
      ;;
    *)
      err "Unknown trust command: $1"
      echo "Run 'muster trust --help' for usage."
      return 1
      ;;
  esac
}

# ── Internal commands (called via SSH) ──

_trust_cmd_request() {
  local fingerprint="" label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fingerprint) fingerprint="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$fingerprint" ]]; then
    echo "error: --fingerprint required" >&2
    return 1
  fi
  [[ -z "$label" ]] && label="unknown"

  trust_add_pending "$fingerprint" "$label"
}

_trust_cmd_verify() {
  local fingerprint=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fingerprint) fingerprint="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$fingerprint" ]]; then
    echo "error: --fingerprint required" >&2
    return 1
  fi

  trust_check_deploy "$fingerprint"
}

# ── User-facing commands ──

_trust_cmd_requests() {
  local count
  count=$(trust_pending_count)

  if [[ "$count" == "0" ]]; then
    info "No pending trust requests."
    return 0
  fi

  echo ""
  printf '  %b%bPending Trust Requests%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}"
  echo ""
  printf "  ${BOLD}%-4s  %-20s  %-24s  %-20s${RESET}\n" "#" "FINGERPRINT" "LABEL" "REQUESTED"
  printf "  ${DIM}%-4s  %-20s  %-24s  %-20s${RESET}\n" "----" "--------------------" "------------------------" "--------------------"

  local idx=0
  while IFS='|' read -r fp label requested; do
    [[ -z "$fp" ]] && continue
    idx=$(( idx + 1 ))
    local short_fp="${fp:0:20}"
    printf "  %-4s  %-20s  %-24s  ${DIM}%-20s${RESET}\n" "$idx" "$short_fp" "$label" "$requested"
  done < <(trust_list_pending)

  echo ""
  printf '  %bAccept: muster trust accept <# or fingerprint>%b\n' "${DIM}" "${RESET}"
  printf '  %bReject: muster trust reject <# or fingerprint>%b\n' "${DIM}" "${RESET}"
  echo ""
}

_trust_configure_sudo() {
  local _user="${USER:-$(whoami)}"
  local _sudoers_file="/etc/sudoers.d/muster-${_user}"

  # Skip if user already has NOPASSWD sudo
  if sudo -n true 2>/dev/null; then
    return 0
  fi

  info "Configuring passwordless sudo for fleet deploys..."
  printf '  %bFleet deploys run non-interactively over SSH and need sudo without a prompt.%b\n' "${DIM}" "${RESET}"
  printf '  %bThis only affects the %s user — other accounts are unchanged.%b\n' "${DIM}" "$_user" "${RESET}"
  echo ""

  local _entry="${_user} ALL=(ALL) NOPASSWD: ALL"

  if ! echo "$_entry" | sudo tee "$_sudoers_file" >/dev/null 2>&1; then
    warn "Could not configure sudo — fleet deploys using sudo may fail"
    printf '  %bManually run: echo "%s" | sudo tee %s%b\n' "${DIM}" "$_entry" "$_sudoers_file" "${RESET}"
    return 0
  fi

  sudo chmod 440 "$_sudoers_file" 2>/dev/null

  # Validate the sudoers entry
  if sudo visudo -c -f "$_sudoers_file" &>/dev/null; then
    ok "Sudo configured for ${_user} (fleet deploys)"
  else
    sudo rm -f "$_sudoers_file"
    warn "Invalid sudoers entry — removed. Fleet deploys using sudo may fail."
  fi
}

_trust_cmd_accept() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    err "Usage: muster trust accept <fingerprint or #>"
    return 1
  fi

  if trust_accept "$id"; then
    ok "Trust accepted"
    _trust_configure_sudo
  else
    err "Request not found: ${id}"
    return 1
  fi
}

_trust_cmd_reject() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    err "Usage: muster trust reject <fingerprint or #>"
    return 1
  fi

  if trust_reject "$id"; then
    ok "Request rejected"
  else
    err "Request not found: ${id}"
    return 1
  fi
}

_trust_cmd_trusted() {
  _trust_ensure_files
  local count
  count=$(jq 'length' "$MUSTER_TRUST_FILE" 2>/dev/null)
  [[ -z "$count" || "$count" == "null" ]] && count=0

  if [[ "$count" == "0" ]]; then
    info "No trusted deployers."
    return 0
  fi

  echo ""
  printf '  %b%bTrusted Deployers%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}"
  echo ""
  printf "  ${BOLD}%-4s  %-20s  %-24s  %-20s${RESET}\n" "#" "FINGERPRINT" "LABEL" "ACCEPTED"
  printf "  ${DIM}%-4s  %-20s  %-24s  %-20s${RESET}\n" "----" "--------------------" "------------------------" "--------------------"

  local idx=0
  while IFS='|' read -r fp label accepted; do
    [[ -z "$fp" ]] && continue
    idx=$(( idx + 1 ))
    local short_fp="${fp:0:20}"
    printf "  %-4s  %-20s  %-24s  ${DIM}%-20s${RESET}\n" "$idx" "$short_fp" "$label" "$accepted"
  done < <(trust_list_trusted)

  echo ""
  printf '  %bRevoke: muster trust revoke <# or fingerprint>%b\n' "${DIM}" "${RESET}"
  echo ""
}

_trust_cmd_revoke() {
  local id="${1:-}"
  if [[ -z "$id" ]]; then
    err "Usage: muster trust revoke <fingerprint or #>"
    return 1
  fi

  if trust_revoke "$id"; then
    ok "Trust revoked"
  else
    err "Deployer not found: ${id}"
    return 1
  fi
}

_trust_cmd_identity() {
  _trust_ensure_identity

  local fp label created
  fp=$(jq -r '.fingerprint' "$MUSTER_IDENTITY_FILE" 2>/dev/null)
  label=$(trust_label)
  created=$(jq -r '.created' "$MUSTER_IDENTITY_FILE" 2>/dev/null)

  echo ""
  printf '  %b%bMuster Identity%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}"
  echo ""
  printf '  %bFingerprint:%b  %s\n' "${DIM}" "${RESET}" "$fp"
  printf '  %bLabel:%b        %s\n' "${DIM}" "${RESET}" "$label"
  printf '  %bCreated:%b      %s\n' "${DIM}" "${RESET}" "$created"
  echo ""
}

# ── Interactive manager ──

_trust_cmd_manager() {
  source "$MUSTER_ROOT/lib/tui/menu.sh"

  while true; do
    local pending_count trusted_count
    pending_count=$(trust_pending_count)
    trusted_count=$(jq 'length' "$MUSTER_TRUST_FILE" 2>/dev/null)
    [[ -z "$trusted_count" || "$trusted_count" == "null" ]] && trusted_count=0

    echo ""
    printf '  %b%bFleet Trust%b\n' "${BOLD}" "${ACCENT_BRIGHT}" "${RESET}"
    echo ""

    local actions=()
    if [[ "$pending_count" -gt 0 ]] 2>/dev/null; then
      actions[${#actions[@]}]="Pending requests (${pending_count})"
    fi
    actions[${#actions[@]}]="Trusted deployers (${trusted_count})"
    actions[${#actions[@]}]="My identity"
    actions[${#actions[@]}]="Back"

    menu_select "Trust Management" "${actions[@]}"

    case "$MENU_RESULT" in
      "Back"|"__back__")
        return 0
        ;;
      "My identity")
        _trust_cmd_identity
        ;;
      "Trusted deployers"*)
        _trust_cmd_trusted
        ;;
      "Pending requests"*)
        _trust_manage_pending
        ;;
    esac
  done
}

_trust_manage_pending() {
  source "$MUSTER_ROOT/lib/tui/menu.sh"

  while true; do
    local entries=()
    local fps=()
    local labels=()

    while IFS='|' read -r fp label requested; do
      [[ -z "$fp" ]] && continue
      entries[${#entries[@]}]="${label} (${fp:0:12}...)"
      fps[${#fps[@]}]="$fp"
      labels[${#labels[@]}]="$label"
    done < <(trust_list_pending)

    if (( ${#entries[@]} == 0 )); then
      info "No pending requests."
      return 0
    fi

    entries[${#entries[@]}]="Back"

    menu_select "Pending Trust Requests" "${entries[@]}"

    if [[ "$MENU_RESULT" == "Back" || "$MENU_RESULT" == "__back__" ]]; then
      return 0
    fi

    # Find which entry was selected
    local _si=0
    local _selected_fp=""
    local _selected_label=""
    while (( _si < ${#fps[@]} )); do
      if [[ "$MENU_RESULT" == "${labels[$_si]} (${fps[$_si]:0:12}...)" ]]; then
        _selected_fp="${fps[$_si]}"
        _selected_label="${labels[$_si]}"
        break
      fi
      _si=$(( _si + 1 ))
    done

    [[ -z "$_selected_fp" ]] && continue

    echo ""
    printf '  %bFingerprint:%b %s\n' "${DIM}" "${RESET}" "$_selected_fp"
    printf '  %bLabel:%b       %s\n' "${DIM}" "${RESET}" "$_selected_label"
    echo ""

    menu_select "What do you want to do?" "Accept" "Reject" "Back"

    case "$MENU_RESULT" in
      "Accept")
        trust_accept "$_selected_fp"
        ok "Trusted: ${_selected_label}"
        _trust_configure_sudo
        ;;
      "Reject")
        trust_reject "$_selected_fp"
        ok "Rejected: ${_selected_label}"
        ;;
    esac
  done
}

_trust_cmd_help() {
  printf '%b\n' "${BOLD}muster trust${RESET} — Manage fleet deploy trust"
  echo ""
  echo "Usage: muster trust <command>"
  echo ""
  echo "Commands:"
  echo "  requests              List pending join requests"
  echo "  accept <# or fp>     Accept a pending request"
  echo "  reject <# or fp>     Reject a pending request"
  echo "  trusted               List trusted deployers"
  echo "  revoke <# or fp>     Revoke a trusted deployer"
  echo "  identity              Show this machine's fingerprint"
  echo ""
  echo "When another machine runs 'muster group add' targeting this host,"
  echo "a trust request is created. Accept it to allow deploys."
  echo ""
  echo "Examples:"
  echo "  muster trust requests          See who wants to deploy here"
  echo "  muster trust accept 1          Accept the first pending request"
  echo "  muster trust trusted           See who is authorized"
  echo "  muster trust revoke 1          Remove access for deployer #1"
}
