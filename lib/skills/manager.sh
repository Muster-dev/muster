#!/usr/bin/env bash
# muster/lib/skills/manager.sh — Skill management
# Skills are per-project (.muster/skills/) with global fallback (~/.muster/skills/).

GLOBAL_SKILLS_DIR="${HOME}/.muster/skills"

# Resolve the active skills directory:
# - Inside a project: .muster/skills/ (per-project)
# - Outside a project: ~/.muster/skills/ (global)
_skills_resolve_dir() {
  # If CONFIG_FILE is set, use that project
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    echo "$(dirname "$CONFIG_FILE")/.muster/skills"
    return
  fi
  # Try to find a config file without erroring
  local _cfg
  _cfg=$(find_config 2>/dev/null) || true
  if [[ -n "$_cfg" ]]; then
    echo "$(dirname "$_cfg")/.muster/skills"
    return
  fi
  echo "$GLOBAL_SKILLS_DIR"
}

# Set SKILLS_DIR based on context (called at the start of commands)
_skills_set_dir() {
  SKILLS_DIR="$(_skills_resolve_dir)"
}

SKILLS_DIR="${HOME}/.muster/skills"

cmd_skill() {
  case "${1:-}" in
    --help|-h)
      echo "Usage: muster skill [--global] <command> [args]"
      echo ""
      echo "Manage addon skills."
      echo ""
      echo "Skills are per-project by default (stored in .muster/skills/)."
      echo "Use --global to manage skills in ~/.muster/skills/ (shared across projects)."
      echo ""
      echo "Commands:"
      echo "  add <url>            Install a skill from a git URL or local path"
      echo "  create <name>        Scaffold a new skill"
      echo "  remove <name>        Remove an installed skill"
      echo "  list                 List installed skills"
      echo "  run <name>           Run a skill manually"
      echo "  configure <name>     Configure a skill (API keys, webhooks, etc.)"
      echo "  enable <name>        Enable auto-run on deploy/rollback hooks"
      echo "  disable <name>       Disable auto-run (manual only)"
      echo "  marketplace [query]  Browse and install skills from the official registry"
      echo ""
      echo "Options:"
      echo "  --global             Operate on global skills (~/.muster/skills/)"
      return 0
      ;;
  esac

  # Check for --global flag before action
  local _use_global=false
  if [[ "${1:-}" == "--global" ]]; then
    _use_global=true
    shift
  fi

  local action="${1:-list}"
  shift 2>/dev/null || true

  # Check for --global after action too (muster skill add --global <url>)
  local args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--global" ]]; then
      _use_global=true
    else
      args[${#args[@]}]="$1"
    fi
    shift
  done

  # Set SKILLS_DIR based on scope
  if [[ "$_use_global" == "true" ]]; then
    SKILLS_DIR="$GLOBAL_SKILLS_DIR"
  else
    _skills_set_dir
  fi

  case "$action" in
    add|install)
      skill_add "${args[@]}"
      ;;
    create|new)
      skill_create "${args[@]}"
      ;;
    remove|uninstall)
      skill_remove "${args[@]}"
      ;;
    list|ls)
      skill_list
      ;;
    run)
      skill_run "${args[@]}"
      ;;
    configure|config)
      skill_configure "${args[@]}"
      ;;
    enable)
      skill_enable "${args[@]}"
      ;;
    disable)
      skill_disable "${args[@]}"
      ;;
    marketplace|browse|search)
      skill_marketplace "${args[@]}"
      ;;
    *)
      err "Unknown skill command: ${action}"
      echo "Usage: muster skill [--global] [add|create|remove|list|run|configure|enable|disable|marketplace]"
      exit 1
      ;;
  esac
}

