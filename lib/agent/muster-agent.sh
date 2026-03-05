#!/usr/bin/env bash
# muster-agent — Lightweight fleet monitoring daemon
# Standalone script — no muster library dependencies.
# Runs on fleet targets to collect health, metrics, logs, and deploy events.
# Copyright 2026 Ricky Eipper. Licensed under Apache 2.0.
set -uo pipefail

AGENT_VERSION="0.5.55"

# ── Paths ──
_AGENT_BASE="${HOME}/.muster/agent"
_AGENT_CONFIG="${_AGENT_BASE}/agent.json"
_AGENT_PID_FILE="${_AGENT_BASE}/agent.pid"
_AGENT_LOCK_FILE="${_AGENT_BASE}/agent.lock"
_AGENT_HEALTH_DIR="${_AGENT_BASE}/health"
_AGENT_METRICS_DIR="${_AGENT_BASE}/metrics"
_AGENT_EVENTS_DIR="${_AGENT_BASE}/events"
_AGENT_LOGS_DIR="${_AGENT_BASE}/logs"
_AGENT_SIG_FILE="${_AGENT_BASE}/agent.sig"
_AGENT_PUBKEY_FILE="${_AGENT_BASE}/agent.pub.pem"
_AGENT_CONFIG_SIG="${_AGENT_BASE}/agent.json.sig"
_AGENT_FLEET_PUBKEY="${_AGENT_BASE}/fleet.pub"

# ── Config defaults ──
_AGENT_PROJECT_DIR=""
_AGENT_POLL_INTERVAL=30
_AGENT_METRICS_INTERVAL=60
_AGENT_LOGS_INTERVAL=60
_AGENT_LOG_TAIL_LINES=50
_AGENT_PUSH_ENABLED=false
_AGENT_PUSH_INTERVAL=300
_AGENT_PUSH_HOST=""
_AGENT_PUSH_USER=""
_AGENT_PUSH_PORT=22
_AGENT_PUSH_IDENTITY=""
_AGENT_PUSH_DIR=""
_AGENT_HEALTH_TIMEOUT=10

# ── Minimal logging ──
_agent_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
_agent_warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
_agent_err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
_agent_info() { printf '  \033[2m%s\033[0m\n' "$*"; }
_agent_log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${_AGENT_BASE}/daemon.log" 2>/dev/null; }

# ── Input validation ──

# Validate a string contains only safe characters (alphanum, ., -, _, /, @, :, ~)
_agent_validate_safe() {
  local val="$1" label="$2"
  if [[ "$val" =~ [^a-zA-Z0-9._/~@:-] ]]; then
    _agent_err "${label} contains unsafe characters: ${val}"
    return 1
  fi
  return 0
}

# Validate a value is a positive integer
_agent_validate_int() {
  local val="$1" label="$2"
  if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" == "0" ]]; then
    _agent_err "${label} must be a positive integer, got: ${val}"
    return 1
  fi
  return 0
}

# Escape a string for safe JSON interpolation (escape " and \)
_agent_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ── File permission checks ──

_agent_check_permissions() {
  local file="$1" label="$2"
  if [[ ! -f "$file" ]]; then
    return 0
  fi

  # Check owner is current user
  local file_owner
  if [[ "$(uname -s)" == "Darwin" ]]; then
    file_owner=$(stat -f '%u' "$file" 2>/dev/null)
  else
    file_owner=$(stat -c '%u' "$file" 2>/dev/null)
  fi
  local my_uid
  my_uid=$(id -u)
  if [[ -n "$file_owner" && "$file_owner" != "$my_uid" ]]; then
    _agent_err "${label} is not owned by current user"
    return 1
  fi

  # Check not world-writable
  local file_perms
  if [[ "$(uname -s)" == "Darwin" ]]; then
    file_perms=$(stat -f '%Lp' "$file" 2>/dev/null)
  else
    file_perms=$(stat -c '%a' "$file" 2>/dev/null)
  fi
  if [[ -n "$file_perms" ]]; then
    local world_w="${file_perms: -1}"
    if [[ "$world_w" =~ [2367] ]]; then
      _agent_err "${label} is world-writable (mode ${file_perms})"
      return 1
    fi
  fi

  return 0
}

# ── Signature verification ──

