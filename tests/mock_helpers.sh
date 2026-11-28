#!/usr/bin/env bash
# tests/mock_helpers.sh — fake docker/kubectl/lsof/ssh/ss binaries on PATH.
#
#   _mock_init                  create $MOCK_BIN and prepend it to PATH
#   _mock_cmd NAME 'body'       write a fake executable (bash body, "$@" = args)
#   _mock_missing NAME          make NAME unavailable (drop PATH dirs that have it)
#
# Every test that sources this gets a PATH where docker, kubectl, lsof, ss and
# ssh are fakes, so results never depend on the developer's machine.

_mock_init() {
  MOCK_BIN=$(mktemp -d)
  export MOCK_BIN
  export PATH="${MOCK_BIN}:${PATH}"
  # Safe defaults: docker running with nothing published, nothing listening,
  # kubectl/ssh succeed.
  _mock_cmd docker 'exit 0'
  _mock_cmd kubectl 'case "$1" in config) [[ "$2" == "current-context" ]] && echo "dev-cluster"; exit 0 ;; *) exit 0 ;; esac'
  _mock_cmd lsof 'exit 1'
  _mock_cmd ss 'exit 0'
  _mock_cmd ssh 'exit 0'
}

_mock_cmd() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "${MOCK_BIN:?}/${name:?}"
  chmod +x "${MOCK_BIN:?}/${name:?}"
}

_mock_missing() {
  local name="$1" d newpath=""
  rm -f "${MOCK_BIN:?}/${name:?}"
  local IFS=':'
  for d in $PATH; do
    [[ -x "${d}/${name}" ]] && continue
    newpath="${newpath:+${newpath}:}${d}"
  done
  export PATH="$newpath"
}

_mock_cleanup() {
  [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN:-}" ]] && rm -rf "${MOCK_BIN:?}"
  return 0
}