skill_add() {
  local source="${1:-}"

  if [[ -z "$source" ]]; then
    err "Usage: muster skill add <git-url-or-path>"
    exit 1
  fi

  mkdir -p "$SKILLS_DIR"

  # Clone from git
  if [[ "$source" =~ ^https?:// || "$source" =~ ^git@ ]]; then
    local skill_name
    skill_name=$(basename "$source" .git)
    skill_name="${skill_name#muster-skill-}"  # strip common prefix

    if [[ -d "${SKILLS_DIR}/${skill_name}" ]]; then
      warn "Skill '${skill_name}' already installed. Updating..."
      (cd "${SKILLS_DIR}/${skill_name}" && git pull --quiet)
    else
      start_spinner "Installing skill: ${skill_name}"
      git clone --quiet "$source" "${SKILLS_DIR}/${skill_name}" 2>/dev/null
      stop_spinner
    fi

    # Validate
    if [[ ! -f "${SKILLS_DIR}/${skill_name}/skill.json" ]]; then
      err "Invalid skill: missing skill.json"
      rm -rf "${SKILLS_DIR}/${skill_name}"
      exit 1
    fi

    ok "Skill '${skill_name}' installed"
  else
    # Local path
    local skill_name
    skill_name=$(basename "$source")
    skill_name="${skill_name#muster-skill-}"  # strip common prefix

    # Read name from skill.json if available
    local source_dir="$source"
    if [[ -f "${source_dir}/skill.json" ]]; then
      local json_name=""
      if has_cmd jq; then
        json_name=$(jq -r '.name // ""' "${source_dir}/skill.json")
      elif has_cmd python3; then
        json_name=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('name',''))" "${source_dir}/skill.json" 2>/dev/null)
      fi
      if [[ -n "$json_name" ]]; then
        skill_name="$json_name"
      fi
    fi

    if [[ -d "${SKILLS_DIR}/${skill_name}" ]]; then
      warn "Skill '${skill_name}' already installed. Updating..."
      # Preserve user config and state across update
      local _tmp_preserve
      _tmp_preserve=$(mktemp -d)
      [[ -f "${SKILLS_DIR}/${skill_name}/config.env" ]] && cp "${SKILLS_DIR}/${skill_name}/config.env" "$_tmp_preserve/"
      [[ -f "${SKILLS_DIR}/${skill_name}/.enabled" ]] && touch "$_tmp_preserve/.enabled"
      rm -rf "${SKILLS_DIR}/${skill_name}"
      cp -r "$source" "${SKILLS_DIR}/${skill_name}"
      # Restore preserved files
      [[ -f "$_tmp_preserve/config.env" ]] && cp "$_tmp_preserve/config.env" "${SKILLS_DIR}/${skill_name}/"
      [[ -f "$_tmp_preserve/.enabled" ]] && touch "${SKILLS_DIR}/${skill_name}/.enabled"
      rm -rf "$_tmp_preserve"
    else
      cp -r "$source" "${SKILLS_DIR}/${skill_name}"
    fi
    ok "Skill '${skill_name}' installed from local path"
  fi
}

skill_create() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster skill create <name>"
    exit 1
  fi

  # Sanitize: lowercase, hyphens for spaces/underscores
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[_ ]/-/g')

  mkdir -p "$SKILLS_DIR"

  if [[ -d "${SKILLS_DIR}/${name}" ]]; then
    err "Skill '${name}' already exists at ${SKILLS_DIR}/${name}"
    return 1
  fi

  mkdir -p "${SKILLS_DIR}/${name}"

  # Write skill.json
  cat > "${SKILLS_DIR}/${name}/skill.json" << SKILLJSON
{
  "name": "${name}",
  "version": "1.0.0",
  "description": "TODO: describe your skill",
  "author": "",
  "hooks": [],
  "requires": []
}
SKILLJSON

  # Write run.sh stub
  cat > "${SKILLS_DIR}/${name}/run.sh" << 'RUNSH'
#!/usr/bin/env bash
# run.sh — skill entry point
#
# Environment variables available:
#   MUSTER_PROJECT_DIR   — path to the project root
#   MUSTER_CONFIG_FILE   — path to muster.json
#   MUSTER_SERVICE       — current service name (if run per-service)
#   MUSTER_HOOK          — which hook triggered this (e.g. "post-deploy")

echo "Hello from skill!"

# Your logic here
RUNSH
  chmod +x "${SKILLS_DIR}/${name}/run.sh"

  ok "Skill '${name}' created"
  echo ""
  echo -e "  ${DIM}${SKILLS_DIR}/${name}/${RESET}"
  echo -e "  ${DIM}  skill.json  — edit name, description, hooks${RESET}"
  echo -e "  ${DIM}  run.sh      — add your logic${RESET}"
  echo ""
  echo -e "  ${DIM}Hooks: add \"pre-deploy\", \"post-deploy\", \"pre-rollback\",${RESET}"
  echo -e "  ${DIM}       \"post-rollback\" to the hooks array in skill.json${RESET}"
  echo ""
  echo -e "  ${DIM}Test: muster skill run ${name}${RESET}"
  echo ""
}

