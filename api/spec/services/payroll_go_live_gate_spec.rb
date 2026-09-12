# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollGoLiveGate do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization:) }
  let(:source_company) { create(:company, organization:) }
  let(:batch) { create(:historical_import_batch, company:, status: "locked") }

  def create_review(status:, effective_on: Date.new(2026, 9, 21))
    PayrollGoLiveReview.create!(
      company:,
      source_company:,
      historical_import_batch: batch,
      effective_on:,
      plan_digest: "d" * 64,
      status:
    )
  end

  def activate_historical_bridge(actor:)
    bootstrap = HistoricalClientBootstrap.create!(
      company:,
      historical_import_batch: batch,
      status: "applied",
      plan_digest: "bootstrap-plan",
      applied_at: Time.current,
      applied_by: actor
    )
    HistoricalYtdBridge.create!(
      company:,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: "bridge-plan",
      preview_summary: {
        "through_period_end" => "2026-08-31",
        "through_pay_date" => "2026-09-04"
      },
      applied_at: Time.current,
      created_by: actor,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
  end

  it "does not affect companies outside the QuickBooks cutover workflow" do
    gate = described_class.new(company:, pay_date: Date.new(2026, 9, 30))

    expect(gate.state).to include(required: false, comparison_only: false)
    expect { gate.require_live_payroll!(parallel_run: false) }.not_to raise_error
  end

  it "allows payroll before the review effective date" do
    create_review(status: "draft")
    gate = described_class.new(company:, pay_date: Date.new(2026, 9, 20))

    expect(gate.state).to include(required: false, comparison_only: false)
  end

  it "allows only parallel comparison payroll while approval is incomplete" do
    create_review(status: "setup_applied")
    gate = described_class.new(company:, pay_date: Date.new(2026, 9, 21))

    expect(gate.state).to include(required: true, approved: false, comparison_only: true)
    expect { gate.require_live_payroll!(parallel_run: true) }.not_to raise_error
    expect { gate.require_live_payroll!(parallel_run: false) }
      .to raise_error(described_class::BlockedError, /Live payroll is blocked/)
  end

  it "allows live payroll after both signoffs approve the review" do
    create_review(status: "approved")
    gate = described_class.new(company:, pay_date: Date.new(2026, 9, 21))

    expect(gate.state).to include(required: true, approved: true, comparison_only: false)
    expect { gate.require_live_payroll!(parallel_run: false) }.not_to raise_error
  end

  it "blocks approval and commit for a live run while the cutover is open" do
    create_review(status: "setup_applied")
    actor = create(:user, company:, organization:, role: "admin")
    activate_historical_bridge(actor:)
    employee = create(:employee, company:)
    period = create(
      :pay_period,
      :calculated,
      company:,
      start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 15),
      pay_date: Date.new(2026, 9, 30)
    )
    create(:payroll_item, pay_period: period, employee:, company:)
    lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor:)

    expect { lifecycle.approve! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Live payroll is blocked/)

    period.update!(status: "approved")
    expect { lifecycle.commit! }
      .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Live payroll is blocked/)
  end

  it "lets an incomplete cutover approve a non-committable comparison" do
    create_review(status: "setup_applied")
    actor = create(:user, company:, organization:, role: "admin")
    activate_historical_bridge(actor:)
    period = create(
      :pay_period,
      :calculated,
      company:,
      parallel_run: true,
      start_date: Date.new(2026, 9, 1),
      end_date: Date.new(2026, 9, 15),
      pay_date: Date.new(2026, 9, 30)
    )

    expect { PayPeriodLifecycleService.new(pay_period: period, actor:).approve! }
      .to change { period.reload.status }.from("calculated").to("approved")
  end
end