_agent_verify_signature() {
  local file="$1" sig_file="$2"

  # No pubkey = signing not configured, skip verification
  if [[ ! -f "$_AGENT_PUBKEY_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$sig_file" ]]; then
    _agent_err "Signature file missing: ${sig_file}"
    _agent_err "Agent files may have been tampered with"
    return 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    _agent_warn "openssl not found — cannot verify signatures"
    return 0
  fi

  # Decode base64 signature to temp file
  local tmp_sig
  tmp_sig=$(mktemp "${_AGENT_BASE}/.sig_verify.XXXXXX") || return 1

  base64 -d < "$sig_file" > "$tmp_sig" 2>/dev/null || {
    rm -f "$tmp_sig"
    _agent_err "Invalid signature format in ${sig_file}"
    return 1
  }

  local rc=0
  openssl pkeyutl -verify \
    -pubin -inkey "$_AGENT_PUBKEY_FILE" \
    -in "$file" -sigfile "$tmp_sig" >/dev/null 2>&1 || rc=1

  rm -f "$tmp_sig"

  if [[ $rc -ne 0 ]]; then
    _agent_err "Signature verification FAILED for $(basename "$file")"
    _agent_err "File may have been tampered with"
    return 1
  fi

  return 0
}

# Verify all signed agent files
_agent_verify_integrity() {
  # Verify agent script itself
  if ! _agent_verify_signature "$0" "$_AGENT_SIG_FILE"; then
    _agent_log "SECURITY: agent script signature verification failed"
    return 1
  fi

  # Verify agent config
  if [[ -f "$_AGENT_CONFIG_SIG" ]]; then
    if ! _agent_verify_signature "$_AGENT_CONFIG" "$_AGENT_CONFIG_SIG"; then
      _agent_log "SECURITY: agent.json signature verification failed"
      return 1
    fi
  fi

  return 0
}

# ── JSON helpers (no jq required) ──

# Read a flat key from a JSON file. Tries jq, falls back to grep/sed.
_agent_json_get() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${key} // \"\"" "$file" 2>/dev/null
    return
  fi
  # Fallback: grep for "key": "value" or "key": value
  local val
  val=$(grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//;s/^"//;s/"$//')
  printf '%s' "$val"
}

# List service keys from deploy.json
_agent_list_services() {
  local config="${_AGENT_PROJECT_DIR}/deploy.json"
  [[ -f "$config" ]] || config="${_AGENT_PROJECT_DIR}/muster.json"
  [[ -f "$config" ]] || return 0

  if command -v jq >/dev/null 2>&1; then
    jq -r '(.deploy_order[]? // empty)' "$config" 2>/dev/null
    local _do_count
    _do_count=$(jq -r '.deploy_order | length // 0' "$config" 2>/dev/null)
    if [[ "$_do_count" == "0" || -z "$_do_count" ]]; then
      jq -r '.services | keys[]' "$config" 2>/dev/null
    fi
  else
    # Fallback: grep service keys
    grep -o '"[^"]*"[[:space:]]*:' "$config" 2>/dev/null | \
      sed -n '/^"services"/,/^"[^s]/{ /^"/{ s/"//g; s/://; p; } }' 2>/dev/null
  fi
}

# Check if a service's health is enabled
_agent_svc_health_enabled() {
  local svc="$1"
  local config="${_AGENT_PROJECT_DIR}/deploy.json"
  [[ -f "$config" ]] || config="${_AGENT_PROJECT_DIR}/muster.json"
  [[ -f "$config" ]] || { echo "true"; return; }

  if command -v jq >/dev/null 2>&1; then
    local val
    val=$(jq -r --arg k "$svc" '.services[$k].health.enabled // "true"' "$config" 2>/dev/null)
    printf '%s' "$val"
  else
    echo "true"
  fi
}

# ── Config loading ──