skill_remove() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster skill remove <name>"
    exit 1
  fi

  if [[ -d "${SKILLS_DIR}/${name}" ]]; then
    rm -rf "${SKILLS_DIR}/${name}"
    ok "Skill '${name}' removed"
  else
    err "Skill '${name}' not found"
    exit 1
  fi
}

skill_list() {
  echo ""
  echo -e "  ${BOLD}Installed Skills${RESET}"
  echo ""

  local _found=false
  local _project_dir=""
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    _project_dir="$(dirname "$CONFIG_FILE")/.muster/skills"
  else
    local _cfg
    _cfg=$(find_config 2>/dev/null) || true
    if [[ -n "$_cfg" ]]; then
      _project_dir="$(dirname "$_cfg")/.muster/skills"
    fi
  fi

  # List project skills
  if [[ -n "$_project_dir" && -d "$_project_dir" ]] && [[ -n "$(ls -A "$_project_dir" 2>/dev/null)" ]]; then
    echo -e "  ${DIM}Project skills:${RESET}"
    _skill_list_dir "$_project_dir"
    _found=true
  fi

  # List global skills
  if [[ -d "$GLOBAL_SKILLS_DIR" ]] && [[ -n "$(ls -A "$GLOBAL_SKILLS_DIR" 2>/dev/null)" ]]; then
    if [[ "$_found" == "true" ]]; then
      echo ""
    fi
    echo -e "  ${DIM}Global skills:${RESET}"
    _skill_list_dir "$GLOBAL_SKILLS_DIR"
    _found=true
  fi

  if [[ "$_found" == "false" ]]; then
    info "No skills installed"
    echo -e "  ${DIM}Run 'muster skill add <git-url>' to install one${RESET}"
  fi
  echo ""
}

# Helper: list skills in a given directory
_skill_list_dir() {
  local dir="$1"
  for skill_dir in "${dir}"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    local name
    name=$(basename "$skill_dir")
    local desc="" hooks_raw=""

    if [[ -f "${skill_dir}/skill.json" ]]; then
      if has_cmd jq; then
        desc=$(jq -r '.description // ""' "${skill_dir}/skill.json")
        hooks_raw=$(jq -r '(.hooks // []) | join(", ")' "${skill_dir}/skill.json")
      fi
    fi

    local _mode_tag=""
    if [[ -z "$hooks_raw" ]]; then
      _mode_tag="${DIM}manual only${RESET}"
    elif [[ -f "${skill_dir}/.enabled" ]]; then
      local _hooks_short
      _hooks_short=$(printf '%s' "$hooks_raw" | sed 's/post-//g; s/pre-/pre-/g')
      _mode_tag="${GREEN}on ${_hooks_short}${RESET}"
    else
      _mode_tag="${DIM}disabled${RESET}"
    fi

    echo -e "  ${ACCENT}*${RESET} ${BOLD}${name}${RESET}  ${_mode_tag}  ${DIM}${desc}${RESET}"
  done
}

