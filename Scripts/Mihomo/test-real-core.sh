#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly EXPECTED_VERSION="v1.19.29"
readonly CORE_NAME="LOCAL-DIRECT"
readonly PROVIDER_NAME="local-provider"
readonly RULE_PROVIDER_NAME="local-rules"
readonly INITIAL_RULE="hot-v1.test"
readonly HOT_RULE="hot-v2.test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BINARY="${PROJECT_ROOT}/Vendor/Mihomo/bin/mihomo"
CONTROLLER_GATE="${SCRIPT_DIR}/real-core-controller-gate.py"
PACK_FIXTURES="${PROJECT_ROOT}/Docs/Vela-v0.2-Daily-Driver-Codex-Pack/fixtures"

TEMP_ROOT=""
TEMP_BASE=""
CORE_PID=""
MIXED_PORT=""
CONTROLLER_PORT=""
VERSION_OUTPUT=""
CYCLE_PIDS=""
CORE_START_IDENTITY=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

print_diagnostic_file() {
  local label="$1"
  local path="$2"
  if [[ -s "${path}" ]]; then
    printf '%s (last 30 lines):\n' "${label}" >&2
    /usr/bin/tail -n 30 "${path}" >&2 || true
  fi
}

owned_core_is_running() {
  local command
  local start_identity
  [[ -n "${CORE_PID}" ]] || return 1
  /bin/kill -0 "${CORE_PID}" 2>/dev/null || return 1
  command="$(/bin/ps -p "${CORE_PID}" -o command= 2>/dev/null || true)"
  start_identity="$(/bin/ps -p "${CORE_PID}" -o lstart= 2>/dev/null || true)"
  [[ -n "${command}" && -n "${start_identity}" ]] || return 1
  [[ "${command}" == "${BINARY} -d ${VALID_HOME} -f ${VALID_CONFIG}"* ]] || return 1
  [[ "${start_identity}" == "${CORE_START_IDENTITY}" ]]
}

terminate_owned_core() {
  local recorded_pid="${CORE_PID}"
  [[ -n "${recorded_pid}" ]] || return 0
  if ! /bin/kill -0 "${recorded_pid}" 2>/dev/null; then
    wait "${recorded_pid}" 2>/dev/null || true
    CORE_PID=""
    CORE_START_IDENTITY=""
    return 0
  fi
  owned_core_is_running || return 1
  /bin/kill -TERM "${recorded_pid}"
  for _ in {1..100}; do
    if ! /bin/kill -0 "${recorded_pid}" 2>/dev/null; then
      break
    fi
    /bin/sleep 0.1
  done
  if /bin/kill -0 "${recorded_pid}" 2>/dev/null; then
    owned_core_is_running || return 1
    printf 'warning: recorded Mihomo PID %s required SIGKILL after SIGTERM timeout\n' "${recorded_pid}" >&2
    /bin/kill -KILL "${recorded_pid}"
  fi
  wait "${recorded_pid}" 2>/dev/null || true
  CORE_PID=""
  CORE_START_IDENTITY=""
  if /bin/kill -0 "${recorded_pid}" 2>/dev/null; then
    return 1
  fi
  CYCLE_PIDS="${CYCLE_PIDS}${CYCLE_PIDS:+,}${recorded_pid}"
}

