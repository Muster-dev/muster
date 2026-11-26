#!/usr/bin/env bash
# muster/lib/commands/setup_scan.sh — `muster setup --scan --dry-run [--json]`
#
# Runs the same scanner as `muster setup --scan` (files, compose, k8s
# manifests, live cluster for k8s, dev start commands) and reports what
# setup would configure, without writing anything. Frontends use the JSON
# form for onboarding previews. Shape: docs/ENGINE-API.md.
# Sourced by setup.sh (scanner.sh + templates.sh already loaded).

source "$MUSTER_ROOT/lib/core/engine.sh"

# "type|endpoint|port" health tuple → JSON object
_setup_scan_health_json() {
  local h="$1"
  if [[ -z "$h" ]]; then
    printf '{"enabled":false}'
    return 0
  fi
  local t="${h%%|*}" rest="${h#*|}"
  local ep="${rest%%|*}" port="${rest#*|}"
  case "$t" in
    http)
      [[ -z "$ep" ]] && ep="/health"
      [[ "$port" =~ ^[0-9]+$ ]] || port=8080
      printf '{"type":"http","endpoint":%s,"port":%s,"timeout":10,"enabled":true}' "$(_json_str "$ep")" "$port"
      ;;
    tcp)
      if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then
        printf '{"type":"tcp","port":%s,"timeout":10,"enabled":true}' "$port"
      else
        printf '{"enabled":false}'
      fi
      ;;
    command)
      if [[ -n "$ep" ]]; then
        printf '{"type":"command","command":%s,"timeout":10,"enabled":true}' "$(_json_str "$ep")"
      else
        printf '{"enabled":false}'
      fi
      ;;
    *) printf '{"enabled":false}' ;;
  esac
}