# Load a skill's config.env into the environment
# Usage: _skill_load_config "slack"           (resolves via SKILLS_DIR)
#        _skill_load_config "/full/path/slack" (absolute path)
_SKILL_CONFIG_KEYS=""
_skill_load_config() {
  local name="$1"
  local config_file
  if [[ "$name" == /* ]]; then
    config_file="${name}/config.env"
  else
    config_file="${SKILLS_DIR}/${name}/config.env"
  fi
  _SKILL_CONFIG_KEYS=""
  [[ ! -f "$config_file" ]] && return 0
  while IFS='=' read -r _ck _cv; do
    [[ -z "$_ck" ]] && continue
    [[ "$_ck" == \#* ]] && continue
    # Don't override existing env vars
    if [[ -z "${!_ck:-}" ]]; then
      export "$_ck=$_cv"
      if [[ -n "$_SKILL_CONFIG_KEYS" ]]; then
        _SKILL_CONFIG_KEYS="${_SKILL_CONFIG_KEYS} ${_ck}"
      else
        _SKILL_CONFIG_KEYS="$_ck"
      fi
    fi
  done < "$config_file"
}

# Unload skill config vars
_skill_unload_config() {
  local _ck
  for _ck in $_SKILL_CONFIG_KEYS; do
    unset "$_ck" 2>/dev/null
  done
  _SKILL_CONFIG_KEYS=""
}

# Configure a skill interactively
# Reads config[] from skill.json, prompts for each value, saves to config.env
skill_configure() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    err "Usage: muster skill configure <name>"
    return 1
  fi

  local skill_dir="${SKILLS_DIR}/${name}"
  local skill_json="${skill_dir}/skill.json"

  if [[ ! -f "$skill_json" ]]; then
    err "Skill '${name}' not found"
    return 1
  fi

  if ! has_cmd jq; then
    err "jq required for skill configuration"
    return 1
  fi

  local config_count hooks_raw hooks_short
  config_count=$(jq '.config // [] | length' "$skill_json")
  hooks_raw=$(jq -r '(.hooks // []) | join(", ")' "$skill_json")
  hooks_short=$(printf '%s' "$hooks_raw" | sed 's/post-//g; s/pre-/pre-/g')

  local config_file="${skill_dir}/config.env"

  echo ""
  printf '%b\n' "  ${BOLD}Configure: ${name}${RESET}"
  if [[ -n "$hooks_raw" ]]; then
    printf '%b\n' "  ${DIM}Runs on: ${hooks_short}${RESET}"
  else
    printf '%b\n' "  ${DIM}Manual only (no hooks)${RESET}"
  fi
  echo ""

  if [[ "$config_count" -eq 0 && -z "$hooks_raw" ]]; then
    info "Skill '${name}' has no configurable options"
    return 0
  fi

  local i=0
  local new_config=""
  while (( i < config_count )); do
    local key label hint is_secret current_val
    key=$(jq -r ".config[$i].key" "$skill_json")
    label=$(jq -r ".config[$i].label // .config[$i].key" "$skill_json")
    hint=$(jq -r ".config[$i].hint // \"\"" "$skill_json")
    is_secret=$(jq -r ".config[$i].secret // false" "$skill_json")

    # Read current value from config.env if exists
    current_val=""
    if [[ -f "$config_file" ]]; then
      current_val=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d= -f2-)
    fi

    printf '%b\n' "  ${ACCENT}${label}${RESET}"
    if [[ -n "$hint" ]]; then
      printf '%b\n' "  ${DIM}${hint}${RESET}"
    fi

    if [[ -n "$current_val" ]]; then
      if [[ "$is_secret" == "true" ]]; then
        local masked="${current_val:0:4}$(printf '%*s' $(( ${#current_val} - 4 )) '' | tr ' ' '*')"
        if (( ${#current_val} <= 4 )); then
          masked="****"
        fi
        printf '%b' "  ${DIM}Current: ${masked}${RESET}\n"
      else
        printf '%b' "  ${DIM}Current: ${current_val}${RESET}\n"
      fi
    fi

    printf '%b' "  > "
    local input=""
    if [[ "$is_secret" == "true" ]]; then
      read -rs input
      echo ""
    else
      read -r input
    fi

    # Keep current value if user just pressed enter
    if [[ -z "$input" && -n "$current_val" ]]; then
      input="$current_val"
    fi

    if [[ -n "$input" ]]; then
      if [[ -n "$new_config" ]]; then
        new_config="${new_config}"$'\n'"${key}=${input}"
      else
        new_config="${key}=${input}"
      fi
    fi

    echo ""
    i=$((i + 1))
  done

  # Write config.env
  if [[ -n "$new_config" ]]; then
    printf '%s\n' "$new_config" > "$config_file"
    ok "Configuration saved for '${name}'"
  elif [[ "$config_count" -gt 0 ]]; then
    warn "No configuration values provided"
  fi

  # Prompt to enable/disable if skill has hooks
  if [[ -n "$hooks_raw" ]]; then
    echo ""
    if [[ -f "${skill_dir}/.enabled" ]]; then
      printf '%b\n' "  ${DIM}Status: enabled (runs on ${hooks_short})${RESET}"
      printf '%b' "  Disable auto-run? (y/n) "
      local _toggle=""
      read -rsn1 _toggle
      echo ""
      if [[ "$_toggle" == "y" || "$_toggle" == "Y" ]]; then
        skill_disable "$name"
      fi
    else
      printf '%b\n' "  ${DIM}This skill can run on: ${hooks_short}${RESET}"
      printf '%b' "  Enable auto-run? (y/n) "
      local _toggle=""
      read -rsn1 _toggle
      echo ""
      if [[ "$_toggle" == "y" || "$_toggle" == "Y" ]]; then
        skill_enable "$name"
      fi
    fi
  fi
}

skill_run() {
  local name="${1:-}"
  shift 2>/dev/null || true

  if [[ -z "$name" ]]; then
    err "Usage: muster skill run <name> [args...]"
    return 1
  fi

  # Find skill: check SKILLS_DIR first, then fall back to global
  local run_script="${SKILLS_DIR}/${name}/run.sh"
  local _skill_base="${SKILLS_DIR}/${name}"
  if [[ ! -x "$run_script" && "$SKILLS_DIR" != "$GLOBAL_SKILLS_DIR" ]]; then
    if [[ -x "${GLOBAL_SKILLS_DIR}/${name}/run.sh" ]]; then
      run_script="${GLOBAL_SKILLS_DIR}/${name}/run.sh"
      _skill_base="${GLOBAL_SKILLS_DIR}/${name}"
    fi
  fi

  if [[ ! -x "$run_script" ]]; then
    err "Skill '${name}' not found or not executable"
    return 1
  fi

  # Export context env vars
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    export MUSTER_PROJECT_DIR="$(dirname "$CONFIG_FILE")"
    export MUSTER_CONFIG_FILE="$CONFIG_FILE"
  fi

  _load_env_file
  _skill_load_config "$_skill_base"

  "$run_script" "$@"
  local rc=$?

  _skill_unload_config
  _unload_env_file
  unset MUSTER_PROJECT_DIR MUSTER_CONFIG_FILE 2>/dev/null
  return $rc
}

# Run all skills that declare a given hook
# Checks project skills first, then global skills (skipping duplicates).
# Usage: run_skill_hooks "post-deploy" "api"
# Non-fatal: warns on failure, never blocks deploy/rollback
run_skill_hooks() {
  local hook_name="${1:-}" svc_name="${2:-}"

  # Build list of skill dirs to check: project first, then global
  local _skill_dirs=""
  local _project_skills_dir=""
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    _project_skills_dir="$(dirname "$CONFIG_FILE")/.muster/skills"
    if [[ -d "$_project_skills_dir" ]]; then
      _skill_dirs="$_project_skills_dir"
    fi
  fi
  if [[ -d "$GLOBAL_SKILLS_DIR" ]]; then
    if [[ -n "$_skill_dirs" ]]; then
      _skill_dirs="${_skill_dirs}:${GLOBAL_SKILLS_DIR}"
    else
      _skill_dirs="$GLOBAL_SKILLS_DIR"
    fi
  fi

  [[ -z "$_skill_dirs" ]] && return 0

  # Track which skill names have already run (project takes priority)
  local _ran_skills=""

  local IFS_SAVE="$IFS"
  IFS=':'
  local _sdir
  for _sdir in $_skill_dirs; do
    IFS="$IFS_SAVE"
    local skill_dir
    for skill_dir in "${_sdir}"/*/; do
      [[ ! -d "$skill_dir" ]] && continue
      [[ ! -f "${skill_dir}/skill.json" ]] && continue
      [[ ! -x "${skill_dir}/run.sh" ]] && continue

      # Only auto-run skills that are enabled
      [[ ! -f "${skill_dir}/.enabled" ]] && continue

      local skill_name
      skill_name=$(basename "$skill_dir")

      # Skip if already ran (project version takes priority over global)
      case " $_ran_skills " in
        *" $skill_name "*) continue ;;
      esac

      # Check if this skill declares the hook
      local has_hook="false"
      if has_cmd jq; then
        local match=""
        match=$(jq -r --arg h "$hook_name" '.hooks // [] | map(select(. == $h)) | length' "${skill_dir}/skill.json" 2>/dev/null)
        [[ "$match" != "0" && -n "$match" ]] && has_hook="true"
      elif has_cmd python3; then
        local match=""
        match=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('yes' if sys.argv[2] in d.get('hooks',[]) else 'no')
" "${skill_dir}/skill.json" "$hook_name" 2>/dev/null)
        [[ "$match" == "yes" ]] && has_hook="true"
      fi

      if [[ "$has_hook" == "true" ]]; then
        _ran_skills="${_ran_skills} ${skill_name}"

        # Export context
        if [[ -n "${CONFIG_FILE:-}" ]]; then
          export MUSTER_PROJECT_DIR="$(dirname "$CONFIG_FILE")"
          export MUSTER_CONFIG_FILE="$CONFIG_FILE"
        fi
        export MUSTER_SERVICE="$svc_name"
        export MUSTER_HOOK="$hook_name"

        _load_env_file
        _skill_load_config "${skill_dir%/}"

        "${skill_dir}/run.sh" 2>&1 || {
          warn "Skill '${skill_name}' failed on ${hook_name} (non-fatal)"
        }

        _skill_unload_config
        _unload_env_file
        unset MUSTER_PROJECT_DIR MUSTER_CONFIG_FILE MUSTER_SERVICE MUSTER_HOOK 2>/dev/null
      fi
    done
  done
  IFS="$IFS_SAVE"
}

# ---------------------------------------------------------------------------
# Skill Marketplace — browse and install from the official registry
# ---------------------------------------------------------------------------

SKILL_REGISTRY_URL="https://raw.githubusercontent.com/ImJustRicky/muster-skills/main/registry.json"

skill_marketplace() {
  source "$MUSTER_ROOT/lib/tui/checklist.sh"
  source "$MUSTER_ROOT/lib/tui/spinner.sh"

  if ! has_cmd jq; then
    err "The marketplace requires jq. Install it first: https://jqlang.github.io/jq/download/"
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp)

  start_spinner "Fetching skill registry..."
  if ! curl -fsSL "$SKILL_REGISTRY_URL" -o "$tmp_file" 2>/dev/null; then
    stop_spinner
    err "Failed to fetch skill registry"
    rm -f "$tmp_file"
    return 1
  fi
  stop_spinner

  local query="${1:-}"

  if [[ -z "$query" && -t 0 ]]; then
    echo ""
    printf '%b\n' "  ${BOLD}Skill Marketplace${RESET}"
    echo ""
    printf '%b' "  ${DIM}Search (or press enter to browse all):${RESET} "
    read -r query
  fi

  if [[ -n "$query" ]]; then
    _marketplace_search "$tmp_file" "$query"
  else
    _marketplace_browse "$tmp_file"
  fi

  rm -f "$tmp_file"
}

