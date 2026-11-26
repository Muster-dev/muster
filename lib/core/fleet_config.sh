#!/usr/bin/env bash
# muster/lib/core/fleet_config.sh — Directory-based fleet config API
# Structure: ~/.muster/fleets/<fleet>/<group>/<project>/project.json

FLEETS_BASE_DIR="$HOME/.muster/fleets"

# ── Fleet functions ──

# Ensure fleets base dir exists; auto-migrate old configs if present
fleets_ensure_dir() {
  if [[ ! -d "$FLEETS_BASE_DIR" ]]; then
    mkdir -p "$FLEETS_BASE_DIR"
    chmod 700 "$FLEETS_BASE_DIR"
    # Auto-migrate if old config exists
    if [[ -f "$HOME/.muster/groups.json" ]] || [[ -f "$HOME/.muster/remotes.json" ]]; then
      fleet_migrate
    fi
  fi
}

# List fleet names (dirs containing fleet.json)
fleets_list() {
  fleets_ensure_dir
  local d
  for d in "$FLEETS_BASE_DIR"/*/; do
    [[ -f "${d}fleet.json" ]] && basename "$d"
  done
}

# Return fleet directory path
fleet_dir() {
  local name="$1"
  printf '%s/%s' "$FLEETS_BASE_DIR" "$name"
}

# Vars set by fleet_cfg_load:
_FL_NAME="" _FL_STRATEGY="" _FL_TRANSPORT_TYPE="" _FL_TRANSPORT_PORT=""

# Read fleet.json into _FL_* vars
fleet_cfg_load() {
  local name="$1"
  local cfg
  cfg="$(fleet_dir "$name")/fleet.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi

  local data
  data=$(jq -r '"\(.name // "")\n\(.deploy_strategy // "sequential")\n\(.transport_defaults.type // "ssh")\n\(.transport_defaults.port // 22)"' "$cfg" 2>/dev/null)

  local i=0
  while IFS= read -r _line; do
    case $i in
      0) _FL_NAME="$_line" ;;
      1) _FL_STRATEGY="$_line" ;;
      2) _FL_TRANSPORT_TYPE="$_line" ;;
      3) _FL_TRANSPORT_PORT="$_line" ;;
    esac
    i=$(( i + 1 ))
  done <<< "$data"

  [[ -z "$_FL_STRATEGY" || "$_FL_STRATEGY" == "null" ]] && _FL_STRATEGY="sequential"
  [[ -z "$_FL_TRANSPORT_TYPE" || "$_FL_TRANSPORT_TYPE" == "null" ]] && _FL_TRANSPORT_TYPE="ssh"
  [[ -z "$_FL_TRANSPORT_PORT" || "$_FL_TRANSPORT_PORT" == "null" ]] && _FL_TRANSPORT_PORT="22"
}

# Create fleet directory + fleet.json
fleet_cfg_create() {
  local name="$1"
  local display="${2:-$1}"
  local strategy="${3:-sequential}"

  # Validate name
  case "$name" in
    *[^a-zA-Z0-9_-]*)
      err "Fleet name must be alphanumeric, hyphens, or underscores"
      return 1
      ;;
  esac

  local fdir
  fdir="$(fleet_dir "$name")"
  if [[ -f "${fdir}/fleet.json" ]]; then
    err "Fleet '${name}' already exists"
    return 1
  fi

  mkdir -p "$fdir"
  jq -n --arg n "$display" --arg s "$strategy" \
    '{name: $n, deploy_strategy: $s, transport_defaults: {type: "ssh", port: 22}}' \
    > "${fdir}/fleet.json"
}

# Delete fleet directory (with guard)
fleet_cfg_delete() {
  local name="$1"
  local fdir
  fdir="$(fleet_dir "$name")"
  if [[ ! -d "$fdir" ]]; then
    err "Fleet '${name}' not found"
    return 1
  fi
  rm -rf "$fdir"
}

# Atomic jq update on fleet.json
fleet_cfg_update() {
  local name="$1" jq_expr="$2"
  local cfg
  cfg="$(fleet_dir "$name")/fleet.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi
  local tmp="${cfg}.tmp"
  jq "$jq_expr" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# ── Group functions ──

# List group names in a fleet (dirs containing group.json)
fleet_cfg_groups() {
  local fleet="$1"
  local fdir
  fdir="$(fleet_dir "$fleet")"
  local d
  for d in "$fdir"/*/; do
    [[ -f "${d}group.json" ]] && basename "$d"
  done
}