# Source files the scanner tied to a service, one per line
_setup_scan_sources() {
  local svc="$1" key="$2" i=0 entry e_svc rest e_type e_path
  while (( i < ${#_SCAN_PATHS[@]} )); do
    entry="${_SCAN_PATHS[$i]}"
    e_svc="${entry%%|*}"; rest="${entry#*|}"
    e_type="${rest%%|*}"; e_path="${rest#*|}"
    i=$(( i + 1 ))
    [[ -z "$e_path" ]] && continue
    if [[ "$e_svc" == "$svc" || "$e_svc" == "$key" || "$e_type" == "compose_file" ]]; then
      printf '%s\n' "$e_path"
    fi
  done | awk '!seen[$0]++'
}

# Args: path stack namespace name force json
_setup_scan_preview() {
  local flag_path="$1" flag_stack="$2" flag_namespace="$3" flag_name="$4" flag_force="$5" json="$6"

  if [[ "$json" == "true" ]]; then
    source "$MUSTER_ROOT/lib/core/auth.sh"
    _json_auth_gate "read" || return 1
  fi

  local project_path
  if ! project_path="$(cd "${flag_path:-.}" 2>/dev/null && pwd)"; then
    if [[ "$json" == "true" ]]; then
      _json_error "bad_path" "Path does not exist: ${flag_path}"
    else
      err "Path does not exist: ${flag_path}"
    fi
    return 1
  fi
  case "$flag_stack" in
    ""|k8s|compose|docker|bare|dev) ;;
    *)
      if [[ "$json" == "true" ]]; then
        _json_error "bad_stack" "Invalid stack: ${flag_stack} (must be k8s, compose, docker, bare, or dev)"
      else
        err "Invalid stack: ${flag_stack} (must be k8s, compose, docker, bare, or dev)"
      fi
      return 1
      ;;
  esac

  # Scanner output (warnings about clusters etc.) is collected, not printed
  local scan_out
  scan_out=$(mktemp "${TMPDIR:-/tmp}/muster-scan.XXXXXX") || return 1
  scan_project "$project_path" > "$scan_out" 2>&1

  local stack="${flag_stack:-$_SCAN_STACK}"
  local ns="" cluster_scanned=false
  if [[ "$stack" == "k8s" ]]; then
    ns=$(_scan_resolve_namespace "${flag_namespace:-}" "$project_path" 2>>"$scan_out")
    scan_k8s_cluster "$ns" >> "$scan_out" 2>&1
    (( ${#_SCAN_K8S_NAMES[@]} > 0 )) && cluster_scanned=true
    [[ -z "$ns" ]] && ns="${_SCAN_K8S_NS:-default}"
  fi
  [[ "$stack" == "dev" ]] && _scan_detect_dev_cmds "$project_path"
  [[ -z "$stack" ]] && stack="bare"

  # Warnings: scanner messages + what setup itself would complain about
  local warnings=()
  local _w
  while IFS= read -r _w; do
    _w=$(printf '%s' "$_w" | sed "s/$(printf '\033')\\[[0-9;]*m//g; s/^[[:space:]]*[!x*i][[:space:]]*//")
    [[ -n "$_w" ]] && warnings[${#warnings[@]}]="$_w"
  done < "$scan_out"
  rm -f "$scan_out"
  if [[ ( -f "${project_path}/muster.json" || -f "${project_path}/deploy.json" ) && "$flag_force" != "true" ]]; then
    warnings[${#warnings[@]}]="Config already exists — setup will need --force to overwrite it"
  fi
  if (( ${#_SCAN_SERVICES[@]} == 0 )); then
    warnings[${#warnings[@]}]="No services detected — pass --services to setup"
  fi

  _setup_sort_services ${_SCAN_SERVICES[@]+"${_SCAN_SERVICES[@]}"}
  local ordered=()
  [[ ${#_SETUP_SORTED_SERVICES[@]} -gt 0 ]] && ordered=("${_SETUP_SORTED_SERVICES[@]}")

  local project_name="${flag_name:-$(basename "$project_path")}"

  # ── Services ──
  local svc_json="" order_json="" human=()
  local svc key name role kind image h health tmpl_dir tmpl skip port sources extra
  for svc in ${ordered[@]+"${ordered[@]}"}; do
    key=$(_svc_to_key "$svc")
    name=$(_friendly_name "$key")
    role="app"; kind="app"; image=""
    if _is_infra_service "$svc"; then
      role="infra"; kind="infra"
      # Compose services run the image from the compose file; elsewhere the
      # infra template pulls this default image
      [[ "$stack" != "compose" ]] && image=$(_infra_default_image "$svc")
    elif [[ -n "$(scan_get_path "$svc" "dockerfile")" && "$stack" != "bare" && "$stack" != "dev" ]]; then
      kind="build"
    fi

    h=$(scan_infer_health "$svc")
    [[ -z "$h" && "$key" != "$svc" ]] && h=$(scan_infer_health "$key")
    health=$(_setup_scan_health_json "$h")

    tmpl_dir="${MUSTER_ROOT}/templates/hooks/${stack}"
    tmpl="$stack"
    if [[ "$role" == "infra" && -d "${tmpl_dir}/infra" ]]; then
      tmpl="${stack}/infra"
    elif [[ ! -d "$tmpl_dir" ]]; then
      tmpl="stub"
    fi

    skip=false
    if [[ "$stack" == "k8s" && "$cluster_scanned" == "true" ]] && ! scan_has_k8s_deployment "$svc"; then
      skip=true
    fi

    port=$(scan_get_port "$svc")
    [[ -z "$port" && "$role" == "infra" ]] && port=$(_scan_infra_default_port "$svc")
    sources=$(_setup_scan_sources "$svc" "$key" | _json_lines_array)

    extra=""
    if [[ "$stack" == "k8s" ]]; then
      extra=",\"k8s\":{\"deployment\":$(_json_str "$(scan_get_k8s_name "$svc")"),\"namespace\":$(_json_str "$ns")}"
    elif [[ "$stack" == "dev" ]]; then
      extra=",\"dev\":{\"start_cmd\":$(_json_str_or_null "$(scan_get_dev_cmd "$svc")"),\"port\":$(_json_int "$(scan_get_dev_port "$svc")")}"
    fi

    [[ -n "$svc_json" ]] && svc_json="${svc_json},"
    svc_json="${svc_json}{\"key\":$(_json_str "$key"),\"name\":$(_json_str "$name"),\"detected_as\":$(_json_str "$svc"),\"role\":\"${role}\",\"kind\":\"${kind}\",\"image\":$(_json_str_or_null "$image"),\"port\":$(_json_int "$port"),\"health\":${health},\"credentials\":{\"mode\":\"off\"},\"skip_deploy\":${skip},\"hooks_template\":$(_json_str "$tmpl"),\"source_files\":${sources}${extra}}"
    [[ -n "$order_json" ]] && order_json="${order_json},"
    order_json="${order_json}$(_json_str "$key")"
    human[${#human[@]}]="${key}|${role}|$(_setup_format_health "$h")|${tmpl}|${skip}"
  done

  local found_json="" i=0 entry
  while (( i < ${#_SCAN_FILES[@]} )); do
    entry="${_SCAN_FILES[$i]}"
    [[ -n "$found_json" ]] && found_json="${found_json},"
    found_json="${found_json}{\"file\":$(_json_str "${entry%%|*}"),\"description\":$(_json_str "${entry#*|}")}"
    i=$(( i + 1 ))
  done

  local warn_json=""
  for _w in ${warnings[@]+"${warnings[@]}"}; do
    [[ -n "$warn_json" ]] && warn_json="${warn_json},"
    warn_json="${warn_json}$(_json_str "$_w")"
  done

  if [[ "$json" == "true" ]]; then
    printf '{"dry_run":true,"project":%s,"root":%s,"stack":%s,"detected_stack":%s,"namespace":%s,"cluster_scanned":%s,"found":[%s],"services":[%s],"deploy_order":[%s],"warnings":[%s]}\n' \
      "$(_json_str "$project_name")" "$(_json_str "$project_path")" "$(_json_str "$stack")" \
      "$(_json_str_or_null "$_SCAN_STACK")" "$(_json_str_or_null "$ns")" "$cluster_scanned" \
      "$found_json" "$svc_json" "$order_json" "$warn_json"
    return 0
  fi

  echo ""
  printf '  %b%bSetup preview%b %b(dry run — nothing written)%b\n' "$BOLD" "$ACCENT_BRIGHT" "$RESET" "$DIM" "$RESET"
  echo ""
  printf '  %bProject:%b %s\n' "$DIM" "$RESET" "$project_name"
  printf '  %bStack:%b   %s\n' "$DIM" "$RESET" "$(_setup_stack_label "$stack")"
  echo ""
  local e k r hh t sk
  for e in ${human[@]+"${human[@]}"}; do
    IFS='|' read -r k r hh t sk <<< "$e"
    printf '  %-16s %b%-6s%b health: %-18s hooks: %s%s\n' "$k" "$DIM" "$r" "$RESET" "$hh" "$t" \
      "$( [[ "$sk" == "true" ]] && printf ' (skip_deploy)')"
  done
  echo ""
  for _w in ${warnings[@]+"${warnings[@]}"}; do
    warn "$_w"
  done
  printf '  %bRun without --dry-run to write muster.json and hooks.%b\n' "$DIM" "$RESET"
  echo ""
}