_marketplace_search() {
  local registry="$1"
  local query="$2"

  local matches
  matches=$(jq -r --arg q "$query" \
    '[.skills[] | select((.name | ascii_downcase | contains($q | ascii_downcase)) or (.description | ascii_downcase | contains($q | ascii_downcase)))]' \
    "$registry")

  local match_count
  match_count=$(printf '%s' "$matches" | jq 'length')

  if [[ "$match_count" -eq 0 ]]; then
    echo ""
    warn "No skills matching '${query}'"
    echo ""
    return 0
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Marketplace results for '${query}'${RESET}"
  echo ""

  local i=0
  local names=()
  while [[ "$i" -lt "$match_count" ]]; do
    local name desc version installed_tag=""
    name=$(printf '%s' "$matches" | jq -r ".[$i].name")
    desc=$(printf '%s' "$matches" | jq -r ".[$i].description // \"\"")
    version=$(printf '%s' "$matches" | jq -r ".[$i].version // \"0.0.0\"")

    if [[ -d "${SKILLS_DIR}/${name}" ]]; then
      installed_tag=" ${GREEN}(installed)${RESET}"
    fi

    printf '%b\n' "  ${BOLD}${name}${RESET}${installed_tag}  ${DIM}${desc}${RESET}  ${ACCENT}v${version}${RESET}"
    names[${#names[@]}]="$name"
    i=$((i + 1))
  done
  echo ""

  if [[ "$match_count" -eq 1 ]]; then
    local single_name="${names[0]}"
    if [[ -d "${SKILLS_DIR}/${single_name}" ]]; then
      printf '%b' "  Uninstall ${BOLD}${single_name}${RESET}? (y/n) "
      local answer=""
      read -rsn1 answer
      echo ""
      if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        skill_remove "$single_name"
      fi
      return 0
    fi
    printf '%b' "  Install ${BOLD}${single_name}${RESET}? (y/n) "
    local answer=""
    read -rsn1 answer
    echo ""
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
      skill_marketplace_install "$single_name"
    fi
  else
    # Build checklist items with descriptions
    local items=()
    i=0
    while [[ "$i" -lt "$match_count" ]]; do
      local item_name
      item_name=$(printf '%s' "$matches" | jq -r ".[$i].name")
      items[${#items[@]}]="$item_name"
      i=$((i + 1))
    done

    checklist_select --none "Select skills to install or uninstall" "${items[@]}"

    if [[ -n "$CHECKLIST_RESULT" ]]; then
      local IFS=$'\n'
      local selected
      for selected in $CHECKLIST_RESULT; do
        if [[ -d "${SKILLS_DIR}/${selected}" ]]; then
          printf '%b' "  Uninstall ${BOLD}${selected}${RESET}? (y/n) "
          local _uans=""
          read -rsn1 _uans
          echo ""
          if [[ "$_uans" == "y" || "$_uans" == "Y" ]]; then
            skill_remove "$selected"
          fi
        else
          skill_marketplace_install "$selected"
        fi
      done
    fi
  fi
}

_marketplace_browse() {
  local registry="$1"

  local skill_count
  skill_count=$(jq '.skills | length' "$registry")

  if [[ "$skill_count" -eq 0 ]]; then
    echo ""
    info "No skills available in the registry"
    echo ""
    return 0
  fi

  echo ""
  printf '%b\n' "  ${BOLD}Skill Marketplace${RESET}"
  echo ""

  local i=0
  local items=()
  while [[ "$i" -lt "$skill_count" ]]; do
    local name desc version installed_tag=""
    name=$(jq -r ".skills[$i].name" "$registry")
    desc=$(jq -r ".skills[$i].description // \"\"" "$registry")
    version=$(jq -r ".skills[$i].version // \"0.0.0\"" "$registry")

    if [[ -d "${SKILLS_DIR}/${name}" ]]; then
      installed_tag=" (installed)"
    fi

    printf '%b\n' "  ${ACCENT}${name}${RESET}${installed_tag}  ${DIM}${desc}${RESET}  ${DIM}v${version}${RESET}"
    items[${#items[@]}]="$name"
    i=$((i + 1))
  done
  echo ""

  checklist_select --none "Select skills to install or uninstall" "${items[@]}"

  if [[ -n "$CHECKLIST_RESULT" ]]; then
    local IFS=$'\n'
    local selected
    for selected in $CHECKLIST_RESULT; do
      if [[ -d "${SKILLS_DIR}/${selected}" ]]; then
        printf '%b' "  Uninstall ${BOLD}${selected}${RESET}? (y/n) "
        local _uans=""
        read -rsn1 _uans
        echo ""
        if [[ "$_uans" == "y" || "$_uans" == "Y" ]]; then
          skill_remove "$selected"
        fi
      else
        skill_marketplace_install "$selected"
      fi
    done
  fi
}

skill_marketplace_install() {
  local name="$1"
  local tmp_dir
  tmp_dir=$(mktemp -d)

  start_spinner "Installing ${name}..."
  git clone --quiet --depth 1 https://github.com/ImJustRicky/muster-skills.git "$tmp_dir" 2>/dev/null
  stop_spinner

  if [[ -d "${tmp_dir}/${name}" && -f "${tmp_dir}/${name}/skill.json" ]]; then
    skill_add "${tmp_dir}/${name}"
    # Refresh registry cache from the cloned repo
    if [[ -f "${tmp_dir}/registry.json" ]]; then
      mkdir -p "${HOME}/.muster"
      cp "${tmp_dir}/registry.json" "${HOME}/.muster/.registry_cache.json"
    fi
  else
    err "Skill '${name}' not found in registry"
  fi

  rm -rf "$tmp_dir"
}

# Enable a skill to auto-run on deploy/rollback hooks
skill_enable() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    err "Usage: muster skill enable <name>"
    return 1
  fi
  if [[ ! -d "${SKILLS_DIR}/${name}" ]]; then
    err "Skill '${name}' not found"
    return 1
  fi
  touch "${SKILLS_DIR}/${name}/.enabled"
  ok "Skill '${name}' enabled — will auto-run on deploy/rollback hooks"
}

# Disable a skill from auto-running on hooks
skill_disable() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    err "Usage: muster skill disable <name>"
    return 1
  fi
  if [[ ! -d "${SKILLS_DIR}/${name}" ]]; then
    err "Skill '${name}' not found"
    return 1
  fi
  rm -f "${SKILLS_DIR}/${name}/.enabled"
  ok "Skill '${name}' disabled — will not auto-run on hooks"
}
