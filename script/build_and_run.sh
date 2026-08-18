#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Vela"
BUNDLE_ID="dev.yilin.Vela"
CONFIGURATION="${VELA_CONFIGURATION:-Debug}"
VERIFY_SECONDS="${VELA_VERIFY_SECONDS:-5}"
CLEAN_BUILD="${VELA_CLEAN_BUILD:-0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STANDARD_DERIVED_DATA_PATH="$ROOT_DIR/.build/DerivedData"
SMOKE_DERIVED_DATA_PATH="$ROOT_DIR/.build/StartupSmokeDerivedData"
BUNDLE_VERIFIER="$ROOT_DIR/Scripts/Mihomo/verify-app-bundle.sh"

case "$MODE" in
  --verify|verify)
    DERIVED_DATA_PATH="$SMOKE_DERIVED_DATA_PATH"
    ;;
  *)
    DERIVED_DATA_PATH="$STANDARD_DERIVED_DATA_PATH"
    ;;
esac

APP_BUNDLE=""
APP_BINARY=""
MIHOMO_HELPER=""
APP_PID=""
LAUNCH_EPOCH="0"
LAUNCH_BASELINE_PIDS=""
SMOKE_ROOT=""
CANONICAL_TMPDIR=""

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    usage
    exit 2
    ;;
esac