# ── Stateful fake Kubernetes cluster (rollout tests) ──
#
#   _mock_kube_cluster          install a kubectl that keeps objects as JSON
#                               files under $KUBE_STATE/<ns>/<kind>/<name>.json
#   _kube_seed_deployment name ns image replicas [app-label]
#   _kube_seed_service name ns [app-label]
#   _kube_fault deploy reason   pods of `deploy` report `reason` (e.g.
#                               CrashLoopBackOff) and never become ready;
#                               "restarts:N" makes them ready but restarting
#   _kube_get kind name [ns]    print a stored object
#
# Supported: get (object / list -o json, jsonpath ready/desired), apply -f -,
# scale, patch --type=merge, set image, rollout status, delete, auth can-i,
# config current-context. Pods are synthesized from Deployments (one per
# replica) and matched with -l a=b,c=d. Every Deployment is "ready" at once
# unless it has a fault. Template changes bump deployment.kubernetes.io/revision.
_mock_kube_cluster() {
  KUBE_STATE="${KUBE_STATE:-$(mktemp -d)}"
  export KUBE_STATE
  mkdir -p "$KUBE_STATE/faults"
  cat > "${MOCK_BIN:?}/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
S="${KUBE_STATE:?}"
printf '%s\n' "$*" >> "$S/calls.log"
ns="default" out="" sel="" file="" patch="" reps="" pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --request-timeout=*|--ignore-not-found|--type=*|--overwrite) shift ;;
    --type) shift 2 ;;
    -n|--namespace) ns="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -o*) out="${1#-o}"; shift ;;
    -l) sel="$2"; shift 2 ;;
    -f) file="$2"; shift 2 ;;
    -p) patch="$2"; shift 2 ;;
    --replicas=*) reps="${1#--replicas=}"; shift ;;
    --timeout=*) shift ;;
    *) pos[${#pos[@]}]="$1"; shift ;;
  esac
done
kind_of() {
  case "$1" in
    deploy|deployment|deployments|deployment.apps) echo deployment ;;
    svc|service|services) echo service ;;
    cm|configmap|configmaps) echo configmap ;;
    rs|replicaset|replicasets) echo replicaset ;;
    po|pod|pods) echo pod ;;
    *) echo "$1" ;;
  esac
}
obj() { echo "$S/$ns/$1/$2.json"; }
# Recompute a Deployment's status from spec + faults
refresh() {
  local f="$1" name fault ready
  name=$(jq -r '.metadata.name' "$f")
  fault=""
  [[ -f "$S/faults/$name" ]] && fault=$(cat "$S/faults/$name")
  jq --arg fault "$fault" '
    (.spec.replicas // 1) as $r
    | .spec.replicas = $r
    | .status = {replicas: $r, observedGeneration: 1,
        readyReplicas: (if ($fault != "" and ($fault | startswith("restarts:") | not)) then 0 else $r end),
        updatedReplicas: (if ($fault != "" and ($fault | startswith("restarts:") | not)) then 0 else $r end),
        availableReplicas: (if ($fault != "" and ($fault | startswith("restarts:") | not)) then 0 else $r end)}' \
    "$f" > "$f.t" && mv "$f.t" "$f"
}
# Store a Deployment, bumping the revision when the pod template changed
store_deploy() {
  local f="$1" new="$2" oldt="" rev=0
  if [[ -f "$f" ]]; then
    oldt=$(jq -c '.spec.template' "$f")
    rev=$(jq -r '.metadata.annotations["deployment.kubernetes.io/revision"] // "0"' "$f")
  fi
  local newt
  newt=$(printf '%s' "$new" | jq -c '.spec.template')
  [[ "$newt" != "$oldt" ]] && rev=$(( rev + 1 ))
  printf '%s' "$new" | jq --arg r "$rev" --arg ns "$ns" \
    '.metadata.namespace = $ns | .metadata.annotations = ((.metadata.annotations // {}) + {"deployment.kubernetes.io/revision": $r})' > "$f"
  refresh "$f"
}
verb="${pos[0]:-}"
case "$verb" in
  config) [[ "${pos[1]:-}" == "current-context" ]] && echo "fake-cluster"; exit 0 ;;
  auth) echo yes; exit 0 ;;
  version|cluster-info) echo "fake"; exit 0 ;;
  get)
    k=$(kind_of "${pos[1]:-}") name="${pos[2]:-}"
    if [[ "$k" == "pod" ]]; then
      shopt -s nullglob
      items="[]"
      for d in "$S/$ns/deployment/"*.json; do
        dn=$(jq -r '.metadata.name' "$d")
        fault=""; [[ -f "$S/faults/$dn" ]] && fault=$(cat "$S/faults/$dn")
        items=$(jq -c --slurpfile d "$d" --arg sel "$sel" --arg fault "$fault" '
          ($d[0]) as $dep
          | ($sel | split(",") | map(select(. != "") | split("=") | {key: .[0], value: .[1]}) | from_entries) as $want
          | ($dep.spec.template.metadata.labels // {}) as $have
          | if all($want | to_entries[]; $have[.key] == .value) then
              . + [range(0; $dep.spec.replicas // 0) as $i | {
                metadata: {name: "\($dep.metadata.name)-pod-\($i)", labels: $have},
                status: {phase: "Running", containerStatuses: [ ($dep.spec.template.spec.containers // [])[] | {
                  name: .name, image: .image,
                  ready: ($fault == "" or ($fault | startswith("restarts:"))),
                  restartCount: (if ($fault | startswith("restarts:")) then ($fault | ltrimstr("restarts:") | tonumber)
                                 elif $fault != "" then 3 else 0 end),
                  state: (if $fault != "" and ($fault | startswith("restarts:") | not) then {waiting: {reason: $fault}} else {running: {}} end)}]}}]
            else . end' <<< "$items")
      done
      jq -n --argjson i "$items" '{kind: "List", items: $i}'
      exit 0
    fi
    if [[ -z "$name" ]]; then
      shopt -s nullglob
      files=("$S/$ns/$k/"*.json)
      if (( ${#files[@]} == 0 )); then echo '{"kind":"List","items":[]}'; else jq -s '{kind: "List", items: .}' "${files[@]}"; fi
      exit 0
    fi
    f=$(obj "$k" "$name")
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $k \"$name\" not found" >&2; exit 1; }
    case "$out" in
      json) cat "$f" ;;
      jsonpath=*readyReplicas*) jq -r '"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"' "$f" ;;
      jsonpath=*) jq -r '.' "$f" ;;
      *) jq -r '.metadata.name' "$f" ;;
    esac
    exit 0
    ;;
  apply)
    [[ "$file" == "-" ]] || exit 0
    doc=$(cat)
    k=$(printf '%s' "$doc" | jq -r '.kind | ascii_downcase')
    name=$(printf '%s' "$doc" | jq -r '.metadata.name')
    [[ -n "$(printf '%s' "$doc" | jq -r '.metadata.namespace // empty')" ]] && ns=$(printf '%s' "$doc" | jq -r '.metadata.namespace')
    mkdir -p "$S/$ns/$k"
    if [[ "$k" == "deployment" ]]; then
      store_deploy "$(obj deployment "$name")" "$doc"
    else
      printf '%s' "$doc" | jq --arg ns "$ns" '.metadata.namespace = $ns' > "$(obj "$k" "$name")"
    fi
    echo "$k/$name configured"
    exit 0
    ;;
  scale)
    t="${pos[1]:-}"; name="${t#*/}"
    f=$(obj deployment "$name")
    [[ -f "$f" ]] || { echo "Error from server (NotFound): deployments \"$name\" not found" >&2; exit 1; }
    jq --argjson r "${reps:-1}" '.spec.replicas = $r' "$f" > "$f.t" && mv "$f.t" "$f"
    refresh "$f"
    echo "deployment.apps/$name scaled"
    exit 0
    ;;
  patch)
    k=$(kind_of "${pos[1]:-}") name="${pos[2]:-}"
    f=$(obj "$k" "$name")
    [[ -f "$f" ]] || { echo "Error from server (NotFound): $k \"$name\" not found" >&2; exit 1; }
    if [[ "$k" == "deployment" ]]; then
      store_deploy "$f" "$(jq --argjson p "$patch" '. * $p' "$f")"
    else
      jq --argjson p "$patch" '. * $p' "$f" > "$f.t" && mv "$f.t" "$f"
    fi
    echo "$k/$name patched"
    exit 0
    ;;
  set)
    [[ "${pos[1]:-}" == "image" ]] || exit 0
    t="${pos[2]:-}"; name="${t#*/}"; spec="${pos[3]:-}"
    f=$(obj deployment "$name")
    [[ -f "$f" ]] || { echo "Error from server (NotFound): deployments \"$name\" not found" >&2; exit 1; }
    c="${spec%%=*}"; img="${spec#*=}"
    if ! jq -e --arg c "$c" 'any(.spec.template.spec.containers[]; .name == $c)' "$f" >/dev/null; then
      echo "error: unable to find container named \"$c\"" >&2; exit 1
    fi
    store_deploy "$f" "$(jq --arg c "$c" --arg i "$img" '.spec.template.spec.containers |= map(if .name == $c then .image = $i else . end)' "$f")"
    echo "deployment.apps/$name image updated"
    exit 0
    ;;
  rollout)
    t="${pos[2]:-}"; name="${t#*/}"
    [[ -f "$S/faults/$name" && "$(cat "$S/faults/$name")" != restarts:* ]] && { echo "error: deployment \"$name\" exceeded its progress deadline" >&2; exit 1; }
    echo "deployment \"$name\" successfully rolled out"
    exit 0
    ;;
  delete)
    k=$(kind_of "${pos[1]:-}") name="${pos[2]:-}"
    rm -f "$(obj "$k" "$name")"
    exit 0
    ;;
