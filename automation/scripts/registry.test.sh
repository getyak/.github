#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$BASH_SOURCE")/../.." && pwd)"

ruby - "$repository_root/automation/registry.yml" <<'RUBY'
require "yaml"

registry = YAML.load_file(ARGV.fetch(0))
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

abort(errors.join("\n")) unless errors.empty?
puts "registry Eval contracts passed"
RUBY

bash -n "$repository_root/automation/scripts/eval-health.sh"
