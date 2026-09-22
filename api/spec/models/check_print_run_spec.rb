# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckPrintRun, type: :model do
  it "requires every manifest entry to identify its source record" do
    company = create(:company)
    run = described_class.new(
      company: company,
      pay_period: create(:pay_period, company: company),
      status: "generated",
      check_stock_type: company.check_stock_type,
      starting_slot: 1,
      selected_count: 1,
      manifest: [ { "source_type" => "payroll_item" } ],
      storage_key: "check-print-runs/model-spec.pdf",
      filename: "model-spec.pdf",
      sha256: "a" * 64,
      byte_size: 100
    )

    expect(run).not_to be_valid
    expect(run.errors[:manifest]).to include("entries must identify their source type and record")
  end
end