cleanup() {
  local status=$?
  local cleanup_failed=0
  if [[ -n "${CORE_PID}" ]] && /bin/kill -0 "${CORE_PID}" 2>/dev/null; then
    if ! terminate_owned_core; then
      printf 'error: refused to signal PID %s because its identity no longer belongs to this test\n' "${CORE_PID}" >&2
      cleanup_failed=1
    fi
  fi

  if [[ "${status}" != "0" && -n "${TEMP_ROOT}" ]]; then
    printf 'Real-core integration gate failed (mixed-port=%s controller-port=%s pid=%s).\n' \
      "${MIXED_PORT:-unset}" "${CONTROLLER_PORT:-unset}" "${CORE_PID:-unset}" >&2
    print_diagnostic_file "Valid configuration check" "${TEMP_ROOT}/valid-check.stderr"
    print_diagnostic_file "Invalid configuration check" "${TEMP_ROOT}/invalid-check.stderr"
    print_diagnostic_file "Mihomo runtime" "${TEMP_ROOT}/runtime.stderr"
  fi

  if [[ -n "${TEMP_ROOT}" ]]; then
    case "${TEMP_ROOT}" in
      "${TEMP_BASE}"/vela-real-core.*)
        /bin/rm -rf "${TEMP_ROOT}" || cleanup_failed=1
        ;;
      *)
        printf 'error: refused to remove unexpected temporary path %s\n' "${TEMP_ROOT}" >&2
        cleanup_failed=1
        ;;
    esac
  fi
  if [[ "${status}" == "0" && "${cleanup_failed}" != "0" ]]; then
    status=1
  fi
  return "${status}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

sanitize_clash_environment() {
  local key
  while IFS='=' read -r key _; do
    if [[ "${key}" == CLASH_* ]]; then
      unset "${key}"
    fi
  done < <(/usr/bin/env)

  if /usr/bin/env | /usr/bin/grep -q '^CLASH_'; then
    fail "A CLASH_* environment variable survived sanitization"
  fi
}

allocate_loopback_port() {
  local candidate
  for _ in {1..200}; do
    candidate="$(/usr/bin/jot -r 1 20000 59999)"
    if [[ "${candidate}" == "${MIXED_PORT:-}" ]]; then
      continue
    fi
    if ! /usr/bin/nc -z -G 1 127.0.0.1 "${candidate}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

assert_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/stat -f '%Lp' "${path}")"
  [[ "${actual}" == "${expected}" ]] ||
    fail "Unexpected permissions for ${path}: expected ${expected}, got ${actual}"
}

json_value() {
  local path="$1"
  local key_path="$2"
  /usr/bin/plutil -extract "${key_path}" raw -o - "${path}"
}

fetch_endpoint() {
  local endpoint="$1"
  local output="$2"
  /usr/bin/curl \
    --config "${TEMP_ROOT}/curl.conf" \
    --fail \
    --output "${output}" \
    "http://127.0.0.1:${CONTROLLER_PORT}${endpoint}"
}

wait_for_controller() {
  local response="${TEMP_ROOT}/version.json"
  for _ in {1..100}; do
    if ! /bin/kill -0 "${CORE_PID}" 2>/dev/null; then
      fail "Mihomo exited before its Controller became ready"
    fi
    if fetch_endpoint "/version" "${response}" 2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
  fail "Timed out waiting for the loopback Controller"
}

wait_for_provider() {
  local response="${TEMP_ROOT}/providers.json"
  for _ in {1..50}; do
    if fetch_endpoint "/providers/proxies" "${response}" 2>/dev/null &&
      [[ "$(json_value "${response}" "providers.${PROVIDER_NAME}.proxies.0.name" 2>/dev/null || true)" == "${CORE_NAME}" ]]
    then
      return 0
    fi
    /bin/sleep 0.1
  done
  fail "Local file proxy-provider did not appear in the Controller response"
}

