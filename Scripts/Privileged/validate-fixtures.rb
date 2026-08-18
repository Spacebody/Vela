#!/usr/bin/ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

class FixtureError < StandardError; end

def require_condition(condition, message)
  raise FixtureError, message unless condition
end

def read_regular_file(path, maximum_size: 1_048_576)
  stat = path.lstat
  require_condition(stat.file?, "Fixture is not a regular file: #{path}")
  require_condition(!stat.symlink?, "Fixture must not be a symlink: #{path}")
  require_condition(stat.size.positive?, "Fixture is empty: #{path}")
  require_condition(stat.size <= maximum_size, "Fixture is too large: #{path}")
  path.binread
rescue Errno::ENOENT
  raise FixtureError, "Missing fixture: #{path}"
end

def load_json(path)
  value = JSON.parse(read_regular_file(path), create_additions: false)
  require_condition(value.is_a?(Hash), "JSON fixture root must be an object: #{path}")
  value
rescue JSON::ParserError => error
  raise FixtureError, "Invalid JSON fixture #{path}: #{error.message}"
end

def load_yaml(path)
  value = YAML.safe_load(
    read_regular_file(path),
    permitted_classes: [],
    permitted_symbols: [],
    aliases: false
  )
  require_condition(value.is_a?(Hash), "YAML fixture root must be a mapping: #{path}")
  value
rescue Psych::Exception => error
  raise FixtureError, "Invalid or unsafe YAML fixture #{path}: #{error.message}"
end

def exact_keys(value, expected, label)
  actual = value.keys.sort
  wanted = expected.sort
  require_condition(actual == wanted, "#{label} keys changed: expected #{wanted}, got #{actual}")
end