# Return group directory path
fleet_cfg_group_dir() {
  local fleet="$1" group="$2"
  printf '%s/%s/%s' "$FLEETS_BASE_DIR" "$fleet" "$group"
}

# Vars set by fleet_cfg_group_load:
_FG_NAME="" _FG_DEPLOY_ORDER=""

# Read group.json into _FG_* vars
fleet_cfg_group_load() {
  local fleet="$1" group="$2"
  local cfg
  cfg="$(fleet_cfg_group_dir "$fleet" "$group")/group.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi

  _FG_NAME=$(jq -r '.name // ""' "$cfg" 2>/dev/null)
  # deploy_order as newline-separated list
  _FG_DEPLOY_ORDER=$(jq -r '.deploy_order[]' "$cfg" 2>/dev/null)
}

# Create group directory + group.json
fleet_cfg_group_create() {
  local fleet="$1" group="$2"
  local display="${3:-$2}"

  # Validate name
  case "$group" in
    *[^a-zA-Z0-9_-]*)
      err "Group name must be alphanumeric, hyphens, or underscores"
      return 1
      ;;
  esac

  local gdir
  gdir="$(fleet_cfg_group_dir "$fleet" "$group")"
  if [[ -f "${gdir}/group.json" ]]; then
    err "Group '${group}' already exists in fleet '${fleet}'"
    return 1
  fi

  mkdir -p "$gdir"
  jq -n --arg n "$display" '{name: $n, deploy_order: []}' > "${gdir}/group.json"
}

# Delete group directory
fleet_cfg_group_delete() {
  local fleet="$1" group="$2"
  local gdir
  gdir="$(fleet_cfg_group_dir "$fleet" "$group")"
  if [[ ! -d "$gdir" ]]; then
    err "Group '${group}' not found in fleet '${fleet}'"
    return 1
  fi
  rm -rf "$gdir"
}