_agent_load_config() {
  if [[ ! -f "$_AGENT_CONFIG" ]]; then
    _agent_err "No agent.json found at ${_AGENT_CONFIG}"
    return 1
  fi

  # Permission check
  _agent_check_permissions "$_AGENT_CONFIG" "agent.json" || return 1

  _AGENT_PROJECT_DIR=$(_agent_json_get "$_AGENT_CONFIG" "project_dir")
  local v
  v=$(_agent_json_get "$_AGENT_CONFIG" "poll_interval")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_POLL_INTERVAL="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "metrics_interval")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_METRICS_INTERVAL="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "logs_interval")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_LOGS_INTERVAL="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "log_tail_lines")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_LOG_TAIL_LINES="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_enabled")
  [[ "$v" == "true" ]] && _AGENT_PUSH_ENABLED=true
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_interval")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_INTERVAL="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_host")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_HOST="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_user")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_USER="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_port")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_PORT="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_identity")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_IDENTITY="$v"
  v=$(_agent_json_get "$_AGENT_CONFIG" "push_dir")
  [[ -n "$v" && "$v" != "null" ]] && _AGENT_PUSH_DIR="$v"

  if [[ -z "$_AGENT_PROJECT_DIR" ]]; then
    _agent_err "project_dir not set in agent.json"
    return 1
  fi

  # Validate all config values
  _agent_validate_safe "$_AGENT_PROJECT_DIR" "project_dir" || return 1
  _agent_validate_int "$_AGENT_POLL_INTERVAL" "poll_interval" || return 1
  _agent_validate_int "$_AGENT_METRICS_INTERVAL" "metrics_interval" || return 1
  _agent_validate_int "$_AGENT_LOGS_INTERVAL" "logs_interval" || return 1
  _agent_validate_int "$_AGENT_LOG_TAIL_LINES" "log_tail_lines" || return 1
  _agent_validate_int "$_AGENT_PUSH_INTERVAL" "push_interval" || return 1
  _agent_validate_int "$_AGENT_PUSH_PORT" "push_port" || return 1
  _agent_validate_int "$_AGENT_HEALTH_TIMEOUT" "health_timeout" || return 1
  if [[ "$_AGENT_PUSH_ENABLED" == "true" ]]; then
    _agent_validate_safe "$_AGENT_PUSH_HOST" "push_host" || return 1
    _agent_validate_safe "$_AGENT_PUSH_USER" "push_user" || return 1
    [[ -n "$_AGENT_PUSH_IDENTITY" ]] && { _agent_validate_safe "$_AGENT_PUSH_IDENTITY" "push_identity" || return 1; }
    [[ -n "$_AGENT_PUSH_DIR" ]] && { _agent_validate_safe "$_AGENT_PUSH_DIR" "push_dir" || return 1; }
  fi

  return 0
}

# ── PID management ──