def uuid?(value)
  value.is_a?(String) && value.match?(/\A[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\z/)
end

def safe_provider_path?(value)
  value.is_a?(String) && value.match?(%r{\A\./providers/[A-Za-z0-9._-]+\.ya?ml\z})
end

begin
fixtures = ARGV.first
raise FixtureError, "Usage: #{$PROGRAM_NAME} /path/to/fixtures" unless ARGV.length == 1

root = Pathname.new(fixtures).expand_path
require_condition(root.directory?, "Fixture directory not found: #{root}")
require_condition(!root.symlink?, "Fixture directory must not be a symlink: #{root}")

expected_names = %w[
  file-provider-path-traversal.yaml
  file-provider-safe.yaml
  helper-handshake-request.json
  helper-handshake-response.json
  malicious-controller.yaml
  resource-path-traversal.json
  root-journal-stale.json
  tun-default.yaml
].sort

actual_names = root.children.map { |path| path.basename.to_s }.sort
require_condition(actual_names == expected_names,
                  "Fixture inventory changed: expected #{expected_names}, got #{actual_names}")

request = load_json(root / "helper-handshake-request.json")
exact_keys(request, %w[
  schemaVersion requestID clientProtocolMinimum clientProtocolMaximum clientVersion clientBuild
], "handshake request")
require_condition(request["schemaVersion"] == 1, "Handshake request schema must be 1")
require_condition(uuid?(request["requestID"]), "Handshake request ID is not a UUID")
require_condition(request["clientProtocolMinimum"] == 1, "Client minimum protocol must be 1")
require_condition(request["clientProtocolMaximum"] == 1, "Client maximum protocol must be 1")

response = load_json(root / "helper-handshake-response.json")
exact_keys(response, %w[
  schemaVersion requestID helperProtocolMinimum helperProtocolMaximum helperVersion helperBuild
  daemonUID mihomoVersion mihomoPlatform mihomoArchitecture rootDataSchemaVersion state
], "handshake response")
require_condition(response["schemaVersion"] == 1, "Handshake response schema must be 1")
require_condition(response["requestID"] == request["requestID"], "Handshake request IDs do not match")
require_condition(response["helperProtocolMinimum"] == 1, "Helper minimum protocol must be 1")
require_condition(response["helperProtocolMaximum"] == 1, "Helper maximum protocol must be 1")
require_condition(response["daemonUID"] == 0, "Helper fixture must report root UID 0")
require_condition(response["mihomoVersion"] == "v1.19.28", "Mihomo fixture version drifted")
require_condition(response["mihomoPlatform"] == "darwin", "Mihomo fixture platform drifted")
require_condition(response["mihomoArchitecture"] == "arm64", "Mihomo fixture architecture drifted")
require_condition(response["state"] == "stopped", "Handshake fixture must start stopped")

resource = load_json(root / "resource-path-traversal.json")
exact_keys(resource, %w[
  schemaVersion transactionID logicalID relativeDestination expectedSize expectedSHA256 kind
], "resource traversal")
require_condition(resource["schemaVersion"] == 1, "Resource fixture schema must be 1")
require_condition(uuid?(resource["transactionID"]), "Resource transaction ID is not a UUID")
require_condition(resource["relativeDestination"].start_with?("../"),
                  "Resource traversal fixture no longer traverses")
require_condition(resource["expectedSHA256"].match?(/\A[0-9a-f]{64}\z/),
                  "Resource SHA-256 fixture is malformed")

journal = load_json(root / "root-journal-stale.json")
exact_keys(journal, %w[
  schemaVersion desiredState instanceID pid configurationSHA256 tunInterface ownerUID lastCleanShutdown
], "stale journal")
require_condition(journal["schemaVersion"] == 1, "Journal fixture schema must be 1")
require_condition(uuid?(journal["instanceID"]), "Journal instance ID is not a UUID")
require_condition(journal["desiredState"] == "running", "Stale journal must request running")
require_condition(journal["pid"].is_a?(Integer) && journal["pid"].positive?, "Stale PID is invalid")
require_condition(journal["lastCleanShutdown"] == false, "Stale journal must be unclean")

safe = load_yaml(root / "file-provider-safe.yaml")
safe_proxy_path = safe.dig("proxy-providers", "local-proxies", "path")
safe_rule_path = safe.dig("rule-providers", "local-rules", "path")
require_condition(safe_provider_path?(safe_proxy_path), "Safe proxy-provider path drifted")
require_condition(safe_provider_path?(safe_rule_path), "Safe rule-provider path drifted")

traversal = load_yaml(root / "file-provider-path-traversal.yaml")
traversal_path = traversal.dig("proxy-providers", "bad", "path")
require_condition(traversal_path.is_a?(String) && traversal_path.include?("../"),
                  "Provider traversal fixture no longer traverses")

malicious = load_yaml(root / "malicious-controller.yaml")
require_condition(malicious["allow-lan"] == true, "Malicious fixture must expose LAN")
require_condition(malicious["bind-address"] == "*", "Malicious bind address drifted")
require_condition(malicious["external-controller"] == "0.0.0.0:9090",
                  "Malicious Controller fixture drifted")
require_condition(malicious["secret"] == "", "Malicious Controller secret must be empty")
require_condition(malicious.key?("external-ui-url"), "Malicious fixture lacks external UI URL")
require_condition(malicious["listeners"].is_a?(Array) && !malicious["listeners"].empty?,
                  "Malicious fixture lacks arbitrary listener")

tun = load_yaml(root / "tun-default.yaml")
require_condition(tun.dig("tun", "enable") == true, "Default TUN fixture must enable TUN")
require_condition(tun.dig("tun", "stack") == "mixed", "Default TUN stack must be mixed")
require_condition(tun.dig("tun", "auto-route") == true, "Default TUN must enable auto-route")
require_condition(tun.dig("tun", "auto-detect-interface") == true,
                  "Default TUN must auto-detect interface")
require_condition(tun.dig("dns", "enable") == true, "Default TUN DNS must be enabled")

puts "Privileged fixture validation passed (#{expected_names.length} fixtures)."
puts "  Schema:       v1"
puts "  Mihomo:       v1.19.28 darwin arm64"
puts "  Safe paths:   accepted fixture shape preserved"
puts "  Attack paths: traversal and Controller exposure fixtures preserved"
rescue FixtureError => error
  warn "error: #{error.message}"
  exit 1
end