write_configuration() {
  local output="$1"
  local generation_rule="$2"
  /usr/bin/printf '%s\n' \
    "mixed-port: ${MIXED_PORT}" \
    'allow-lan: false' \
    'bind-address: 127.0.0.1' \
    'mode: rule' \
    'log-level: warning' \
    'ipv6: false' \
    "external-controller: 127.0.0.1:${CONTROLLER_PORT}" \
    "secret: \"${SECRET}\"" \
    'proxy-providers:' \
    "  ${PROVIDER_NAME}:" \
    '    type: file' \
    "    path: ./providers/${PROVIDER_NAME}.yaml" \
    '    health-check:' \
    '      enable: false' \
    'rule-providers:' \
    "  ${RULE_PROVIDER_NAME}:" \
    '    type: file' \
    '    behavior: classical' \
    '    format: yaml' \
    "    path: ./providers/${RULE_PROVIDER_NAME}.yaml" \
    'proxy-groups:' \
    '  - name: Proxy' \
    '    type: select' \
    '    proxies:' \
    '      - DIRECT' \
    '    use:' \
    "      - ${PROVIDER_NAME}" \
    'rules:' \
    "  - DOMAIN-SUFFIX,${generation_rule},Proxy" \
    "  - RULE-SET,${RULE_PROVIDER_NAME},DIRECT" \
    '  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve' \
    '  - MATCH,Proxy' \
    > "${output}"
  /bin/chmod 0600 "${output}"
}

start_core() {
  "${BINARY}" -d "${VALID_HOME}" -f "${VALID_CONFIG}" \
    > "${TEMP_ROOT}/runtime.stdout" \
    2> "${TEMP_ROOT}/runtime.stderr" &
  CORE_PID=$!
  CORE_START_IDENTITY="$(/bin/ps -p "${CORE_PID}" -o lstart= 2>/dev/null || true)"
  [[ -n "${CORE_START_IDENTITY}" ]] || fail "Could not record the started Mihomo process identity"
  owned_core_is_running || fail "Started Mihomo command identity did not match the isolated test process"
  wait_for_controller
  wait_for_provider
}

stop_core() {
  local recorded_pid="${CORE_PID}"
  terminate_owned_core || fail "Refused to stop unowned or PID-reused process ${recorded_pid}"
  if /bin/kill -0 "${recorded_pid}" 2>/dev/null; then
    fail "Recorded Mihomo PID still exists after wait"
  fi
  for _ in {1..100}; do
    if ! /usr/bin/nc -z -G 1 127.0.0.1 "${CONTROLLER_PORT}" >/dev/null 2>&1 &&
      ! /usr/bin/nc -z -G 1 127.0.0.1 "${MIXED_PORT}" >/dev/null 2>&1
    then
      return 0
    fi
    /bin/sleep 0.05
  done
  fail "A test-owned Controller or mixed port remained open after PID ${recorded_pid} exited"
}

[[ "$#" == "0" ]] || fail "Usage: $0"
[[ -f "${BINARY}" && ! -L "${BINARY}" ]] || fail "Missing regular Vendor Mihomo binary"
[[ -x "${BINARY}" ]] || fail "Vendor Mihomo binary is not executable"
[[ -f "${CONTROLLER_GATE}" && ! -L "${CONTROLLER_GATE}" ]] || fail "Missing Controller integration probe"
[[ "$(/usr/bin/lipo -archs "${BINARY}" 2>/dev/null || true)" == "arm64" ]] ||
  fail "Vendor Mihomo binary is not thin arm64"
/usr/bin/python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
  "${CONTROLLER_GATE}" || fail "Controller integration probe has invalid Python syntax"

sanitize_clash_environment

TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
TEMP_ROOT="$(/usr/bin/mktemp -d "${TEMP_BASE}/vela-real-core.XXXXXX")"
/bin/chmod 0700 "${TEMP_ROOT}"
VALID_HOME="${TEMP_ROOT}/valid-home"
INVALID_HOME="${TEMP_ROOT}/invalid-home"
PACK_V1_HOME="${TEMP_ROOT}/pack-v1-home"
PACK_V2_HOME="${TEMP_ROOT}/pack-v2-home"
PROVIDER_DIR="${VALID_HOME}/providers"
/bin/mkdir -m 0700 \
  "${VALID_HOME}" \
  "${INVALID_HOME}" \
  "${PACK_V1_HOME}" \
  "${PACK_V2_HOME}" \
  "${PROVIDER_DIR}"