_agent_acquire_lock() {
  # Use mkdir as an atomic lock (portable, no flock needed)
  if mkdir "$_AGENT_LOCK_FILE" 2>/dev/null; then
    trap '_agent_release_lock' EXIT
    return 0
  fi

  # Lock exists — check if the holding process is still alive
  if [[ -f "$_AGENT_PID_FILE" ]]; then
    local existing_pid
    existing_pid=$(cat "$_AGENT_PID_FILE" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return 1  # genuinely locked
    fi
  fi

  # Stale lock — remove and retry
  rm -rf "$_AGENT_LOCK_FILE"
  if mkdir "$_AGENT_LOCK_FILE" 2>/dev/null; then
    trap '_agent_release_lock' EXIT
    return 0
  fi
  return 1
}

_agent_release_lock() {
  rm -rf "$_AGENT_LOCK_FILE"
}

_agent_is_running() {
  [[ -f "$_AGENT_PID_FILE" ]] || return 1
  local pid
  pid=$(cat "$_AGENT_PID_FILE" 2>/dev/null)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_agent_write_pid() {
  printf '%s' "$$" > "$_AGENT_PID_FILE"
  chmod 600 "$_AGENT_PID_FILE"
}

_agent_remove_pid() {
  rm -f "$_AGENT_PID_FILE"
}

_agent_read_pid() {
  cat "$_AGENT_PID_FILE" 2>/dev/null
}

# ── Ensure directories ──

_agent_ensure_dirs() {
  mkdir -p "$_AGENT_HEALTH_DIR" "$_AGENT_METRICS_DIR" "$_AGENT_EVENTS_DIR" "$_AGENT_LOGS_DIR"
  chmod 700 "$_AGENT_BASE"
}

# ── Health collector ──

_agent_collect_health() {
  local services
  services=$(_agent_list_services)
  [[ -z "$services" ]] && return 0

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue

    # Sanitize service name for use as filename
    local safe_svc
    safe_svc=$(printf '%s' "$svc" | tr -cd 'a-zA-Z0-9._-')
    [[ -z "$safe_svc" ]] && continue

    local hook="${_AGENT_PROJECT_DIR}/.muster/hooks/${safe_svc}/health.sh"
    local result="unhealthy"

    local enabled
    enabled=$(_agent_svc_health_enabled "$svc")
    if [[ "$enabled" == "false" ]]; then
      result="disabled"
    elif [[ -x "$hook" ]]; then
      # Run with timeout (fork + kill pattern)
      (cd "$_AGENT_PROJECT_DIR" && "$hook") &>/dev/null &
      local hpid=$!
      ( sleep "$_AGENT_HEALTH_TIMEOUT" && kill "$hpid" 2>/dev/null ) &
      local tpid=$!
      if wait "$hpid" 2>/dev/null; then
        result="healthy"
      fi
      kill "$tpid" 2>/dev/null
      wait "$tpid" 2>/dev/null
    fi

    printf '%s' "$result" > "${_AGENT_HEALTH_DIR}/${safe_svc}"
  done <<< "$services"

  _agent_log "health: collected"
}

# ── Metrics collector ──

_agent_collect_metrics() {
  local ts cpu mem_pct disk_pct load_avg
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cpu="0"
  mem_pct="0"
  disk_pct="0"
  load_avg="0"

  case "$(uname -s)" in
    Linux)
      # CPU: 1-second sample from /proc/stat
      if [[ -f /proc/stat ]]; then
        local c1 c2
        c1=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
        sleep 1
        c2=$(awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
        local t1 i1 t2 i2
        t1="${c1%% *}"; i1="${c1##* }"
        t2="${c2%% *}"; i2="${c2##* }"
        local dt di
        dt=$(( t2 - t1 ))
        di=$(( i2 - i1 ))
        if (( dt > 0 )); then
          cpu=$(awk -v di="$di" -v dt="$dt" 'BEGIN {printf "%.1f", (1 - di/dt) * 100}')
        fi
      fi
      # Memory
      if command -v free >/dev/null 2>&1; then
        mem_pct=$(free 2>/dev/null | awk '/^Mem:/ {printf "%.1f", $3/$2 * 100}')
      fi
      # Disk
      disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
      # Load
      load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
      ;;
    Darwin)
      # CPU from top
      cpu=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub(/%/,""); print $3+$5}')
      # Memory from vm_stat
      local _page_size _pages_free _pages_active _pages_speculative _pages_wired
      _page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      _pages_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,""); print $3}')
      _pages_active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,""); print $3}')
      _pages_speculative=$(vm_stat 2>/dev/null | awk '/Pages speculative/ {gsub(/\./,""); print $3}')
      _pages_wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,""); print $4}')
      local _total_mem
      _total_mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
      if [[ -n "$_pages_active" && -n "$_pages_wired" && "$_total_mem" != "0" ]]; then
        local _used_bytes=$(( (_pages_active + _pages_wired) * _page_size ))
        mem_pct=$(awk -v used="$_used_bytes" -v total="$_total_mem" 'BEGIN {printf "%.1f", used/total * 100}')
      fi
      # Disk
      disk_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
      # Load
      load_avg=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
      ;;
  esac

  : "${cpu:=0}"
  : "${mem_pct:=0}"
  : "${disk_pct:=0}"
  : "${load_avg:=0}"

  printf '{"ts":"%s","cpu":%s,"mem_pct":%s,"disk_pct":%s,"load":%s}\n' \
    "$ts" "$cpu" "$mem_pct" "$disk_pct" "$load_avg" \
    > "${_AGENT_METRICS_DIR}/latest.json"

  _agent_log "metrics: cpu=${cpu} mem=${mem_pct} disk=${disk_pct}"
}

# ── Log tail collector ──

_agent_collect_logs() {
  local services
  services=$(_agent_list_services)
  [[ -z "$services" ]] && return 0

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue

    local safe_svc
    safe_svc=$(printf '%s' "$svc" | tr -cd 'a-zA-Z0-9._-')
    [[ -z "$safe_svc" ]] && continue

    local hook="${_AGENT_PROJECT_DIR}/.muster/hooks/${safe_svc}/logs.sh"
    [[ -x "$hook" ]] || continue

    local tail_file="${_AGENT_LOGS_DIR}/${safe_svc}.tail"

    # Run logs hook with timeout, capture last N lines
    local tmplog
    tmplog=$(mktemp "${_AGENT_BASE}/.logtmp.XXXXXX") || continue
    (
      cd "$_AGENT_PROJECT_DIR" 2>/dev/null || true
      "$hook" 2>/dev/null
    ) > "$tmplog" 2>/dev/null &
    local lpid=$!
    ( sleep 5 && kill "$lpid" 2>/dev/null ) &
    local ltpid=$!
    wait "$lpid" 2>/dev/null
    kill "$ltpid" 2>/dev/null
    wait "$ltpid" 2>/dev/null

    if [[ -f "$tmplog" ]]; then
      tail -n "$_AGENT_LOG_TAIL_LINES" "$tmplog" > "$tail_file" 2>/dev/null
      rm -f "$tmplog"
    fi
  done <<< "$services"

  _agent_log "logs: collected"
}

# ── Event watcher ──

_AGENT_EVENTS_OFFSET=0