# Update group.json
fleet_cfg_group_update() {
  local fleet="$1" group="$2" jq_expr="$3"
  local cfg
  cfg="$(fleet_cfg_group_dir "$fleet" "$group")/group.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi
  local tmp="${cfg}.tmp"
  jq "$jq_expr" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# List project names in a group (dirs containing project.json)
fleet_cfg_group_projects() {
  local fleet="$1" group="$2"
  local gdir
  gdir="$(fleet_cfg_group_dir "$fleet" "$group")"
  local d
  for d in "$gdir"/*/; do
    [[ -f "${d}project.json" ]] && basename "$d"
  done
}

# ── Project functions ──

# Return project directory path
fleet_cfg_project_dir() {
  local fleet="$1" group="$2" project="$3"
  printf '%s/%s/%s/%s' "$FLEETS_BASE_DIR" "$fleet" "$group" "$project"
}

# Vars set by fleet_cfg_project_load:
_FP_NAME="" _FP_HOST="" _FP_USER="" _FP_PORT="" _FP_TRANSPORT=""
_FP_IDENTITY="" _FP_REMOTE_PATH="" _FP_HOOK_MODE="" _FP_MODE="" _FP_STACK=""
_FP_SERVICES="" _FP_DEPLOY_ORDER="" _FP_PATH=""
_FP_FLEET="" _FP_GROUP="" _FP_PROJECT=""

# Read project.json into _FP_* vars
fleet_cfg_project_load() {
  local fleet="$1" group="$2" project="$3"
  local cfg
  cfg="$(fleet_cfg_project_dir "$fleet" "$group" "$project")/project.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi

  _FP_FLEET="$fleet"
  _FP_GROUP="$group"
  _FP_PROJECT="$project"
  _FP_MODE=""

  local data
  data=$(jq -r '"\(.name // "")\n\(.machine.host // "")\n\(.machine.user // "")\n\(.machine.port // 22)\n\(.machine.transport // "ssh")\n\(.machine.identity_file // "")\n\(.remote_path // "")\n\(.hook_mode // "manual")\n\(.stack // "")\n\(.path // "")\n\(.mode // "")"' "$cfg" 2>/dev/null)

  local i=0
  while IFS= read -r _line; do
    case $i in
      0) _FP_NAME="$_line" ;;
      1) _FP_HOST="$_line" ;;
      2) _FP_USER="$_line" ;;
      3) _FP_PORT="$_line" ;;
      4) _FP_TRANSPORT="$_line" ;;
      5) _FP_IDENTITY="$_line" ;;
      6) _FP_REMOTE_PATH="$_line" ;;
      7) _FP_HOOK_MODE="$_line" ;;
      8) _FP_STACK="$_line" ;;
      9) _FP_PATH="$_line" ;;
      10) _FP_MODE="$_line" ;;
    esac
    i=$(( i + 1 ))
  done <<< "$data"

  # Defaults / null cleanup
  [[ -z "$_FP_PORT" || "$_FP_PORT" == "null" ]] && _FP_PORT="22"
  [[ -z "$_FP_TRANSPORT" || "$_FP_TRANSPORT" == "null" ]] && _FP_TRANSPORT="ssh"
  [[ "$_FP_IDENTITY" == "null" ]] && _FP_IDENTITY=""
  [[ "$_FP_REMOTE_PATH" == "null" ]] && _FP_REMOTE_PATH=""
  [[ -z "$_FP_HOOK_MODE" || "$_FP_HOOK_MODE" == "null" ]] && _FP_HOOK_MODE="manual"
  [[ "$_FP_MODE" == "null" ]] && _FP_MODE=""
  [[ "$_FP_STACK" == "null" ]] && _FP_STACK=""
  [[ "$_FP_PATH" == "null" ]] && _FP_PATH=""

  # Services and deploy_order as newline-separated lists
  _FP_SERVICES=$(jq -r '.services[]' "$cfg" 2>/dev/null)
  _FP_DEPLOY_ORDER=$(jq -r '.deploy_order[]' "$cfg" 2>/dev/null)
}

# Create project directory + project.json
fleet_cfg_project_create() {
  local fleet="$1" group="$2" project="$3" json_str="$4"

  # Validate name
  case "$project" in
    *[^a-zA-Z0-9_-]*)
      err "Project name must be alphanumeric, hyphens, or underscores"
      return 1
      ;;
  esac

  local pdir
  pdir="$(fleet_cfg_project_dir "$fleet" "$group" "$project")"
  if [[ -f "${pdir}/project.json" ]]; then
    err "Project '${project}' already exists in ${fleet}/${group}"
    return 1
  fi

  mkdir -p "$pdir"
  printf '%s\n' "$json_str" > "${pdir}/project.json"

  # Add to group deploy_order if not already there
  local gcfg
  gcfg="$(fleet_cfg_group_dir "$fleet" "$group")/group.json"
  if [[ -f "$gcfg" ]]; then
    local tmp="${gcfg}.tmp"
    jq --arg p "$project" \
      'if (.deploy_order | index($p)) == null then .deploy_order += [$p] else . end' \
      "$gcfg" > "$tmp" && mv "$tmp" "$gcfg"
  fi
}

# Atomic jq update on project.json
fleet_cfg_project_update() {
  local fleet="$1" group="$2" project="$3" jq_expr="$4"
  local cfg
  cfg="$(fleet_cfg_project_dir "$fleet" "$group" "$project")/project.json"
  if [[ ! -f "$cfg" ]]; then
    return 1
  fi
  local tmp="${cfg}.tmp"
  jq "$jq_expr" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# Delete project directory
fleet_cfg_project_delete() {
  local fleet="$1" group="$2" project="$3"
  local pdir
  pdir="$(fleet_cfg_project_dir "$fleet" "$group" "$project")"
  if [[ ! -d "$pdir" ]]; then
    err "Project '${project}' not found in ${fleet}/${group}"
    return 1
  fi
  rm -rf "$pdir"

  # Remove from group deploy_order
  local gcfg
  gcfg="$(fleet_cfg_group_dir "$fleet" "$group")/group.json"
  if [[ -f "$gcfg" ]]; then
    local tmp="${gcfg}.tmp"
    jq --arg p "$project" '.deploy_order = [.deploy_order[] | select(. != $p)]' \
      "$gcfg" > "$tmp" && mv "$tmp" "$gcfg"
  fi
}

# Return hooks directory path for a project
fleet_cfg_project_hooks_dir() {
  local fleet="$1" group="$2" project="$3"
  printf '%s/%s/%s/%s/hooks' "$FLEETS_BASE_DIR" "$fleet" "$group" "$project"
}

# ── Finder helpers ──

# Walk all fleets/groups to find a project by name
# Sets _FP_FLEET, _FP_GROUP, _FP_PROJECT and loads the project
fleet_cfg_find_project() {
  local target="$1"
  fleets_ensure_dir

  local fleet group project
  for fleet in $(fleets_list); do
    for group in $(fleet_cfg_groups "$fleet"); do
      for project in $(fleet_cfg_group_projects "$fleet" "$group"); do
        if [[ "$project" == "$target" ]]; then
          fleet_cfg_project_load "$fleet" "$group" "$project"
          return 0
        fi
      done
    done
  done
  return 1
}

# Return project name at index within a group's deploy_order
_fleet_cfg_project_at_index() {
  local fleet="$1" group="$2" index="$3"
  fleet_cfg_group_load "$fleet" "$group"
  local i=0
  local proj
  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    if (( i == index )); then
      printf '%s' "$proj"
      return 0
    fi
    i=$(( i + 1 ))
  done <<< "$_FG_DEPLOY_ORDER"
  return 1
}

# Count total projects across all groups in a fleet
fleet_cfg_project_count() {
  local fleet="$1"
  local count=0
  local group
  for group in $(fleet_cfg_groups "$fleet"); do
    local project
    for project in $(fleet_cfg_group_projects "$fleet" "$group"); do
      count=$(( count + 1 ))
    done
  done
  printf '%d' "$count"
}

# Check if any fleet exists
fleet_cfg_has_any() {
  fleets_ensure_dir
  local d
  for d in "$FLEETS_BASE_DIR"/*/; do
    [[ -f "${d}fleet.json" ]] && return 0
  done
  return 1
}

# ── Migration ──

# Auto-migrate old config to new directory structure
fleet_migrate() {
  local _migrated=0

  # Migrate groups.json → each group becomes a fleet with "default" group
  if [[ -f "$HOME/.muster/groups.json" ]]; then
    local _groups
    _groups=$(jq -r '.groups | keys[]' "$HOME/.muster/groups.json" 2>/dev/null)

    local _gname
    while IFS= read -r _gname; do
      [[ -z "$_gname" ]] && continue

      # Create fleet with the group name
      local _fleet_name="$_gname"
      local _fdir="${FLEETS_BASE_DIR}/${_fleet_name}"
      mkdir -p "$_fdir"

      # fleet.json
      local _display
      _display=$(jq -r --arg g "$_gname" '.groups[$g].name // $g' "$HOME/.muster/groups.json" 2>/dev/null)
      jq -n --arg n "$_display" \
        '{name: $n, deploy_strategy: "sequential", transport_defaults: {type: "ssh", port: 22}}' \
        > "${_fdir}/fleet.json"

      # Create default group
      local _gdir="${_fdir}/default"
      mkdir -p "$_gdir"
      jq -n '{name: "default", deploy_order: []}' > "${_gdir}/group.json"

      # Migrate each project in the group
      local _proj_count
      _proj_count=$(jq -r --arg g "$_gname" '.groups[$g].projects | length' "$HOME/.muster/groups.json" 2>/dev/null)
      [[ -z "$_proj_count" || "$_proj_count" == "null" ]] && _proj_count=0

      local _pi=0
      while (( _pi < _proj_count )); do
        local _ptype _phost _puser _pport _ppath _pdir_name _pcloud _phook_mode
        _ptype=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
          '.groups[$g].projects[$i].type // "remote"' "$HOME/.muster/groups.json" 2>/dev/null)

        if [[ "$_ptype" == "local" ]]; then
          _ppath=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].path // ""' "$HOME/.muster/groups.json" 2>/dev/null)
          _pdir_name=$(basename "$_ppath")

          local _proj_dir="${_gdir}/${_pdir_name}"
          mkdir -p "$_proj_dir"
          jq -n --arg n "$_pdir_name" --arg p "$_ppath" \
            '{name: $n, machine: {transport: "local"}, path: $p, hook_mode: "local"}' \
            > "${_proj_dir}/project.json"

          # Add to group deploy_order
          local _gtmp="${_gdir}/group.json.tmp"
          jq --arg p "$_pdir_name" '.deploy_order += [$p]' "${_gdir}/group.json" > "$_gtmp" && mv "$_gtmp" "${_gdir}/group.json"
        else
          _phost=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].host // ""' "$HOME/.muster/groups.json" 2>/dev/null)
          _puser=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].user // ""' "$HOME/.muster/groups.json" 2>/dev/null)
          _pport=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].port // 22' "$HOME/.muster/groups.json" 2>/dev/null)
          _pcloud=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].cloud // false' "$HOME/.muster/groups.json" 2>/dev/null)
          _phook_mode=$(jq -r --arg g "$_gname" --argjson i "$_pi" \
            '.groups[$g].projects[$i].hook_mode // "manual"' "$HOME/.muster/groups.json" 2>/dev/null)

          # Use host as dir name (sanitize dots/colons)
          _pdir_name=$(printf '%s' "$_phost" | tr '.:' '-')

          local _proj_dir="${_gdir}/${_pdir_name}"
          mkdir -p "$_proj_dir"

          local _transport="ssh"
          [[ "$_pcloud" == "true" ]] && _transport="cloud"

          jq -n \
            --arg n "$_pdir_name" \
            --arg host "$_phost" \
            --arg user "$_puser" \
            --argjson port "$_pport" \
            --arg transport "$_transport" \
            --arg hook_mode "$_phook_mode" \
            '{name: $n, machine: {host: $host, user: $user, port: $port, transport: $transport}, hook_mode: $hook_mode}' \
            > "${_proj_dir}/project.json"

          # Add to group deploy_order
          local _gtmp="${_gdir}/group.json.tmp"
          jq --arg p "$_pdir_name" '.deploy_order += [$p]' "${_gdir}/group.json" > "$_gtmp" && mv "$_gtmp" "${_gdir}/group.json"
        fi

        _pi=$(( _pi + 1 ))
      done

      _migrated=1
    done <<< "$_groups"

    mv "$HOME/.muster/groups.json" "$HOME/.muster/groups.json.bak"
  fi

  # Migrate remotes.json → merge into project configs
  if [[ -f "$HOME/.muster/remotes.json" ]]; then
    local _machines
    _machines=$(jq -r '.machines | keys[]' "$HOME/.muster/remotes.json" 2>/dev/null)

    if [[ -n "$_machines" ]]; then
      # If no fleet exists yet from groups migration, create a "default" fleet
      if [[ ! -d "${FLEETS_BASE_DIR}/default" ]]; then
        mkdir -p "${FLEETS_BASE_DIR}/default/default"
        jq -n '{name: "default", deploy_strategy: "sequential", transport_defaults: {type: "ssh", port: 22}}' \
          > "${FLEETS_BASE_DIR}/default/fleet.json"
        jq -n '{name: "default", deploy_order: []}' \
          > "${FLEETS_BASE_DIR}/default/default/group.json"
      fi

      local _mname
      while IFS= read -r _mname; do
        [[ -z "$_mname" ]] && continue
        local _mhost _muser _mport _midentity _mproject_dir _mtransport _mhook_mode _mmode
        _mhost=$(jq -r --arg n "$_mname" '.machines[$n].host // ""' "$HOME/.muster/remotes.json" 2>/dev/null)
        _muser=$(jq -r --arg n "$_mname" '.machines[$n].user // ""' "$HOME/.muster/remotes.json" 2>/dev/null)
        _mport=$(jq -r --arg n "$_mname" '.machines[$n].port // 22' "$HOME/.muster/remotes.json" 2>/dev/null)
        _midentity=$(jq -r --arg n "$_mname" '.machines[$n].identity_file // ""' "$HOME/.muster/remotes.json" 2>/dev/null)
        _mproject_dir=$(jq -r --arg n "$_mname" '.machines[$n].project_dir // ""' "$HOME/.muster/remotes.json" 2>/dev/null)
        _mtransport=$(jq -r --arg n "$_mname" '.machines[$n].transport // "ssh"' "$HOME/.muster/remotes.json" 2>/dev/null)
        _mhook_mode=$(jq -r --arg n "$_mname" '.machines[$n].hook_mode // "manual"' "$HOME/.muster/remotes.json" 2>/dev/null)
        _mmode=$(jq -r --arg n "$_mname" '.machines[$n].mode // ""' "$HOME/.muster/remotes.json" 2>/dev/null)

        [[ "$_midentity" == "null" ]] && _midentity=""
        [[ "$_mproject_dir" == "null" ]] && _mproject_dir=""
        [[ "$_mtransport" == "null" ]] && _mtransport="ssh"
        [[ "$_mhook_mode" == "null" ]] && _mhook_mode="manual"
        [[ "$_mmode" == "null" ]] && _mmode=""

        # Check if this project already exists from groups migration
        local _proj_dir="${FLEETS_BASE_DIR}/default/default/${_mname}"
        if [[ -f "${_proj_dir}/project.json" ]]; then
          # Merge identity_file and project_dir if missing
          if [[ -n "$_midentity" ]]; then
            local _tmp="${_proj_dir}/project.json.tmp"
            jq --arg id "$_midentity" '.machine.identity_file = $id' \
              "${_proj_dir}/project.json" > "$_tmp" && mv "$_tmp" "${_proj_dir}/project.json"
          fi
          if [[ -n "$_mproject_dir" ]]; then
            local _tmp="${_proj_dir}/project.json.tmp"
            jq --arg pd "$_mproject_dir" '.remote_path = $pd' \
              "${_proj_dir}/project.json" > "$_tmp" && mv "$_tmp" "${_proj_dir}/project.json"
          fi
          if [[ -n "$_mmode" ]]; then
            local _tmp="${_proj_dir}/project.json.tmp"
            jq --arg md "$_mmode" '.mode = $md' \
              "${_proj_dir}/project.json" > "$_tmp" && mv "$_tmp" "${_proj_dir}/project.json"
          fi
        else
          mkdir -p "$_proj_dir"
          jq -n \
            --arg n "$_mname" \
            --arg host "$_mhost" \
            --arg user "$_muser" \
            --argjson port "$_mport" \
            --arg transport "$_mtransport" \
            --arg identity "$_midentity" \
            --arg remote_path "$_mproject_dir" \
            --arg hook_mode "$_mhook_mode" \
            --arg mode "$_mmode" \
            '{name: $n, machine: ({host: $host, user: $user, port: $port, transport: $transport} +
              (if $identity != "" then {identity_file: $identity} else {} end)),
              hook_mode: $hook_mode} +
              (if $mode != "" then {mode: $mode} else {} end) +
              (if $remote_path != "" then {remote_path: $remote_path} else {} end)' \
            > "${_proj_dir}/project.json"

          # Add to group deploy_order
          local _gcfg="${FLEETS_BASE_DIR}/default/default/group.json"
          local _gtmp="${_gcfg}.tmp"
          jq --arg p "$_mname" \
            'if (.deploy_order | index($p)) == null then .deploy_order += [$p] else . end' \
            "$_gcfg" > "$_gtmp" && mv "$_gtmp" "$_gcfg"
        fi
      done <<< "$_machines"

      _migrated=1
    fi

    mv "$HOME/.muster/remotes.json" "$HOME/.muster/remotes.json.bak"
  fi

  # Migrate fleet-hooks if present
  if [[ -d "$HOME/.muster/fleet-hooks" ]]; then
    local _hdir
    for _hdir in "$HOME/.muster/fleet-hooks"/*/; do
      [[ ! -d "$_hdir" ]] && continue
      local _machine_name
      _machine_name=$(basename "$_hdir")

      # Find the project dir for this machine
      local _fleet _group _project
      for _fleet in $(fleets_list); do
        for _group in $(fleet_cfg_groups "$_fleet"); do
          for _project in $(fleet_cfg_group_projects "$_fleet" "$_group"); do
            if [[ "$_project" == "$_machine_name" ]]; then
              local _pdir
              _pdir="$(fleet_cfg_project_dir "$_fleet" "$_group" "$_project")"
              # Copy hooks
              if [[ ! -d "${_pdir}/hooks" ]]; then
                cp -R "$_hdir" "${_pdir}/hooks"
              fi
            fi
          done
        done
      done
    done

    mv "$HOME/.muster/fleet-hooks" "$HOME/.muster/fleet-hooks.bak"
    _migrated=1
  fi

  if [[ "$_migrated" -eq 1 ]]; then
    printf '%b\n' "  ${DIM}Migrated fleet config to ~/.muster/fleets/${RESET}" >&2
  fi
}
