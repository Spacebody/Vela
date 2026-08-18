#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && /bin/pwd -P)"
PROJECT_FILE="${PROJECT_ROOT}/Vela.xcodeproj/project.pbxproj"
LAUNCH_DAEMON="${PROJECT_ROOT}/Configuration/Privileged/dev.yilin.Vela.Helper.plist"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "Missing regular file: $1"
}

require_project_contract() {
  /usr/bin/grep -Fq "$1" "${PROJECT_FILE}" || fail "Missing Xcode project contract: $1"
}

[[ "$#" == "0" ]] || fail "Usage: $0"
require_regular_file "${PROJECT_FILE}"
require_regular_file "${LAUNCH_DAEMON}"
require_regular_file "${PROJECT_ROOT}/VelaHelper/main.swift"
require_regular_file "${PROJECT_ROOT}/VelaHelper/VelaHelperPowerObserver.swift"

/usr/bin/grep -Eq 'umask\(0o077\)' "${PROJECT_ROOT}/VelaHelper/main.swift" || \
  fail "Privileged Helper must set umask 077 before creating root data or Mihomo"

POWER_OBSERVER="${PROJECT_ROOT}/VelaHelper/VelaHelperPowerObserver.swift"
/usr/bin/grep -Fq 'IORegisterForSystemPower' "${POWER_OBSERVER}" || \
  fail "Privileged Helper must register directly with the root power domain"
/usr/bin/grep -Fq 'IOAllowPowerChange' "${POWER_OBSERVER}" || \
  fail "Privileged Helper must acknowledge required IOKit sleep messages"
if /usr/bin/grep -Eq 'NSWorkspace|willSleepNotification|didWakeNotification' "${POWER_OBSERVER}"; then
  fail "Privileged LaunchDaemon must not rely on per-user AppKit sleep notifications"
fi

EXPECTED_SHELL_SCRIPTS="check-tun-cleanup.sh
inspect-signing.sh
notarize-app.sh
run-privileged-integration.sh
test-static-integration.sh
validate-fixtures.sh
verify-launch-daemon.sh
verify-privileged-bundle.sh"

while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  script="${SCRIPT_DIR}/${name}"
  require_regular_file "${script}"
  [[ -x "${script}" ]] || fail "Script is not executable: ${script}"
  /bin/bash -n "${script}"
done <<< "${EXPECTED_SHELL_SCRIPTS}"

require_regular_file "${SCRIPT_DIR}/validate-fixtures.rb"
[[ -x "${SCRIPT_DIR}/validate-fixtures.rb" ]] || fail "Ruby fixture validator is not executable"
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby \
  -c "${SCRIPT_DIR}/validate-fixtures.rb" >/dev/null

"${SCRIPT_DIR}/validate-fixtures.sh"
"${SCRIPT_DIR}/verify-launch-daemon.sh" "${LAUNCH_DAEMON}"

for contract in \
  '/* VelaHelper */ = {' \
  'name = VelaHelper;' \
  'productType = "com.apple.product-type.tool";' \
  '/* VelaHelperTests */ = {' \
  '/* VelaIPC */' \
  '/* VelaPrivilegedCore */' \
  'dstPath = Contents/Library/LaunchServices;' \
  'dstPath = Contents/Library/LaunchDaemons;' \
  'VelaHelper in Embed Privileged Helper' \
  'settings = {ATTRIBUTES = (CodeSignOnCopy, ); };' \
  'PRODUCT_BUNDLE_IDENTIFIER = dev.yilin.Vela.Helper;' \
  'ENABLE_APP_SANDBOX = NO;' \
  'ENABLE_HARDENED_RUNTIME = YES;' \
  'MACOSX_DEPLOYMENT_TARGET = 15.0;' \
  'ARCHS = arm64;'
do
  require_project_contract "${contract}"
done

