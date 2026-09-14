# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "operator artifact safety" do
  let(:repository_root) { Rails.root.parent }

  it "does not retain the retired MoSa database and mailbox utilities" do
    retired_paths = %w[
      scripts/download_mosa_attachments.sh
      scripts/download_mosa_attachments.py
      scripts/mosa_run.sh
      api/scripts/mosa_full_year_validation.rb
      api/scripts/mosa_backfill_employees.rb
    ]

    expect(retired_paths.filter { |path| repository_root.join(path).exist? }).to be_empty
  end

  it "does not embed a keyring-password assignment in tracked operator artifacts" do
    output, status = Open3.capture2(
      "git", "-C", repository_root.to_s, "grep", "-n", "-I", "-E",
      "GOG_KEYRING_PASSWORD[[:space:]]*=", "--", "scripts", "docs"
    )

    expect(status.exitstatus).to eq(1), "found embedded keyring-password assignments:\n#{output}"
  end

  it "keeps current operator guidance on supported workflows" do
    current_guidance = [
      repository_root.join("docs/rollout/02-MOSA-CYCLE-RUNBOOK.md"),
      repository_root.join("docs/OPERATOR_AND_RECOVERY_ACCEPTANCE.md")
    ].map(&:read).join("\n")

    expect(current_guidance).not_to include(
      "mosa_run.sh",
      "mosa_full_year_validation.rb",
      "mosa_backfill_employees.rb",
      "payroll_items.destroy_all"
    )
  end
end
