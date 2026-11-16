# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRunEligibility do
  include ActiveSupport::Testing::TimeHelpers
  around { |example| travel_to(Time.utc(2026, 11, 17, 12)) { example.run } }
  let(:company) { create(:company) }
  let(:worker) { create(:employee, company: company, first_name: "Dana", last_name: "Lee", hire_date: "2024-01-01") }
  let(:period) { create(:pay_period, :calculated, company: company, start_date: "2026-11-16", end_date: "2026-11-30", pay_date: "2026-12-04") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: :manager) }
  before { create(:payroll_item, company: company, employee: worker, pay_period: period) }

  it "shows a dated reason and clears after reactivation" do
    EmployeeStatusTransitionService.deactivate!(employee: worker, actor: actor, attributes: { effective_date: "2026-11-15" })
    expect(described_class.new(period).payload.sole).to include(employee_id: worker.id, reason: "Dana Lee is inactive from Nov 15, 2026", effective_date: Date.new(2026, 11, 15))
    EmployeeStatusTransitionService.reactivate!(employee: worker, actor: actor, attributes: { effective_date: "2026-11-16" })
    expect(described_class.new(period).payload).to be_empty
  end

  %w[deactivate terminate].each do |action|
    it "keeps a worker whose #{action} date falls within the run eligible" do
      EmployeeStatusTransitionService.public_send("#{action}!", employee: worker, actor: actor, attributes: { effective_date: "2026-11-17" })
      expect(described_class.new(period).payload).to be_empty
    end
  end

  it "preserves the different start-day boundaries for termination and inactivity" do
    EmployeeStatusTransitionService.terminate!(employee: worker, actor: actor, attributes: { effective_date: "2026-11-16" })
    expect(described_class.new(period).payload).to be_empty
    inactive = create(:employee, company: company, hire_date: "2024-01-01")
    create(:payroll_item, company: company, employee: inactive, pay_period: period)
    EmployeeStatusTransitionService.deactivate!(employee: inactive, actor: actor, attributes: { effective_date: "2026-11-16" })
    expect(described_class.new(period).payload.sole[:status]).to eq("inactive")
  end
end
