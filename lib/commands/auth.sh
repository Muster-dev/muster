#!/usr/bin/env bash
# muster/lib/commands/auth.sh — Token management CLI

cmd_auth() {
  case "${1:-}" in
    create)
      shift
      local name="" scope="read"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --scope|-s) scope="$2"; shift 2 ;;
          --help|-h)
            echo "Usage: muster auth create <name> [--scope <scope>]"
            echo ""
            echo "Generate a new API token for JSON API access."
            echo ""
            echo "Options:"
            echo "  --scope, -s <scope>   Token scope: read, deploy, admin (default: read)"
            echo ""
            echo "Scopes:"
            echo "  read     View status, history, doctor, settings"
            echo "  deploy   Read + deploy, rollback, logs"
            echo "  admin    Full access including setup, auth, uninstall"
            echo ""
            echo "Examples:"
            echo "  muster auth create my-laptop --scope admin"
            echo "  muster auth create ci-bot --scope deploy"
            echo "  muster auth create dashboard --scope read"
            return 0
            ;;
          --*)
            err "Unknown flag: $1"
            return 1
            ;;
          *)
            name="$1"
            shift
            ;;
        esac
      done

      if [[ -z "$name" ]]; then
        err "Usage: muster auth create <name> --scope <scope>"
        return 1
      fi

      local token
      token=$(auth_create_token "$name" "$scope") || return 1

      echo ""
      echo -e "  ${GREEN}Token created${RESET}"
      echo ""
      echo -e "  Name:   ${BOLD}${name}${RESET}"
      echo -e "  Scope:  ${scope}"
      echo -e "  Token:  ${ACCENT}${token}${RESET}"
      echo ""
      echo -e "  ${YELLOW}Save this token now -- it won't be shown again.${RESET}"
      echo -e "  ${DIM}Set MUSTER_TOKEN=<token> when using --json commands.${RESET}"
      echo ""
      ;;

    list)
      auth_list_tokens
      ;;

    revoke)
      shift
      if [[ -z "${1:-}" ]]; then
        err "Usage: muster auth revoke <name>"
        return 1
      fi
      auth_revoke_token "$1"
      ;;

    verify)
      if auth_validate_token; then
        echo -e "  ${GREEN}Valid${RESET} -- scope: ${BOLD}${AUTH_SCOPE}${RESET}"
      fi
      ;;

    --help|-h|"")
      echo "Usage: muster auth <command>"
      echo ""
      echo "Manage API tokens for secure JSON API access."
      echo ""
      echo "Commands:"
      echo "  create <name> --scope <scope>   Generate a new token"
      echo "  list                            List all tokens"
      echo "  revoke <name>                   Revoke a token"
      echo "  verify                          Validate MUSTER_TOKEN env var"
      echo ""
      echo "Scopes:"
      echo "  read     View status, history, doctor, settings"
      echo "  deploy   Read + deploy, rollback, logs"
      echo "  admin    Full access including setup, auth, uninstall"
      echo ""
      echo "Examples:"
      echo "  muster auth create ci-bot --scope deploy"
      echo "  MUSTER_TOKEN=abc123 muster status --json"
      ;;

    *)
      err "Unknown auth command: $1"
      echo "Run 'muster auth --help' for usage."
      return 1
      ;;
  esac
}