_agent_collect_events() {
  local evlog="${_AGENT_PROJECT_DIR}/.muster/logs/deploy-events.log"
  [[ -f "$evlog" ]] || return 0

  local current_size
  current_size=$(wc -c < "$evlog" 2>/dev/null | tr -d ' ')
  : "${current_size:=0}"

  if (( current_size > _AGENT_EVENTS_OFFSET )); then
    # New data — copy new lines
    tail -c "+$(( _AGENT_EVENTS_OFFSET + 1 ))" "$evlog" >> "${_AGENT_EVENTS_DIR}/deploy.log" 2>/dev/null
    _AGENT_EVENTS_OFFSET="$current_size"
    _agent_log "events: synced to offset ${_AGENT_EVENTS_OFFSET}"
  fi
}

_agent_init_events_offset() {
  local evlog="${_AGENT_PROJECT_DIR}/.muster/logs/deploy-events.log"
  if [[ -f "$evlog" ]]; then
    _AGENT_EVENTS_OFFSET=$(wc -c < "$evlog" 2>/dev/null | tr -d ' ')
    : "${_AGENT_EVENTS_OFFSET:=0}"
  fi
}

# ── Report encryption ──
# Hybrid RSA-4096 + AES-256-CBC encryption for push reports.
# Only encrypts if fleet.pub is present (pushed during agent install).

_agent_encrypt_file() {
  local input="$1" output="$2" pubkey="$3"

  [[ ! -f "$input" || ! -f "$pubkey" ]] && return 1
  command -v openssl >/dev/null 2>&1 || return 1

  local tmpdir
  tmpdir=$(mktemp -d "${_AGENT_BASE}/.enc.XXXXXX") || return 1

  # Generate random AES-256 session key + IV
  openssl rand 32 > "${tmpdir}/k" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
  openssl rand 16 > "${tmpdir}/v" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }

  # Wrap session key with RSA public key (OAEP + SHA-256)
  openssl pkeyutl -encrypt -pubin -inkey "$pubkey" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
    -in "${tmpdir}/k" -out "${tmpdir}/k.enc" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  # Encrypt data with AES-256-CBC
  local kh vh
  kh=$(xxd -p < "${tmpdir}/k" | tr -d '\n')
  vh=$(xxd -p < "${tmpdir}/v" | tr -d '\n')

  openssl enc -aes-256-cbc -in "$input" -out "${tmpdir}/d.enc" \
    -K "$kh" -iv "$vh" 2>/dev/null || {
    rm -rf "$tmpdir"
    return 1
  }

  # Pack: base64(encrypted_key)\nbase64(iv)\nbase64(ciphertext)
  {
    base64 < "${tmpdir}/k.enc" | tr -d '\n'; echo ""
    base64 < "${tmpdir}/v" | tr -d '\n'; echo ""
    base64 < "${tmpdir}/d.enc" | tr -d '\n'; echo ""
  } > "$output"

  rm -rf "$tmpdir"
  return 0
}

# ── Push summary ──