MIXED_PORT="$(allocate_loopback_port)" || fail "Could not allocate a loopback mixed port"
CONTROLLER_PORT="$(allocate_loopback_port)" || fail "Could not allocate a loopback Controller port"
SECRET="$(/usr/bin/uuidgen | /usr/bin/tr -d '-')"

VALID_CONFIG="${TEMP_ROOT}/valid.yaml"
# Mihomo intentionally constrains Controller reload paths to its home.  Keep
# the candidate inside this test's isolated home instead of weakening that
# boundary with a force reload.
HOT_CONFIG="${VALID_HOME}/hot.yaml"
INVALID_CONFIG="${TEMP_ROOT}/invalid.yaml"
PROVIDER_CONFIG="${PROVIDER_DIR}/${PROVIDER_NAME}.yaml"
RULE_PROVIDER_CONFIG="${PROVIDER_DIR}/${RULE_PROVIDER_NAME}.yaml"
SECRET_FILE="${TEMP_ROOT}/controller.secret"

write_configuration "${VALID_CONFIG}" "${INITIAL_RULE}"
write_configuration "${HOT_CONFIG}" "${HOT_RULE}"

/usr/bin/printf '%s\n' \
  'proxies:' \
  "  - name: ${CORE_NAME}" \
  '    type: direct' \
  > "${PROVIDER_CONFIG}"

/usr/bin/printf '%s\n' \
  'payload:' \
  '  - DOMAIN-SUFFIX,provider-fixture.test' \
  > "${RULE_PROVIDER_CONFIG}"

/usr/bin/printf '%s' "${SECRET}" > "${SECRET_FILE}"

/usr/bin/printf '%s\n' 'mixed-port: [' > "${INVALID_CONFIG}"
/usr/bin/printf '%s\n' \
  'silent' \
  'show-error' \
  'connect-timeout = 1' \
  'max-time = 2' \
  "header = \"Authorization: Bearer ${SECRET}\"" \
  > "${TEMP_ROOT}/curl.conf"

/bin/chmod 0600 \
  "${VALID_CONFIG}" \
  "${HOT_CONFIG}" \
  "${INVALID_CONFIG}" \
  "${PROVIDER_CONFIG}" \
  "${RULE_PROVIDER_CONFIG}" \
  "${SECRET_FILE}" \
  "${TEMP_ROOT}/curl.conf"
assert_mode "${TEMP_ROOT}" 700
assert_mode "${VALID_HOME}" 700
assert_mode "${INVALID_HOME}" 700
assert_mode "${PROVIDER_DIR}" 700
assert_mode "${VALID_CONFIG}" 600
assert_mode "${HOT_CONFIG}" 600
assert_mode "${INVALID_CONFIG}" 600
assert_mode "${PROVIDER_CONFIG}" 600
assert_mode "${RULE_PROVIDER_CONFIG}" 600
assert_mode "${SECRET_FILE}" 600

VERSION_OUTPUT="$("${BINARY}" -v 2>&1)" || fail "mihomo -v failed"
FIRST_VERSION_LINE="$(printf '%s\n' "${VERSION_OUTPUT}" | /usr/bin/awk 'NF { print; exit }')"
[[ "${FIRST_VERSION_LINE}" =~ ^Mihomo[[:space:]]Meta[[:space:]]v1\.19\.29[[:space:]]darwin[[:space:]]arm64([[:space:]].*)?$ ]] ||
  fail "Unexpected mihomo -v output: ${VERSION_OUTPUT}"

"${BINARY}" -t -d "${VALID_HOME}" -f "${VALID_CONFIG}" \
  > "${TEMP_ROOT}/valid-check.stdout" \
  2> "${TEMP_ROOT}/valid-check.stderr" ||
  fail "Valid configuration was rejected"

"${BINARY}" -t -d "${PACK_V1_HOME}" -f "${PACK_FIXTURES}/valid-subscription.yaml" \
  > "${TEMP_ROOT}/pack-v1-check.stdout" \
  2> "${TEMP_ROOT}/pack-v1-check.stderr" ||
  fail "Pack valid-subscription.yaml was rejected"

