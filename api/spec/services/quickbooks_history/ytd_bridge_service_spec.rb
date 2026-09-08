# frozen_string_literal: true

require "rails_helper"

RSpec.describe "QuickBooks historical YTD bridge" do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }
  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "previews and atomically activates immutable employee balances before the first live pay period" do
    batch = QuickbooksHistory::ImportService.new(
      company: company,
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads,
      actor: actor
    ).call.batch
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    expect(bootstrap).to be_ready_to_apply
    QuickbooksHistory::ClientBootstrapApplyService.new(
      bootstrap: bootstrap,
      actor: actor,
      acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    approve_historical_cutover(batch, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).lock!

    blocked_period = build_next_period(company)
    expect(blocked_period).not_to be_valid
    expect(blocked_period.errors[:base]).to include(/Activate the verified historical YTD/)

    bridge = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    expect(bridge).to be_ready_to_apply
    expect(bridge.preview_summary).to include(
      "employee_count" => 2,
      "balance_count" => 2,
      "tax_years" => [ 2024 ],
      "gross_pay" => "3000.0",
      "through_pay_date" => "2024-07-03"
    )
    expect(bridge.reconciliation_summary).to include("passed" => true)
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)

    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: bridge,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call

    expect do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: bridge,
        actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call
    end.not_to change(HistoricalEmployeeYtdBalance, :count)

    expect(bridge.reload).to be_applied
    expect(bridge.historical_employee_ytd_balances.count).to eq(2)
    expect([ PayPeriod.count, PayrollItem.count, EmployeeYtdTotal.count ]).to eq([ 0, 0, 0 ])
    alice = company.employees.find_by!(first_name: "Alice", last_name: "Worker")
    future_pay_period_id = 1_000_000
    expect(alice.ytd_totals_before(year: 2024, pay_date: Date.new(2024, 7, 17), pay_period_id: future_pay_period_id)).to include(
      gross_pay: 1_000.0,
      net_pay: 725.0,
      withholding_tax: 100.0,
      social_security_tax: 80.0,
      medicare_tax: 20.0,
      retirement: 50.0,
      loans: 25.0,
      social_security_taxable_total: 1_000.0,
      medicare_taxable_wages: 1_000.0
    )
    expect(build_next_period(company)).to be_valid

    overlapping = build_next_period(company, start_date: Date.new(2024, 6, 27))
    expect(overlapping).not_to be_valid
    expect(overlapping.errors[:start_date]).to include(/must be after the imported QuickBooks history/)

    live_period = build_next_period(company)
    live_period.save!
    expect(live_period.update(start_date: Date.new(2024, 6, 27))).to be(false)
    expect(live_period.errors[:start_date]).to include(/must be after the imported QuickBooks history/)
    expect(bridge.update(plan_digest: "changed")).to be(false)
    expect(bridge.historical_employee_ytd_balances.first.update(gross_pay: 0)).to be(false)
  end

  it "requires a complete ISO-8601 historical boundary on every bridge preview" do
    bridge = prepare_previewed_bridge

    bridge.preview_summary = bridge.preview_summary.except("through_pay_date")

    expect(bridge).not_to be_valid
    expect(bridge.errors[:preview_summary]).to include(/valid ISO-8601 through pay date/)
  end

  it "rejects employee balances that extend beyond their bridge boundary" do
    bridge = create_applied_bridge(
      plan_digest: "bounded-bridge",
      through_period_end: "2024-07-15",
      through_pay_date: "2024-07-20"
    )
    employee = create(:employee, company: company)
    balance = bridge.historical_employee_ytd_balances.build(
      company: company,
      employee: employee,
      tax_year: 2024,
      through_period_end: Date.new(2024, 7, 16),
      through_pay_date: Date.new(2024, 7, 21)
    )

    expect(balance).not_to be_valid
    expect(balance.errors[:through_period_end]).to include(/cannot exceed/)
    expect(balance.errors[:through_pay_date]).to include(/cannot exceed/)
  end

  it "rejects an employee balance whose pay date is outside its tax year" do
    bridge = create_applied_bridge(
      plan_digest: "tax-year-boundary",
      through_period_end: "2024-07-15",
      through_pay_date: "2024-07-20"
    )
    balance = bridge.historical_employee_ytd_balances.build(
      company: company,
      employee: create(:employee, company: company),
      tax_year: 2023,
      through_period_end: Date.new(2024, 7, 15),
      through_pay_date: Date.new(2024, 7, 20)
    )

    expect(balance).not_to be_valid
    expect(balance.errors[:through_pay_date]).to include(/must be in the balance tax year/)
  end

  it "enforces the latest boundary across every locked historical batch" do
    bridge = prepare_previewed_bridge
    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: bridge,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call
    create_applied_bridge(
      plan_digest: "later-boundary",
      through_period_end: "2024-07-15",
      through_pay_date: "2024-07-20",
      locked_at: 1.day.ago
    )

    period = company.pay_periods.build(
      start_date: Date.new(2024, 7, 12),
      end_date: Date.new(2024, 7, 25),
      pay_date: Date.new(2024, 7, 30),
      status: "draft"
    )

    expect(period).not_to be_valid
    expect(period.errors[:start_date]).to include(/07\/15\/2024/)
  end

  it "does not create balances when the activation acknowledgement is wrong" do
    bridge = prepare_previewed_bridge

    expect do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: bridge,
        actor: actor,
        acknowledgement: "wrong"
      ).call
    end.to raise_error(ArgumentError, /ACTIVATE VERIFIED HISTORICAL YTD/)
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)
    expect(bridge.reload).to be_previewed
  end

  it "requires an authorized payroll manager for both preview and activation" do
    bridge = prepare_previewed_bridge
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")

    expect do
      QuickbooksHistory::YtdBridgePreviewService.new(
        batch: bridge.historical_import_batch,
        actor: accountant
      ).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)

    expect do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: bridge,
        actor: accountant,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized, /manager or administrator/)
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)
    expect(bridge.reload).to be_previewed
  end

  it "does not create balances when the reviewed bridge plan is stale" do
    bridge = prepare_previewed_bridge
    bridge.update_column(:plan_digest, "stale-plan")

    expect do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: bridge,
        actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ArgumentError, /preview changed/)
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)
    expect(bridge.reload).to be_previewed
  end

  it "turns unknown tax-and-wage checks into actionable preview errors" do
    bridge = prepare_previewed_bridge
    batch = bridge.historical_import_batch
    reconciliation = batch.tax_wage_reconciliation.deep_dup
    reconciliation.fetch("checks") << {
      "key" => "future_tax_measure",
      "label" => "Future tax measure",
      "year" => 2024,
      "source_amount" => "1.0",
      "passed" => true
    }
    batch.update_column(:tax_wage_reconciliation, reconciliation)

    result = QuickbooksHistory::YtdBridgePlan.new(batch: batch).call

    expect(result).not_to be_ready
    expect(result.errors.join(" ")).to match(/Future tax measure is not modeled by the historical YTD bridge/)
  end

  it "blocks a balance year with no staged tax-and-wage checks" do
    bridge = prepare_previewed_bridge
    batch = bridge.historical_import_batch
    reconciliation = batch.tax_wage_reconciliation.deep_dup
    reconciliation["checks"] = []
    batch.update_column(:tax_wage_reconciliation, reconciliation)

    result = QuickbooksHistory::YtdBridgePlan.new(batch: batch).call

    expect(result).not_to be_ready
    expect(result.errors).to include(
      "2024 has no staged Tax and Wage Summary checks; rebuild the QuickBooks preview before activating historical YTD"
    )
  end

  it "blocks a staged tax checklist that omits a bridge value" do
    bridge = prepare_previewed_bridge
    batch = bridge.historical_import_batch
    reconciliation = batch.tax_wage_reconciliation.deep_dup
    reconciliation["checks"].reject! { |check| check["key"] == "medicare_wages" }
    batch.update_column(:tax_wage_reconciliation, reconciliation)

    result = QuickbooksHistory::YtdBridgePlan.new(batch: batch).call

    expect(result).not_to be_ready
    expect(result.reconciliation.fetch("checks")).to include(
      include("key" => "medicare_wages", "source_amount" => nil, "passed" => false)
    )
    expect(result.errors.join(" ")).to match(/staged Tax and Wage Summary evidence does not cover medicare_wages/)
  end

  %w[Pay\ Tip Pay\ Tips].each do |tip_label|
    it "carries QuickBooks #{tip_label.inspect} earnings into historical reported tips" do
      bridge = prepare_previewed_bridge(
        files: quickbooks_history_uploads_with_tip_label(tip_label) + quickbooks_tax_wage_uploads
      )
      expect(bridge.warnings.join(" ")).to match(/does not distinguish tips paid out separately/)

      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: bridge,
        actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call

      alice = company.employees.find_by!(first_name: "Alice", last_name: "Worker")
      expect(alice.historical_employee_ytd_balances.find_by!(tax_year: 2024).reported_tips).to eq(100.to_d)
    end
  end

  it "carries Roth deductions from after-tax detail without also treating them as loans" do
    bridge = prepare_previewed_bridge(
      files: quickbooks_history_uploads_with_roth_and_loan + quickbooks_tax_wage_uploads
    )
    expect(bridge.warnings.join(" ")).to match(/Roth 401\(k\) Loan.*matches more than one historical YTD bucket/)

    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: bridge,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call

    alice = company.employees.find_by!(first_name: "Alice", last_name: "Worker")
    expect(alice.historical_employee_ytd_balances.find_by!(tax_year: 2024)).to have_attributes(
      roth_retirement: 50.to_d,
      loans: 25.to_d
    )
  end

  it "returns a clear error when clean-client preparation has not been applied" do
    batch = create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: Time.current,
      tax_wage_reconciliation: { "passed" => true }
    )

    expect do
      QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    end.to raise_error(ArgumentError, /Apply the clean-client employee setup/)
    expect(batch.reload.historical_ytd_bridge).to be_nil
  end

  it "surfaces plan errors when an empty archive cannot provide a YTD boundary" do
    batch = create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: Time.current,
      tax_wage_reconciliation: { "passed" => true }
    )
    create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      status: "applied"
    )
    approve_historical_cutover(batch, actor: actor)

    expect do
      QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    end.to raise_error(ArgumentError, /no employee balances to carry forward/i)
    expect(batch.reload.historical_ytd_bridge).to be_nil
  end

  it "does not block live payroll for a locked archive that cannot activate a bridge" do
    existing_period = build_next_period(company)
    existing_period.save!
    create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: Time.current,
      tax_wage_reconciliation: { "passed" => true }
    )

    expect(existing_period.update(status: "calculated")).to be(true)
    expect(build_next_period(company)).to be_valid
  end

  it "does not require a YTD bridge for a legacy locked archive" do
    create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: Time.current,
      importer_version: "quickbooks-online-payroll-v4"
    )

    expect(build_next_period(company)).to be_valid
  end

  it "refuses activation if live payroll appears after the bridge preview" do
    bridge = prepare_previewed_bridge
    build_next_period(company).save!(validate: false)

    refreshed = QuickbooksHistory::YtdBridgePreviewService.new(
      batch: bridge.historical_import_batch,
      actor: actor
    ).call

    expect(refreshed.validation_errors.join(" ")).to match(/already has live pay periods/)
    expect(refreshed.reconciliation_summary).to include("passed" => false)
    expect do
      QuickbooksHistory::YtdBridgeApplyService.new(
        bridge: refreshed,
        actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
      ).call
    end.to raise_error(ArgumentError, /already has live pay periods/)
    expect(HistoricalEmployeeYtdBalance.count).to eq(0)
  end

  it "blocks calculation and status changes when a saved draft predates an activated bridge" do
    stale_draft = build_next_period(company, start_date: Date.new(2024, 6, 27))
    stale_draft.save!
    employee = create(:employee, company: company, employment_type: "hourly", pay_rate: 20)

    create_applied_bridge(
      plan_digest: "activated-after-draft",
      through_period_end: "2024-07-15",
      through_pay_date: "2024-07-20"
    )

    payroll_item = stale_draft.payroll_items.build(
      company: company,
      employee: employee,
      employment_type: "hourly",
      pay_rate: 20,
      hours_worked: 1
    )

    expect { payroll_item.calculate! }
      .to raise_error(ActiveRecord::RecordInvalid, /must be after the imported QuickBooks history/)
    expect(payroll_item).not_to be_persisted
    expect(stale_draft.update(status: "calculated")).to be(false)
    expect(stale_draft.errors[:start_date]).to include(/must be after the imported QuickBooks history/)
  end

  it "does not let a bridge boundary move behind an existing balance" do
    batch = create(:historical_import_batch, company: company)
    bootstrap = create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      status: "applied"
    )
    bridge = HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      plan_digest: "boundary-guard",
      preview_summary: {
        "through_period_end" => "2026-09-30",
        "through_pay_date" => "2026-09-30"
      }
    )
    employee = create(:employee, company: company)
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: company,
      employee: employee,
      tax_year: 2026,
      through_period_end: Date.new(2026, 9, 30),
      through_pay_date: Date.new(2026, 9, 30)
    )

    bridge.preview_summary = {
      "through_period_end" => "2026-09-15",
      "through_pay_date" => "2026-09-15"
    }

    expect(bridge).not_to be_valid
    expect(bridge.errors[:preview_summary]).to include("cannot change after historical YTD balances exist")
  end

  it "does not preview historical YTD before cutover approval and lock" do
    batch = QuickbooksHistory::ImportService.new(
      company: company,
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads,
      actor: actor
    ).call.batch
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    QuickbooksHistory::ClientBootstrapApplyService.new(
      bootstrap: bootstrap,
      actor: actor,
      acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    bridge_count = HistoricalYtdBridge.count
    expect do
      QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    end.to raise_error(ArgumentError, /Lock the approved QuickBooks history/)
    expect(HistoricalYtdBridge.count).to eq(bridge_count)
  end

  it "creates an immutable second YTD revision for reviewed historical adjustments" do
    first_bridge = prepare_previewed_bridge
    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: first_bridge,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call
    batch = first_bridge.historical_import_batch
    paycheck = batch.historical_paychecks.order(:id).first
    original_gross = paycheck.gross_pay
    input = {
      kind: "correction",
      effective_pay_date: paycheck.pay_date.iso8601,
      reason: "Correct source wage classification",
      idempotency_key: "ytd-revision-adjustment",
      gross_pay: 100,
      federal_income_tax: 10,
      social_security_tax: 6.20,
      medicare_tax: 1.45
    }
    preview = HistoricalPayroll::AdjustmentPreviewService.new(
      paycheck: paycheck, actor: actor, attributes: input
    ).call
    adjustment = HistoricalPayroll::AdjustmentCreateService.new(
      paycheck: paycheck,
      actor: actor,
      attributes: input,
      acknowledgement: HistoricalPayroll::AdjustmentCreateService::ACKNOWLEDGEMENT,
      preview_digest: preview.digest
    ).call

    stale_period = build_next_period(company)
    stale_period.save!
    expect(stale_period).not_to be_valid(:payroll_calculation)
    expect(stale_period.errors[:base]).to include(/revised historical YTD bridge/)

    blocked = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    expect(blocked).to be_previewed
    expect(blocked.revision).to eq(2)
    expect(blocked.validation_errors.join(" ")).to include("requires filing review")

    HistoricalPayroll::AdjustmentEventService.new(
      adjustment: adjustment,
      actor: actor,
      event_type: "filing_reviewed_no_amendment"
    ).call
    revised = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
    expect(revised).to have_attributes(revision: 2, supersedes_historical_ytd_bridge_id: first_bridge.id)
    expect(revised).to be_ready_to_apply
    expect(revised.preview_summary).to include(
      "adjustment_ids" => [ adjustment.id ],
      "adjustment_deltas" => include("gross_pay" => "100.0")
    )
    expect(revised.reconciliation_summary).to include("passed" => true)

    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: revised,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call

    expect(first_bridge.reload).to be_applied
    expect(first_bridge.historical_employee_ytd_balances).to exist
    expect(revised.reload).to be_applied
    expect(revised.historical_employee_ytd_balances).to exist
    expect(adjustment.events.where(event_type: "ytd_revision_activated", historical_ytd_bridge: revised)).to exist
    expect(paycheck.reload.gross_pay).to eq(original_gross)
    expect(stale_period.reload).to be_valid(:payroll_calculation)
  end

  it "reuses an applied revision only when the complete YTD plan is unchanged" do
    first_bridge = prepare_previewed_bridge
    QuickbooksHistory::YtdBridgeApplyService.new(
      bridge: first_bridge,
      actor: actor,
      acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    ).call
    batch = first_bridge.historical_import_batch
    reconciliation = batch.tax_wage_reconciliation.deep_dup
    reconciliation["checks"].first["source_amount"] = "0.0"
    batch.update_column(:tax_wage_reconciliation, reconciliation)

    revised = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call

    expect(revised).to have_attributes(revision: 2, supersedes_historical_ytd_bridge_id: first_bridge.id)
    expect(revised).to be_previewed
    expect(revised.plan_digest).not_to eq(first_bridge.plan_digest)
    expect(revised.validation_errors).not_to be_empty
  end

  def build_next_period(company, start_date: Date.new(2024, 6, 28))
    company.pay_periods.build(
      start_date: start_date,
      end_date: Date.new(2024, 7, 11),
      pay_date: Date.new(2024, 7, 17),
      status: "draft"
    )
  end

  def create_applied_bridge(plan_digest:, through_period_end:, through_pay_date:, locked_at: Time.current)
    batch = create(
      :historical_import_batch,
      company: company,
      status: "locked",
      locked_at: locked_at,
      tax_wage_reconciliation: { "passed" => true }
    )
    bootstrap = create(
      :historical_client_bootstrap,
      company: company,
      historical_import_batch: batch,
      status: "applied"
    )
    HistoricalYtdBridge.create!(
      company: company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      status: "applied",
      plan_digest: plan_digest,
      preview_summary: {
        "through_period_end" => through_period_end,
        "through_pay_date" => through_pay_date
      },
      reconciliation_summary: { "passed" => true },
      applied_at: Time.current,
      applied_by: actor,
      apply_acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT
    )
  end

  def prepare_previewed_bridge(files: quickbooks_history_uploads + quickbooks_tax_wage_uploads)
    batch = QuickbooksHistory::ImportService.new(
      company: company,
      files: files,
      actor: actor
    ).call.batch
    bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
    QuickbooksHistory::ClientBootstrapApplyService.new(
      bootstrap: bootstrap,
      actor: actor,
      acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT
    ).call
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    approve_historical_cutover(batch, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).lock!
    QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
  end
end