# Resolve the project/target configuration lists instead of accepting a matching
# setting from an unrelated target or configuration. Release signing must never
# inherit Xcode's development-only base entitlements.
/usr/bin/plutil -convert json -o - "${PROJECT_FILE}" |
  /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/ruby -rjson -e '
    project = JSON.parse(STDIN.read, create_additions: false)
    objects = project.fetch("objects")

    find_object = lambda do |isa, name|
      pair = objects.find { |_id, value| value["isa"] == isa && value["name"] == name }
      abort("error: Missing #{isa} named #{name}") unless pair
      pair.last
    end

    settings_for = lambda do |owner, configuration_name|
      list = objects.fetch(owner.fetch("buildConfigurationList"))
      configuration_id = list.fetch("buildConfigurations").find do |candidate|
        objects.fetch(candidate)["name"] == configuration_name
      end
      abort("error: Missing #{configuration_name} configuration") unless configuration_id
      objects.fetch(configuration_id).fetch("buildSettings")
    end

    project_object = objects.values.find { |value| value["isa"] == "PBXProject" }
    abort("error: Missing PBXProject") unless project_object
    project_debug = settings_for.call(project_object, "Debug")
    project_release = settings_for.call(project_object, "Release")
    app = find_object.call("PBXNativeTarget", "Vela")
    helper = find_object.call("PBXNativeTarget", "VelaHelper")
    app_debug = project_debug.merge(settings_for.call(app, "Debug"))
    app_release = project_release.merge(settings_for.call(app, "Release"))
    helper_debug = project_debug.merge(settings_for.call(helper, "Debug"))
    helper_release = project_release.merge(settings_for.call(helper, "Release"))

    release_version = app_release["MARKETING_VERSION"]
    release_build = app_release["CURRENT_PROJECT_VERSION"]
    abort("error: Vela Release marketing version must be major.minor.patch") unless
      release_version.is_a?(String) && release_version.match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)
    abort("error: Vela Release build must use YYYYMMDDNN") unless
      release_build.to_s.match?(/\A20[0-9]{8}\z/) && release_build.to_s[-2, 2] != "00"

    expected = {
      "Vela Debug marketing version" => [app_debug["MARKETING_VERSION"], release_version],
      "Vela Debug build version" => [app_debug["CURRENT_PROJECT_VERSION"], release_build],
      "Vela Release ARCHS" => [app_release["ARCHS"], "arm64"],
      "Vela Release minimum macOS" => [app_release["MACOSX_DEPLOYMENT_TARGET"], "15.0"],
      "Vela Release App Sandbox" => [app_release["ENABLE_APP_SANDBOX"], "NO"],
      "Vela Release Hardened Runtime" => [app_release["ENABLE_HARDENED_RUNTIME"], "YES"],
      "Vela Release base entitlement injection" => [app_release["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO"],
      "VelaHelper Debug marketing version" => [helper_debug["MARKETING_VERSION"], release_version],
      "VelaHelper Debug build version" => [helper_debug["CURRENT_PROJECT_VERSION"], release_build],
      "VelaHelper Release ARCHS" => [helper_release["ARCHS"], "arm64"],
      "VelaHelper Release minimum macOS" => [helper_release["MACOSX_DEPLOYMENT_TARGET"], "15.0"],
      "VelaHelper Release App Sandbox" => [helper_release["ENABLE_APP_SANDBOX"], "NO"],
      "VelaHelper Release Hardened Runtime" => [helper_release["ENABLE_HARDENED_RUNTIME"], "YES"],
      "VelaHelper Release base entitlement injection" => [helper_release["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "NO"],
      "VelaHelper Release marketing version" => [helper_release["MARKETING_VERSION"], release_version],
      "VelaHelper Release build version" => [helper_release["CURRENT_PROJECT_VERSION"], release_build]
    }
    expected.each do |label, (actual, wanted)|
      abort("error: #{label} must be #{wanted}, got #{actual.inspect}") unless actual == wanted
    end

    [
      ["VelaHelper Debug", helper_debug],
      ["VelaHelper Release", helper_release]
    ].each do |label, settings|
      runpaths = Array(settings["LD_RUNPATH_SEARCH_PATHS"])
      expected_runpath = "@executable_path/../../Frameworks"
      unless runpaths == [expected_runpath]
        abort("error: #{label} must load package frameworks only from #{expected_runpath}, got #{runpaths.inspect}")
      end
    end

    user_selected_files = app_release["ENABLE_USER_SELECTED_FILES"]
    unless user_selected_files.nil? || user_selected_files == "NO"
      abort("error: Non-sandboxed Vela Release must not request a user-selected-files sandbox entitlement")
    end
  '

/usr/bin/grep -Eq \
  'VelaHelper in Embed Privileged Helper.*CodeSignOnCopy' "${PROJECT_FILE}" || \
  fail "VelaHelper is not configured for Code Sign On Copy"
if /usr/bin/grep -Eq \
  'dev\.yilin\.Vela\.Helper\.plist in Embed LaunchDaemon.*CodeSignOnCopy' "${PROJECT_FILE}"
then
  fail "LaunchDaemon plist must not use Code Sign On Copy"
fi

if /usr/bin/grep -Eq '__[A-Z][A-Z0-9_]*__' "${LAUNCH_DAEMON}"; then
  fail "LaunchDaemon contains an unresolved placeholder"
fi

for gate in \
  'VELA_RUN_NOTARIZATION' \
  'NOTARY_PROFILE' \
  '--execute'
do
  /usr/bin/grep -Fq -- "${gate}" "${SCRIPT_DIR}/notarize-app.sh" || \
    fail "Notarization script lacks explicit gate: ${gate}"
done

for gate in \
  'VELA_RUN_PRIVILEGED_TESTS' \
  'VELA_PRIVILEGED_TESTS_CONFIRM' \
  'VelaPrivilegedIntegrationTests'
do
  /usr/bin/grep -Fq -- "${gate}" "${SCRIPT_DIR}/run-privileged-integration.sh" || \
    fail "Privileged test harness lacks explicit gate: ${gate}"
done

for script in "${SCRIPT_DIR}"/*.sh; do
  [[ -f "${script}" && ! -L "${script}" ]] || continue
  [[ "$(/usr/bin/basename "${script}")" != "test-static-integration.sh" ]] || continue
  if /usr/bin/grep -En \
    '(^|[[:space:]])sudo[[:space:]]|/usr/bin/sudo|(^|[[:space:]])launchctl[[:space:]]|/bin/launchctl|(^|[[:space:]])killall[[:space:]]|route[[:space:]].*(delete|flush)' \
    "${script}" >/dev/null
  then
    fail "Privileged script contains a forbidden destructive recovery command: ${script}"
  fi
done

printf 'Privileged static integration gate passed:\n'
printf '  Shell scripts:       8 syntax-checked\n'
printf '  Fixture contracts:   validated\n'
printf '  LaunchDaemon:        validated\n'
printf '  Xcode bundle layout: validated\n'
printf '  Release settings:    arm64, macOS 15, hardened, no base entitlement injection\n'
printf '  Bundle versions:     App and Helper semantic/build versions synchronized\n'
printf '  Sleep/wake source:   IOKit root power domain\n'
printf '  Explicit gates:      privileged tests and notarization\n'
printf '  System mutations:    none\n'
