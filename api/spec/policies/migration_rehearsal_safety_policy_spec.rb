# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationRehearsalSafetyPolicy do
  it "blocks money-moving and filing-ready actions while retaining draft review" do
    expect(described_class.blocked?(controller_path: "api/v1/admin/pay_periods", action_name: "commit")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/check_print_runs", action_name: "create")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/reports", action_name: "w2_gu_mark_ready")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/reports", action_name: "check_signoff_sheet")).to be(true)
    expect(described_class.blocked?(controller_path: "api/v1/admin/reports", action_name: "w2_gu")).to be(false)
    expect(described_class.blocked?(controller_path: "api/v1/admin/pay_periods", action_name: "run_payroll")).to be(false)
  end
end
