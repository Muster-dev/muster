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
