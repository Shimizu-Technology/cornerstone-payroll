# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckPrintGenerationRecoveryJob do
  let(:company) { create(:company, check_stock_type: "top_check") }
  let(:user) { create(:user, company:, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company:) }
  let(:employee) { create(:employee, company:) }
  let(:payroll_item) { create(:payroll_item, :with_check, company:, pay_period:, employee:) }
  let(:printer_profile) do
    PrinterProfile.create!(
      organization: company.organization,
      name: "Payroll Office",
      check_stock_type: company.check_stock_type,
      check_offset_x: 0,
      check_offset_y: 0
    )
  end

  def create_generation(status:, updated_at:)
    CheckPrintGeneration.create!(
      company:, pay_period:, requested_by: user, printer_profile:,
      idempotency_key: SecureRandom.uuid, request_digest: SecureRandom.hex(32),
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    ).tap do |generation|
      generation.update_columns(
        status: status,
        phase: status == "processing" ? "rendering" : "queued",
        worker_job_id: status == "processing" ? "worker-1" : nil,
        updated_at: updated_at
      )
    end
  end

  it "fails abandoned queued and processing generations without touching a fresh heartbeat" do
    abandoned_queued = create_generation(status: "queued", updated_at: 31.minutes.ago)
    abandoned_processing = create_generation(status: "processing", updated_at: 31.minutes.ago)
    fresh_processing = create_generation(status: "processing", updated_at: 5.minutes.ago)

    described_class.perform_now

    expect(abandoned_queued.reload).to have_attributes(status: "failed", error_code: "generation_abandoned")
    expect(abandoned_processing.reload).to have_attributes(status: "failed", error_code: "generation_abandoned")
    expect(fresh_processing.reload).to have_attributes(status: "processing", error_code: nil)
  end
end