if ! [[ "$VERIFY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "VELA_VERIFY_SECONDS must be a non-negative number" >&2
  exit 2
fi

if [[ "$CLEAN_BUILD" != "0" && "$CLEAN_BUILD" != "1" ]]; then
  echo "VELA_CLEAN_BUILD must be 0 or 1" >&2
  exit 2
fi

XCODEBUILD_ARGS=(
  -project "$ROOT_DIR/Vela.xcodeproj"
  -scheme "$APP_NAME"
  -configuration "$CONFIGURATION"
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$DERIVED_DATA_PATH"
  CODE_SIGNING_ALLOWED=YES
  ENABLE_CODE_COVERAGE=NO
)

build_setting() {
  local settings="$1"
  local key="$2"

  printf '%s\n' "$settings" | /usr/bin/awk -v target="$APP_NAME" -v key="$key" '
    $0 == "Build settings for action build and target " target ":" {
      in_target = 1
      next
    }
    /^Build settings for action / {
      in_target = 0
    }
    in_target {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      prefix = key " = "
      if (!found && index(line, prefix) == 1) {
        print substr(line, length(prefix) + 1)
        found = 1
      }
    }
  '
}

resolve_product_paths() {
  local settings target_build_dir wrapper_name executable_path

  settings="$(xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildSettings)"
  target_build_dir="$(build_setting "$settings" TARGET_BUILD_DIR)"
  wrapper_name="$(build_setting "$settings" WRAPPER_NAME)"
  executable_path="$(build_setting "$settings" EXECUTABLE_PATH)"

  if [[ -z "$target_build_dir" || -z "$wrapper_name" || -z "$executable_path" ]]; then
    echo "Could not resolve the $APP_NAME product from Xcode build settings" >&2
    return 1
  fi

  APP_BUNDLE="$target_build_dir/$wrapper_name"
  APP_BINARY="$target_build_dir/$executable_path"
  MIHOMO_HELPER="$APP_BUNDLE/Contents/Helpers/mihomo"
}

pid_matches_binary() {
  local pid="$1"
  local command_line line

  kill -0 "$pid" >/dev/null 2>&1 || return 1

  command_line="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  command_line="${command_line#"${command_line%%[![:space:]]*}"}"
  command_line="${command_line%"${command_line##*[![:space:]]}"}"
  if [[ "$command_line" == "$APP_BINARY" || "$command_line" == "$APP_BINARY "* ]]; then
    return 0
  fi

  # lsof checks the process text vnode and avoids relying solely on argv.
  if [[ -x /usr/sbin/lsof ]]; then
    while IFS= read -r line; do
      [[ "$line" == "n$APP_BINARY" ]] && return 0
    done < <(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null || true)
  fi

  return 1
}

matching_app_pids() {
  local pid

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if pid_matches_binary "$pid"; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)
}

pid_was_present_before_launch() {
  local wanted_pid="$1"
  local pid

  while IFS= read -r pid; do
    [[ "$pid" == "$wanted_pid" ]] && return 0
  done <<< "$LAUNCH_BASELINE_PIDS"

  return 1
}

warn_about_other_named_processes() {
  local pid command_line

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    pid_matches_binary "$pid" && continue

    command_line="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
    command_line="${command_line#"${command_line%%[![:space:]]*}"}"
    command_line="${command_line%"${command_line##*[![:space:]]}"}"
    echo "Leaving same-name $APP_NAME PID $pid untouched (${command_line:-executable path unavailable})" >&2
  done < <(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)
}

stop_running_app() {
  local pids pid remaining

  pids="$(matching_app_pids)"
  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    pid_matches_binary "$pid" || continue
    echo "Stopping $APP_NAME PID $pid ($APP_BINARY)"
    kill -TERM "$pid"
  done <<< "$pids"

  for _ in {1..50}; do
    remaining="$(matching_app_pids)"
    [[ -z "$remaining" ]] && return 0
    sleep 0.1
  done

  echo "$APP_NAME did not terminate cleanly; matching PID(s):" >&2
  matching_app_pids >&2
  return 1
}

build_app() {
  if [[ "$CLEAN_BUILD" == "1" ]]; then
    xcodebuild "${XCODEBUILD_ARGS[@]}" clean build
  else
    xcodebuild "${XCODEBUILD_ARGS[@]}" build
  fi
}

validate_product() {
  local actual_bundle_id

  if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
    echo "Built app is incomplete: $APP_BUNDLE" >&2
    return 1
  fi

  if [[ ! -x "$MIHOMO_HELPER" ]]; then
    echo "Bundled Mihomo helper is missing or not executable: $MIHOMO_HELPER" >&2
    return 1
  fi

  if [[ ! -f "$BUNDLE_VERIFIER" ]]; then
    echo "Bundle verifier is missing: $BUNDLE_VERIFIER" >&2
    return 1
  fi

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$actual_bundle_id" != "$BUNDLE_ID" ]]; then
    echo "Unexpected bundle identifier: ${actual_bundle_id:-missing}" >&2
    return 1
  fi

  # This project gate checks helper provenance/version/architecture, bundle
  # layout and containment, and strict signatures for both executables.
  /bin/bash "$BUNDLE_VERIFIER" "$APP_BUNDLE"
}

recent_matching_crash_report() {
  local pid="${1:-}"
  local candidate latest="" crash_epoch
  local redacted_path escaped_path escaped_redacted_path

  redacted_path="$APP_BINARY"
  case "$redacted_path" in
    "$HOME"/*)
      redacted_path="/Users/USER/${redacted_path#"$HOME"/}"
      ;;
  esac
  escaped_path="$(printf '%s' "$APP_BINARY" | /usr/bin/sed 's|/|\\/|g')"
  escaped_redacted_path="$(printf '%s' "$redacted_path" | /usr/bin/sed 's|/|\\/|g')"

  for candidate in "$HOME/Library/Logs/DiagnosticReports/$APP_NAME-"*.ips; do
    [[ -f "$candidate" ]] || continue
    crash_epoch="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    [[ "$crash_epoch" =~ ^[0-9]+$ ]] || continue
    (( crash_epoch + 5 >= LAUNCH_EPOCH )) || continue

    if ! /usr/bin/grep -Fq "\"procPath\" : \"$escaped_path\"" "$candidate" &&
      ! /usr/bin/grep -Fq "\"procPath\" : \"$escaped_redacted_path\"" "$candidate"; then
      continue
    fi
    if [[ -n "$pid" ]] && ! /usr/bin/grep -Fq "\"pid\" : $pid," "$candidate"; then
      continue
    fi

    if [[ -z "$latest" || "$candidate" -nt "$latest" ]]; then
      latest="$candidate"
    fi
  done

  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

print_launch_diagnostics() {
  local pid="${1:-}"
  local predicate crash_report

  echo >&2
  echo "Recent $APP_NAME launch logs:" >&2
  if [[ -n "$pid" ]]; then
    predicate="processID == $pid"
    /usr/bin/log show --last 2m --info --debug --style compact \
      --predicate "$predicate" 2>&1 | /usr/bin/tail -n 120 >&2 || true
  else
    echo "No exact launch PID was discovered; skipping the process log query" >&2
  fi

  crash_report="$(recent_matching_crash_report "$pid" || true)"
  if [[ -n "$crash_report" ]]; then
    echo "Matching crash report: $crash_report" >&2
  else
    echo "No recent crash report matched this binary${pid:+ and PID $pid}" >&2
  fi
}

discover_launched_pid() {
  local pid

  APP_PID=""
  for _ in {1..100}; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      pid_was_present_before_launch "$pid" && continue
      APP_PID="$pid"
      return 0
    done < <(matching_app_pids)
    sleep 0.1
  done

  return 1
}

launch_and_verify() {
  LAUNCH_EPOCH="$(date +%s)"
  LAUNCH_BASELINE_PIDS="$(matching_app_pids)"

  if ! /usr/bin/open -n "$APP_BUNDLE"; then
    echo "Failed to ask LaunchServices to open $APP_BUNDLE" >&2
    print_launch_diagnostics
    return 1
  fi

  if ! discover_launched_pid; then
    echo "$APP_NAME did not start from the expected binary: $APP_BINARY" >&2
    print_launch_diagnostics
    return 1
  fi

  echo "Launched $APP_NAME PID $APP_PID from $APP_BINARY"
  sleep "$VERIFY_SECONDS"

  if ! pid_matches_binary "$APP_PID"; then
    echo "$APP_NAME PID $APP_PID exited during the ${VERIFY_SECONDS}s verification window" >&2
    print_launch_diagnostics "$APP_PID"
    return 1
  fi

  echo "Verified $APP_NAME PID $APP_PID remained alive for ${VERIFY_SECONDS}s"
}

refuse_preexisting_smoke_process() {
  local pids

  pids="$(matching_app_pids)"
  [[ -z "$pids" ]] && return 0

  echo "Refusing startup smoke test because its exact product is already running:" >&2
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && echo "  PID $pid ($APP_BINARY)" >&2
  done <<< "$pids"
  return 1
}

create_smoke_root() {
  local tmpdir old_umask created_root permissions

  tmpdir="${TMPDIR:-}"
  if [[ -z "$tmpdir" ]]; then
    tmpdir="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  fi
  if [[ -z "$tmpdir" || ! -d "$tmpdir" ]]; then
    echo "Could not resolve TMPDIR for the startup smoke test" >&2
    return 1
  fi

  CANONICAL_TMPDIR="$(cd "$tmpdir" && pwd -P)"
  old_umask="$(umask)"
  umask 077
  if ! created_root="$(/usr/bin/mktemp -d "$CANONICAL_TMPDIR/VelaStartupSmoke.XXXXXX")"; then
    umask "$old_umask"
    echo "Could not create the startup smoke root under $CANONICAL_TMPDIR" >&2
    return 1
  fi
  umask "$old_umask"

  SMOKE_ROOT="$(cd "$created_root" && pwd -P)"
  /bin/chmod 0700 "$SMOKE_ROOT"
  permissions="$(/usr/bin/stat -f '%Lp' "$SMOKE_ROOT")"
  if [[ "$permissions" != "700" ]]; then
    echo "Startup smoke root permissions are $permissions instead of 700" >&2
    return 1
  fi
}

cleanup_smoke() {
  local status="$1"

  trap - EXIT INT TERM HUP

  if [[ -n "$APP_PID" ]] && pid_matches_binary "$APP_PID"; then
    kill -TERM "$APP_PID" >/dev/null 2>&1 || true
    for _ in {1..50}; do
      pid_matches_binary "$APP_PID" || break
      sleep 0.1
    done
    if pid_matches_binary "$APP_PID"; then
      echo "Startup smoke PID $APP_PID did not terminate; sending SIGKILL" >&2
      kill -KILL "$APP_PID" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        pid_matches_binary "$APP_PID" || break
        sleep 0.1
      done
      if pid_matches_binary "$APP_PID"; then
        echo "Startup smoke PID $APP_PID is still present after SIGKILL" >&2
        status=1
      fi
    fi
  fi

  if [[ -n "$SMOKE_ROOT" ]]; then
    case "$SMOKE_ROOT" in
      "$CANONICAL_TMPDIR"/VelaStartupSmoke.*)
        if [[ -d "$SMOKE_ROOT" && ! -L "$SMOKE_ROOT" ]]; then
          /bin/rm -rf "$SMOKE_ROOT"
        fi
        ;;
      *)
        echo "Refusing to remove unexpected startup smoke root: $SMOKE_ROOT" >&2
        status=1
        ;;
    esac
  fi

  exit "$status"
}

smoke_directories_ready() {
  local directory

  for directory in profiles runtime logs metadata mihomo; do
    [[ -d "$SMOKE_ROOT/$directory" && ! -L "$SMOKE_ROOT/$directory" ]] || return 1
  done
}

print_missing_smoke_directories() {
  local directory

  echo "Startup smoke directories were not ready under $SMOKE_ROOT:" >&2
  for directory in profiles runtime logs metadata mihomo; do
    if [[ ! -d "$SMOKE_ROOT/$directory" || -L "$SMOKE_ROOT/$directory" ]]; then
      echo "  missing or not a regular directory: $directory" >&2
    fi
  done
}

wait_for_smoke_readiness() {
  for _ in {1..150}; do
    if ! pid_matches_binary "$APP_PID"; then
      echo "$APP_NAME PID $APP_PID exited before startup storage was ready" >&2
      print_launch_diagnostics "$APP_PID"
      return 1
    fi
    smoke_directories_ready && return 0
    sleep 0.1
  done

  print_missing_smoke_directories
  print_launch_diagnostics "$APP_PID"
  return 1
}

dwell_on_smoke_process() {
  local iteration iteration_count

  iteration_count="$(/usr/bin/awk -v seconds="$VERIFY_SECONDS" '
    BEGIN {
      count = int((seconds * 10) + 0.999999)
      print (count < 0 ? 0 : count)
    }
  ')"

  for ((iteration = 0; iteration < iteration_count; iteration++)); do
    sleep 0.1
    if ! pid_matches_binary "$APP_PID"; then
      echo "$APP_NAME PID $APP_PID exited during the ${VERIFY_SECONDS}s startup smoke dwell" >&2
      print_launch_diagnostics "$APP_PID"
      return 1
    fi
  done
}

run_startup_smoke() {
  trap 'cleanup_smoke $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  create_smoke_root

  LAUNCH_EPOCH="$(date +%s)"
  LAUNCH_BASELINE_PIDS="$(matching_app_pids)"
  if [[ -n "$LAUNCH_BASELINE_PIDS" ]]; then
    echo "An exact smoke product process appeared before launch" >&2
    return 1
  fi

  if ! /usr/bin/open -n \
    --env "VELA_STARTUP_SMOKE_ROOT=$SMOKE_ROOT" \
    "$APP_BUNDLE" \
    --args --vela-startup-smoke -ApplePersistenceIgnoreState YES; then
    echo "Failed to ask LaunchServices to start the isolated smoke app" >&2
    print_launch_diagnostics
    return 1
  fi

  if ! discover_launched_pid; then
    echo "$APP_NAME did not start from the smoke binary: $APP_BINARY" >&2
    print_launch_diagnostics
    return 1
  fi

  echo "Launched isolated $APP_NAME PID $APP_PID from $APP_BINARY"
  wait_for_smoke_readiness
  echo "Startup smoke storage is ready under $SMOKE_ROOT"
  dwell_on_smoke_process
  echo "Verified isolated $APP_NAME PID $APP_PID remained alive for ${VERIFY_SECONDS}s"
}

if [[ "$MODE" == "--verify" || "$MODE" == "verify" ]]; then
  resolve_product_paths
  refuse_preexisting_smoke_process
  build_app
  resolve_product_paths
  validate_product
  refuse_preexisting_smoke_process
  run_startup_smoke
  exit 0
fi

resolve_product_paths
warn_about_other_named_processes
stop_running_app
build_app
resolve_product_paths
validate_product

case "$MODE" in
  run)
    launch_and_verify
    ;;
  --debug|debug)
    exec /usr/bin/xcrun lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    launch_and_verify
    exec /usr/bin/log stream --info --style compact \
      --predicate "processID == $APP_PID"
    ;;
  --telemetry|telemetry)
    launch_and_verify
    exec /usr/bin/log stream --info --style compact \
      --predicate "processID == $APP_PID AND subsystem == \"$BUNDLE_ID\""
    ;;
esac
