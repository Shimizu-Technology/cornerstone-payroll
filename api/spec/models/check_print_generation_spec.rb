# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckPrintGeneration do
  let(:company) { create(:company, check_stock_type: "top_check") }
  let(:user) { create(:user, company:, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company:) }
  let(:employee) { create(:employee, company:) }
  let(:payroll_item) do
    create(:payroll_item, :with_check, company:, pay_period:, employee:, check_number: "7201")
  end
  let(:printer_profile) do
    PrinterProfile.create!(
      organization: company.organization,
      name: "Payroll Office",
      check_stock_type: company.check_stock_type,
      check_offset_x: 0,
      check_offset_y: 0
    )
  end
  let(:generation) do
    described_class.create!(
      company:, pay_period:, requested_by: user, printer_profile:,
      idempotency_key: SecureRandom.uuid, request_digest: SecureRandom.hex(32),
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    )
  end

  it "allows the same queue execution to resume after an interrupted worker" do
    expect(generation.begin_processing!(job_id: "job-123")).to be(true)
    generation.advance!("rendering", completed_items: 1)

    expect(generation.begin_processing!(job_id: "job-123")).to be(true)
    expect(generation).to have_attributes(
      status: "processing",
      phase: "validating",
      completed_items: 0,
      worker_job_id: "job-123"
    )
  end

  it "does not let a different queue execution duplicate an active generation" do
    expect(generation.begin_processing!(job_id: "job-123")).to be(true)

    expect(generation.begin_processing!(job_id: "job-456")).to be(false)
    expect(generation.reload.worker_job_id).to eq("job-123")
  end
end
