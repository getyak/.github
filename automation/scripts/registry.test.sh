#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"

ruby - \
  "$repository_root/automation/registry.yml" \
  "$repository_root/automation/codex-targets.yml" <<'RUBY'
require "yaml"

registry = YAML.load_file(ARGV.fetch(0))
codex_targets = YAML.load_file(ARGV.fetch(1))
repositories = registry.fetch("repositories")
required_fields = %w[
  maturity
  primary_suite
  command
  evidence
  ci_workflow
  acceptance
  privacy
  gap
]
allowed_maturities = %w[
  ci_gated
  versioned_manual
  deterministic_test_proxy
]
errors = []

repositories.each do |name, repository|
  next unless repository["lifecycle"] == "active"

  contract = repository["eval_contract"]
  unless contract.is_a?(Hash)
    errors << "#{name}: active repository is missing eval_contract"
    next
  end

  required_fields.each do |field|
    errors << "#{name}: eval_contract.#{field} is missing" unless contract.key?(field)
  end
  unless allowed_maturities.include?(contract["maturity"])
    errors << "#{name}: unsupported eval maturity #{contract["maturity"].inspect}"
  end
  if contract["maturity"] == "ci_gated" && contract["ci_workflow"].to_s.empty?
    errors << "#{name}: ci_gated contract must declare ci_workflow"
  end
  if contract["maturity"] == "ci_gated"
    %w[ci_job ci_step artifact_prefix artifact_partial_pattern].each do |field|
      errors << "#{name}: ci_gated contract is missing #{field}" unless contract.key?(field)
    end
    errors << "#{name}: ci_gated contract must declare ci_job" if contract["ci_job"].to_s.empty?
    errors << "#{name}: ci_gated contract must declare ci_step" if contract["ci_step"].to_s.empty?
  end
  unless contract["privacy"] == "synthetic_only"
    errors << "#{name}: automated Eval discovery must remain synthetic_only"
  end
end

active_repositories = repositories.each_with_object([]) do |(name, repository), values|
  values << name if repository["lifecycle"] == "active"
end.sort
targets = codex_targets.fetch("targets")
unless targets.keys.sort == active_repositories
  errors << "Codex targets must exactly match active repositories"
end

allowed_integration_states = %w[pending_verification ready paused]
allowed_review_modes = %w[manual_p0_p1_after_setup automatic_p0_p1 paused]
desired_environments = []
targets.each do |name, target|
  expected_repository = "getyak/#{name}"
  errors << "#{name}: Codex repository must be #{expected_repository}" unless target["repository"] == expected_repository
  errors << "#{name}: Codex repo_map must contain only #{expected_repository}" unless target["repo_map"] == [expected_repository]
  if target["desired_environment"].to_s.empty?
    errors << "#{name}: desired_environment is missing"
  else
    desired_environments << target["desired_environment"]
  end
  unless allowed_integration_states.include?(target["integration_state"])
    errors << "#{name}: unsupported integration_state #{target["integration_state"].inspect}"
  end
  unless allowed_review_modes.include?(target["review_mode"])
    errors << "#{name}: unsupported review_mode #{target["review_mode"].inspect}"
  end
end
errors << "Codex desired environments must be unique" unless desired_environments.uniq.length == desired_environments.length
errors << "Codex Slack route must be build" unless codex_targets.dig("slack", "channel") == "build"
errors << "Codex ambiguous targets must be rejected" unless codex_targets.dig("policy", "ambiguous_target") == "reject"
errors << "Codex unverified targets must be rejected" unless codex_targets.dig("policy", "unverified_target") == "reject"

abort(errors.join("\n")) unless errors.empty?
puts "registry Eval and Codex target contracts passed"
RUBY

bash -n "$repository_root/automation/scripts/eval-health.sh"
bash -n "$repository_root/automation/scripts/codex-task-lint.sh"
bash -n "$repository_root/automation/scripts/codex-task-lint.test.sh"
bash -n "$repository_root/automation/scripts/codex-review-health.sh"
bash -n "$repository_root/automation/scripts/codex-review-health.test.sh"

"$repository_root/automation/scripts/codex-task-lint.test.sh"
"$repository_root/automation/scripts/codex-review-health.test.sh"