esac
exit 0
KUBECTL
  chmod +x "${MOCK_BIN:?}/kubectl"
}

_kube_seed_deployment() {
  local name="$1" ns="$2" image="$3" reps="$4" app="${5:-$1}"
  mkdir -p "$KUBE_STATE/$ns"
  jq -nc --arg n "$name" --arg ns "$ns" --arg i "$image" --argjson r "$reps" --arg a "$app" '{
    apiVersion: "apps/v1", kind: "Deployment",
    metadata: {name: $n, namespace: $ns, labels: {app: $a}},
    spec: {replicas: $r, selector: {matchLabels: {app: $a}},
      template: {metadata: {labels: {app: $a}}, spec: {containers: [{name: $a, image: $i}]}}}}' \
    | kubectl apply -n "$ns" -f - >/dev/null
}

_kube_seed_service() {
  local name="$1" ns="$2" app="${3:-$1}"
  jq -nc --arg n "$name" --arg ns "$ns" --arg a "$app" '{
    apiVersion: "v1", kind: "Service",
    metadata: {name: $n, namespace: $ns},
    spec: {type: "ClusterIP", clusterIP: "10.0.0.10", selector: {app: $a}, ports: [{port: 80, targetPort: 8080}]}}' \
    | kubectl apply -n "$ns" -f - >/dev/null
}

_kube_fault() {
  if [[ -z "${2:-}" ]]; then rm -f "$KUBE_STATE/faults/$1"; else printf '%s' "$2" > "$KUBE_STATE/faults/$1"; fi
}

_kube_get() {
  local f="$KUBE_STATE/${3:-default}/$1/$2.json"
  [[ -f "$f" ]] && cat "$f"
}
