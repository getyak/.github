#!/usr/bin/env bash
set -euo pipefail

command -v ruby >/dev/null || {
  echo "ruby is required" >&2
  exit 2
}

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"
targets_path="${CODEX_TARGETS_PATH:-$repository_root/automation/codex-targets.yml}"
task_path="${1:--}"

temporary_task=""
if [[ "$task_path" == "-" ]]; then
  temporary_task="$(mktemp "${TMPDIR:-/tmp}/codex-task.XXXXXX")"
  trap 'rm -f "$temporary_task"' EXIT
  task_path="$temporary_task"
  cat >"$task_path"
elif [[ ! -f "$task_path" ]]; then
  echo "task file not found: $task_path" >&2
  exit 2
fi

ruby - "$targets_path" "$task_path" <<'RUBY'
require "json"
require "yaml"

targets_path = ARGV.fetch(0)
task_path = ARGV.fetch(1)
document = File.read(task_path)
config = YAML.load_file(targets_path)
targets = config.fetch("targets")
errors = []

if document.bytesize > 32_768
  errors << "task envelope exceeds 32 KiB"
end

secret_patterns = {
  "private key" => /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
  "GitHub token" => /\b(?:github_pat_|gh[oprsu]_[A-Za-z0-9]{20,})/,
  "OpenAI-style key" => /\bsk-[A-Za-z0-9_-]{20,}/,
  "Slack token" => /\bxox[baprs]-[A-Za-z0-9-]{10,}/,
  "AWS access key" => /\bAKIA[0-9A-Z]{16}\b/,
  "bearer credential" => /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}={0,2}/i
}
secret_patterns.each do |label, pattern|
  errors << "task envelope contains a possible #{label}" if document.match?(pattern)
end

fields = {}
%w[Repository Environment Fingerprint Outcome Evidence].each do |name|
  matches = document.scan(/^#{Regexp.escape(name)}:\s*(.+?)\s*$/i).flatten
  if matches.length != 1
    errors << "#{name} must appear exactly once"
  else
    fields[name.downcase] = matches.first.strip
  end
end

channel_matches = document.scan(/^Slack channel:\s*(.+?)\s*$/i).flatten
if channel_matches.length != 1 || channel_matches.first.strip != "#build"
  errors << "Slack channel must appear exactly once and be #build"
end

source_matches = document.scan(/^Source thread:\s*(.+?)\s*$/i).flatten
if source_matches.length != 1
  errors << "Source thread must appear exactly once"
else
  source_thread = source_matches.first.strip
  unless source_thread.match?(%r{\Ahttps://getyak\.slack\.com/archives/C[A-Z0-9]+/p[0-9]+(?:\?thread_ts=[0-9.]+&cid=C[A-Z0-9]+)?\z})
    errors << "Source thread must be a getyak Slack message permalink"
  end
end

sections = {}
heading_matches = document.to_enum(:scan, /^##\s+(.+?)\s*$/).map do
  [Regexp.last_match.begin(0), Regexp.last_match.end(0), Regexp.last_match(1).downcase]
end
heading_matches.each_with_index do |(_start_at, body_start, name), index|
  body_end = heading_matches.fetch(index + 1, [document.length]).first
  sections[name] = document[body_start...body_end]
end

required_sections = ["constraints", "acceptance", "rollback / recovery", "human boundary"]
required_sections.each do |name|
  heading_count = heading_matches.count { |_start_at, _body_start, heading| heading == name }
  errors << "section ## #{name.split.map(&:capitalize).join(' ')} must appear exactly once" unless heading_count == 1
  body = sections[name].to_s
  errors << "section ## #{name.split.map(&:capitalize).join(' ')} must contain a list item" unless body.match?(/^\s*-\s+\S/)
end

human_boundary = sections["human boundary"].to_s
{
  "deploy" => /deploy/i,
  "secret or credential" => /secret|credential/i,
  "permission or OAuth" => /permission|oauth/i,
  "external communication" => /external|communicat/i,
  "explicit human approval" => /explicit human|human (?:message|approval)/i
}.each do |label, pattern|
  errors << "human boundary must cover #{label}" unless human_boundary.match?(pattern)
end

repository = fields["repository"]
environment = fields["environment"]
target_name, target = targets.find { |_name, value| value["repository"] == repository }

if repository && target.nil?
  errors << "Repository is not an approved Codex target"
elsif target
  errors << "Environment does not match the repository's desired environment" unless environment == target["desired_environment"]
  errors << "Codex target must map exactly one repository" unless target["repo_map"] == [repository]
  if target["integration_state"] != "ready" && ENV["CODEX_TASK_ALLOW_PENDING_TARGET"] != "true"
    errors << "Codex target is #{target["integration_state"].inspect}, not ready"
  end

  evidence = fields["evidence"]
  durable_evidence = %r{\Ahttps://github\.com/#{Regexp.escape(repository)}/(?:issues/[0-9]+|pull/[0-9]+|actions/runs/[0-9]+|commit/[0-9a-fA-F]{7,40}|blob/[0-9a-fA-F]{40}/[^?#]+)(?:[?#].*)?\z}
  errors << "Evidence must be an issue, pull request, run, commit, or immutable blob URL inside the named GitHub repository" unless evidence&.match?(durable_evidence)

  fingerprint = fields["fingerprint"]
  unless fingerprint&.match?(%r{\A#{Regexp.escape(target_name)}:[a-z0-9][a-z0-9_-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*\z})
    errors << "Fingerprint must use REPOSITORY:CLASS:STABLE_ID"
  end
end

unless fields["outcome"].to_s.match?(/\S/) && fields["outcome"].to_s.length >= 12
  errors << "Outcome must describe one observable result"
end

unless errors.empty?
  warn errors.uniq.join("\n")
  exit 1
end

puts JSON.generate(
  valid: true,
  repository: repository,
  environment: environment,
  target: target_name,
  integration_state: target.fetch("integration_state"),
  fingerprint: fields.fetch("fingerprint")
)
RUBY