_agent_push_summary() {
  [[ "$_AGENT_PUSH_ENABLED" == "true" ]] || return 0
  [[ -n "$_AGENT_PUSH_HOST" && -n "$_AGENT_PUSH_USER" ]] || return 0

  # Build summary using jq if available, otherwise safe printf
  local summary_file="${_AGENT_BASE}/summary.json"
  local ts hostname_short
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  hostname_short=$(hostname -s 2>/dev/null || hostname)
  # Sanitize hostname
  hostname_short=$(printf '%s' "$hostname_short" | tr -cd 'a-zA-Z0-9._-')

  if command -v jq >/dev/null 2>&1; then
    # Build health object safely with jq
    local health_json="{}"
    if [[ -d "$_AGENT_HEALTH_DIR" ]]; then
      health_json=$(
        for hf in "${_AGENT_HEALTH_DIR}"/*; do
          [[ -f "$hf" ]] || continue
          local sname hval
          sname=$(basename "$hf")
          hval=$(cat "$hf" 2>/dev/null)
          printf '%s\t%s\n' "$sname" "$hval"
        done | jq -Rsn '
          [inputs | split("\n")[] | select(length > 0) | split("\t") | {(.[0]): .[1]}] | add // {}
        '
      )
    fi

    local metrics_json="{}"
    [[ -f "${_AGENT_METRICS_DIR}/latest.json" ]] && metrics_json=$(cat "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)

    jq -n \
      --arg ts "$ts" \
      --arg hostname "$hostname_short" \
      --arg version "$AGENT_VERSION" \
      --argjson health "$health_json" \
      --argjson metrics "$metrics_json" \
      '{ts: $ts, hostname: $hostname, version: $version, health: $health, metrics: $metrics}' \
      > "$summary_file"
  else
    # No jq — build manually with escaped values
    local health_json="{"
    local first=true
    if [[ -d "$_AGENT_HEALTH_DIR" ]]; then
      for hf in "${_AGENT_HEALTH_DIR}"/*; do
        [[ -f "$hf" ]] || continue
        local sname hval
        sname=$(basename "$hf")
        # Sanitize: only allow safe chars in service names
        sname=$(printf '%s' "$sname" | tr -cd 'a-zA-Z0-9._-')
        [[ -z "$sname" ]] && continue
        hval=$(cat "$hf" 2>/dev/null)
        # Health values are only: healthy, unhealthy, disabled
        case "$hval" in
          healthy|unhealthy|disabled) ;;
          *) hval="unknown" ;;
        esac
        [[ "$first" == "true" ]] && first=false || health_json="${health_json},"
        health_json="${health_json}\"${sname}\":\"${hval}\""
      done
    fi
    health_json="${health_json}}"

    local metrics_json="{}"
    [[ -f "${_AGENT_METRICS_DIR}/latest.json" ]] && metrics_json=$(cat "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)

    local escaped_ts escaped_host escaped_ver
    escaped_ts=$(_agent_json_escape "$ts")
    escaped_host=$(_agent_json_escape "$hostname_short")
    escaped_ver=$(_agent_json_escape "$AGENT_VERSION")

    printf '{"ts":"%s","hostname":"%s","version":"%s","health":%s,"metrics":%s}\n' \
      "$escaped_ts" "$escaped_host" "$escaped_ver" "$health_json" "$metrics_json" \
      > "$summary_file"
  fi

  # Encrypt if fleet public key is present
  local push_file="$summary_file"
  local push_filename="latest.json"
  if [[ -f "$_AGENT_FLEET_PUBKEY" ]]; then
    local enc_file="${_AGENT_BASE}/summary.enc"
    if _agent_encrypt_file "$summary_file" "$enc_file" "$_AGENT_FLEET_PUBKEY"; then
      push_file="$enc_file"
      push_filename="latest.enc"
      _agent_log "push: report encrypted with fleet key"
    else
      _agent_log "push: encryption failed, sending plaintext"
    fi
  fi

  # Push via SCP (avoid embedding paths in remote shell commands)
  local _ssh_args="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  if [[ -n "$_AGENT_PUSH_IDENTITY" ]]; then
    _ssh_args="${_ssh_args} -i ${_AGENT_PUSH_IDENTITY}"
  fi
  if [[ "$_AGENT_PUSH_PORT" != "22" ]]; then
    _ssh_args="${_ssh_args} -p ${_AGENT_PUSH_PORT}"
  fi

  local _scp_args="${_ssh_args//-p /-P }"

  # Create remote directory (push into fleet dir structure)
  local remote_dir
  remote_dir=$(printf '%s' "$_AGENT_PUSH_DIR")

  # shellcheck disable=SC2086
  ssh $_ssh_args -- "${_AGENT_PUSH_USER}@${_AGENT_PUSH_HOST}" \
    "mkdir -p -- '$(printf '%s' "$remote_dir" | sed "s/'/'\\\\''/g")'" 2>/dev/null || {
    _agent_log "push: failed to create remote dir"
    return 1
  }

  # shellcheck disable=SC2086
  scp $_scp_args -- "$push_file" \
    "${_AGENT_PUSH_USER}@${_AGENT_PUSH_HOST}:${remote_dir}/${push_filename}" 2>/dev/null || {
    _agent_log "push: failed to scp summary"
    return 1
  }

  _agent_log "push: ${push_filename} sent to ${_AGENT_PUSH_HOST}"
}

# ── Signal handlers ──

_agent_shutdown=false

_agent_handle_term() {
  _agent_log "received SIGTERM, shutting down"
  _agent_shutdown=true
}

_agent_handle_hup() {
  _agent_log "received SIGHUP, reloading config"
  _agent_load_config
}

# ── Main daemon loop ──

_agent_main_loop() {
  trap '_agent_handle_term' TERM INT
  trap '_agent_handle_hup' HUP

  _agent_write_pid
  _agent_ensure_dirs
  _agent_init_events_offset

  _agent_log "started (pid $$, project ${_AGENT_PROJECT_DIR})"

  local tick=0
  while [[ "$_agent_shutdown" == "false" ]]; do
    # Health
    if (( tick % _AGENT_POLL_INTERVAL == 0 )); then
      _agent_collect_health
    fi
    # Metrics
    if (( tick % _AGENT_METRICS_INTERVAL == 0 )); then
      _agent_collect_metrics
    fi
    # Log tails
    if (( tick % _AGENT_LOGS_INTERVAL == 0 )); then
      _agent_collect_logs
    fi
    # Events (every tick — lightweight file size check)
    _agent_collect_events
    # Push summary
    if [[ "$_AGENT_PUSH_ENABLED" == "true" ]] && (( tick % _AGENT_PUSH_INTERVAL == 0 && tick > 0 )); then
      _agent_push_summary
    fi

    sleep 1
    tick=$(( tick + 1 ))
    # Prevent overflow
    (( tick > 86400 )) && tick=0
  done

  _agent_remove_pid
  _agent_release_lock
  _agent_log "stopped"
}

# ── CLI commands ──

_agent_cmd_start() {
  _agent_load_config || return 1

  # Verify file integrity before starting
  _agent_verify_integrity || {
    _agent_err "Integrity check failed — refusing to start"
    _agent_err "Reinstall with: muster fleet install-agent <machine> --force"
    return 1
  }

  if _agent_is_running; then
    local pid
    pid=$(_agent_read_pid)
    _agent_info "Agent already running (pid ${pid})"
    return 0
  fi

  # Acquire lock to prevent duplicate starts
  if ! _agent_acquire_lock; then
    _agent_err "Another agent instance is starting"
    return 1
  fi

  if [[ "${1:-}" == "--foreground" ]]; then
    # Foreground mode (for systemd/launchd)
    _agent_main_loop
  else
    # Background mode
    _agent_ensure_dirs
    nohup "$0" _daemon >> "${_AGENT_BASE}/daemon.log" 2>&1 &
    local bg_pid=$!
    disown "$bg_pid" 2>/dev/null
    _agent_ok "Agent started (pid ${bg_pid})"
  fi
}

_agent_cmd_stop() {
  if ! _agent_is_running; then
    _agent_info "Agent not running"
    return 0
  fi

  local pid
  pid=$(_agent_read_pid)
  kill "$pid" 2>/dev/null
  # Wait up to 5 seconds
  local i=0
  while (( i < 5 )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    i=$(( i + 1 ))
  done
  # Force kill if still running
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
  fi
  _agent_remove_pid
  _agent_release_lock
  _agent_ok "Agent stopped"
}

_agent_cmd_status() {
  echo ""
  printf '  \033[1mMuster Agent\033[0m v%s\n' "$AGENT_VERSION"
  echo ""

  if _agent_is_running; then
    local pid
    pid=$(_agent_read_pid)
    printf '  Status: \033[32mrunning\033[0m (pid %s)\n' "$pid"
  else
    printf '  Status: \033[31mstopped\033[0m\n'
  fi

  # Signature status
  if [[ -f "$_AGENT_PUBKEY_FILE" ]]; then
    if _agent_verify_signature "$0" "$_AGENT_SIG_FILE" 2>/dev/null; then
      printf '  Signed: \033[32mverified\033[0m\n'
    else
      printf '  Signed: \033[31mFAILED\033[0m\n'
    fi
  else
    printf '  Signed: \033[2mnot configured\033[0m\n'
  fi

  if [[ -f "$_AGENT_CONFIG" ]]; then
    local pd
    pd=$(_agent_json_get "$_AGENT_CONFIG" "project_dir")
    printf '  Project: %s\n' "$pd"
  fi

  # Health summary
  if [[ -d "$_AGENT_HEALTH_DIR" ]]; then
    local _h_count=0 _h_healthy=0 _h_unhealthy=0
    for hf in "${_AGENT_HEALTH_DIR}"/*; do
      [[ -f "$hf" ]] || continue
      _h_count=$(( _h_count + 1 ))
      local hv
      hv=$(cat "$hf" 2>/dev/null)
      case "$hv" in
        healthy)   _h_healthy=$(( _h_healthy + 1 )) ;;
        unhealthy) _h_unhealthy=$(( _h_unhealthy + 1 )) ;;
      esac
    done
    if (( _h_count > 0 )); then
      echo ""
      printf '  Services: %d healthy, %d unhealthy (%d total)\n' "$_h_healthy" "$_h_unhealthy" "$_h_count"
    fi
  fi

  # Latest metrics
  if [[ -f "${_AGENT_METRICS_DIR}/latest.json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      local _m_cpu _m_mem _m_disk _m_ts
      _m_cpu=$(jq -r '.cpu // 0' "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)
      _m_mem=$(jq -r '.mem_pct // 0' "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)
      _m_disk=$(jq -r '.disk_pct // 0' "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)
      _m_ts=$(jq -r '.ts // ""' "${_AGENT_METRICS_DIR}/latest.json" 2>/dev/null)
      printf '  CPU: %s%%  Mem: %s%%  Disk: %s%%\n' "$_m_cpu" "$_m_mem" "$_m_disk"
      [[ -n "$_m_ts" ]] && printf '  \033[2mLast poll: %s\033[0m\n' "$_m_ts"
    else
      printf '  \033[2mMetrics available (install jq for details)\033[0m\n'
    fi
  fi
  echo ""
}

_agent_cmd_run_once() {
  _agent_load_config || return 1

  # Verify file integrity
  _agent_verify_integrity || {
    _agent_err "Integrity check failed — refusing to run"
    return 1
  }

  _agent_ensure_dirs
  _agent_init_events_offset

  _agent_collect_health
  _agent_collect_metrics
  _agent_collect_logs
  _agent_collect_events
  if [[ "$_AGENT_PUSH_ENABLED" == "true" ]]; then
    _agent_push_summary
  fi
  _agent_log "run-once complete"
}

_agent_cmd_help() {
  echo "muster-agent v${AGENT_VERSION} — Fleet monitoring daemon"
  echo ""
  echo "Usage: muster-agent.sh <command>"
  echo ""
  echo "Commands:"
  echo "  start [--foreground]   Start the agent daemon"
  echo "  stop                   Stop the agent daemon"
  echo "  status                 Show agent status and data"
  echo "  run-once               Collect all data once and exit"
  echo "  verify                 Verify file integrity"
  echo ""
  echo "Config: ${_AGENT_CONFIG}"
  echo "Data:   ${_AGENT_BASE}/"
}

_agent_cmd_verify() {
  echo ""
  printf '  \033[1mMuster Agent Integrity Check\033[0m\n'
  echo ""

  if [[ ! -f "$_AGENT_PUBKEY_FILE" ]]; then
    _agent_warn "No signing key installed — skipping verification"
    printf '  \033[2mReinstall with signing enabled: muster fleet install-agent <name> --force\033[0m\n'
    echo ""
    return 0
  fi

  local _vf_ok=0 _vf_fail=0

  # Verify agent script
  if _agent_verify_signature "$0" "$_AGENT_SIG_FILE"; then
    _agent_ok "Agent script: verified"
    _vf_ok=$(( _vf_ok + 1 ))
  else
    _agent_err "Agent script: FAILED"
    _vf_fail=$(( _vf_fail + 1 ))
  fi

  # Verify config
  if [[ -f "$_AGENT_CONFIG_SIG" ]]; then
    if _agent_verify_signature "$_AGENT_CONFIG" "$_AGENT_CONFIG_SIG"; then
      _agent_ok "Agent config: verified"
      _vf_ok=$(( _vf_ok + 1 ))
    else
      _agent_err "Agent config: FAILED"
      _vf_fail=$(( _vf_fail + 1 ))
    fi
  else
    _agent_info "Agent config: not signed"
  fi

  # Check file permissions
  _agent_check_permissions "$_AGENT_CONFIG" "agent.json" && {
    _agent_ok "Config permissions: OK"
    _vf_ok=$(( _vf_ok + 1 ))
  } || {
    _agent_err "Config permissions: FAILED"
    _vf_fail=$(( _vf_fail + 1 ))
  }

  echo ""
  if (( _vf_fail > 0 )); then
    _agent_err "${_vf_fail} check(s) failed"
    return 1
  else
    _agent_ok "All ${_vf_ok} check(s) passed"
  fi
  echo ""
}

# ── Entry point ──

case "${1:-}" in
  start)
    shift
    _agent_cmd_start "$@"
    ;;
  stop)
    _agent_cmd_stop
    ;;
  status)
    _agent_cmd_status
    ;;
  run-once)
    _agent_cmd_run_once
    ;;
  verify)
    _agent_cmd_verify
    ;;
  _daemon)
    # Internal: called by nohup for background mode
    _agent_load_config || exit 1
    _agent_verify_integrity || exit 1
    _agent_acquire_lock || { _agent_err "Lock held by another instance"; exit 1; }
    _agent_main_loop
    ;;
  --version|-v)
    echo "v${AGENT_VERSION}"
    ;;
  --help|-h|"")
    _agent_cmd_help
    ;;
  *)
    _agent_err "Unknown command: $1"
    echo "Run '$(basename "$0") --help' for usage."
    exit 1
    ;;
esac