"${BINARY}" -t -d "${PACK_V2_HOME}" -f "${PACK_FIXTURES}/valid-subscription-v2.yaml" \
  > "${TEMP_ROOT}/pack-v2-check.stdout" \
  2> "${TEMP_ROOT}/pack-v2-check.stderr" ||
  fail "Pack valid-subscription-v2.yaml was rejected"

if "${BINARY}" -t -d "${INVALID_HOME}" -f "${INVALID_CONFIG}" \
  > "${TEMP_ROOT}/invalid-check.stdout" \
  2> "${TEMP_ROOT}/invalid-check.stderr"
then
  fail "Invalid configuration was unexpectedly accepted"
fi

start_core

fetch_endpoint "/configs" "${TEMP_ROOT}/configs.json"
fetch_endpoint "/proxies" "${TEMP_ROOT}/proxies.json"
fetch_endpoint "/providers/proxies" "${TEMP_ROOT}/providers.json"

API_VERSION="$(json_value "${TEMP_ROOT}/version.json" version)"
[[ "${API_VERSION}" =~ ^v?1\.19\.29$ ]] || fail "Unexpected /version response: ${API_VERSION}"
[[ "$(json_value "${TEMP_ROOT}/configs.json" mixed-port)" == "${MIXED_PORT}" ]] ||
  fail "/configs did not report the configured mixed port"
[[ "$(json_value "${TEMP_ROOT}/proxies.json" proxies.Proxy.type)" == "Selector" ]] ||
  fail "/proxies did not include the configured Selector"
[[ "$(json_value "${TEMP_ROOT}/providers.json" "providers.${PROVIDER_NAME}.proxies.0.name")" == "${CORE_NAME}" ]] ||
  fail "/providers/proxies did not include the local provider node"

/usr/bin/python3 "${CONTROLLER_GATE}" \
  --controller-port "${CONTROLLER_PORT}" \
  --mixed-port "${MIXED_PORT}" \
  --secret-file "${SECRET_FILE}" \
  --hot-config "${HOT_CONFIG}" \
  --proxy-provider "${PROVIDER_NAME}" \
  --rule-provider "${RULE_PROVIDER_NAME}" \
  --initial-rule "${INITIAL_RULE}" \
  --hot-rule "${HOT_RULE}" ||
  fail "Controller API integration probe failed"

stop_core

for _ in 2 3; do
  MIXED_PORT="$(allocate_loopback_port)" || fail "Could not allocate a loopback mixed port"
  CONTROLLER_PORT="$(allocate_loopback_port)" || fail "Could not allocate a loopback Controller port"
  write_configuration "${VALID_CONFIG}" "${INITIAL_RULE}"
  start_core
  stop_core
done

printf 'Real Mihomo integration gate passed:\n'
printf '  Version:                    %s\n' "${FIRST_VERSION_LINE}"
printf '  Generated configuration:    accepted\n'
printf '  Pack valid fixtures:         v1 and v2 accepted\n'
printf '  Invalid configuration:      rejected\n'
printf '  Controller:                 127.0.0.1:%s\n' "${CONTROLLER_PORT}"
printf '  Mixed port:                 127.0.0.1:%s\n' "${MIXED_PORT}"
printf '  /version:                   %s\n' "${API_VERSION}"
printf '  /configs:                   passed\n'
printf '  /proxies:                   passed\n'
printf '  /providers/proxies:         %s/%s\n' "${PROVIDER_NAME}" "${CORE_NAME}"
printf '  Full Controller API gate:   passed\n'
printf '  Start/stop cycles:           3\n'
printf '  SIGTERM and orphan check:   passed (PIDs %s reaped)\n' "${CYCLE_PIDS}"
printf '  Temporary test directory:   removed on exit\n'
printf '  Existing Mihomo processes:  never enumerated, matched, or signalled\n'
