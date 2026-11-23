# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeCompensationChangeService do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:employee) { create(:employee, company: company, pay_rate: 15, hire_date: Date.new(2026, 1, 1)) }

  around { |example| travel_to(Time.zone.parse("2026-11-20 12:00:00 +10:00")) { example.run } }

  def change!(**options)
    described_class.new(employee: employee, actor: actor, source: "staff", reason: "Spec change", **options).call!
  end

  def period(start_on, end_on, status: "draft")
    create(:pay_period, company: company, start_date: start_on, end_date: end_on, pay_date: end_on + 5, status: status,
      committed_at: status == "committed" ? Time.current : nil)
  end

  describe "the single write path" do
    it "rejects a direct pay-rate update outside the service" do
      expect { employee.update!(pay_rate: 20) }.to raise_error(described_class::CompensationMutationError)
      expect(employee.reload.pay_rate).to eq(15)
    end

    it "rejects direct wage-rate edits and deletes outside the service" do
      rate = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
      expect { rate.update!(rate: 20) }.to raise_error(described_class::CompensationMutationError)
      expect { rate.update!(active: false) }.to raise_error(described_class::CompensationMutationError)
      expect { rate.destroy! }.to raise_error(described_class::CompensationMutationError)
      expect(rate.reload).to have_attributes(rate: 15, active: true)
    end

    it "rejects history edits outside the service" do
      version = employee.employee_compensation_changes.sole
      expect { version.update!(pay_rate: 99) }.to raise_error(described_class::CompensationMutationError)
      expect { version.destroy! }.to raise_error(described_class::CompensationMutationError)
    end

    it "still allows unrelated employee edits" do
      employee.update!(first_name: "Renamed", pay_rate: 15)
      expect(employee.reload.first_name).to eq("Renamed")
    end
  end

  describe "initial versions" do
    it "records the starting pay rate when an employee is created" do
      expect(employee.employee_compensation_changes.sole).to have_attributes(
        pay_rate: 15, effective_on: Date.new(2026, 1, 1), ends_on: nil, source: "employee_creation"
      )
    end

    it "records a wage rate added during setup from the start of the employee's history" do
      rate = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
      expect(rate.employee_wage_rate_versions.sole).to have_attributes(effective_on: Date.new(2026, 1, 1), rate: 15, active: true)
    end
  end

  describe "future-dated raises" do
    let!(:rate) { employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true) }
    let!(:open_period) { period(Date.new(2026, 11, 16), Date.new(2026, 11, 30)) }
    let!(:next_period) { period(Date.new(2026, 12, 1), Date.new(2026, 12, 15)) }

    before do
      change!(effective_on: "2026-12-01", pay_rate: 17, wage_rate_edits: [ { id: rate.id, rate: 17 } ])
      employee.reload
    end

    it "keeps the current open period at the old rate and pays the next period at the new rate" do
      expect(employee.default_payroll_rate_on(open_period.end_date)).to eq(15)
      expect(employee.default_payroll_rate_on(next_period.end_date)).to eq(17)
      expect(employee.wage_rates_on(open_period.end_date).map(&:rate)).to eq([ 15 ])
      expect(employee.wage_rates_on(next_period.end_date).map(&:rate)).to eq([ 17 ])
    end

    it "leaves today's cache columns alone until the change starts, then the daily job activates it" do
      expect(employee.pay_rate).to eq(15)
      expect(rate.reload.rate).to eq(15)

      SyncEffectiveCompensationJob.perform_now(as_of: "2026-12-01")

      expect(employee.reload.pay_rate).to eq(17)
      expect(rate.reload.rate).to eq(17)
    end

    it "keeps a scheduled raise when an earlier change is inserted before it" do
      change!(effective_on: "2026-11-25", pay_rate: 16)
      timeline = employee.reload.employee_compensation_changes.chronological.map { |row| [ row.effective_on.iso8601, row.ends_on&.iso8601, row.pay_rate.to_i ] }
      expect(timeline).to eq([ [ "2026-01-01", "2026-11-24", 15 ], [ "2026-11-25", "2026-11-30", 16 ], [ "2026-12-01", nil, 17 ] ])
    end

    it "replaces a change already recorded for the same date" do
      change!(effective_on: "2026-12-01", pay_rate: 18)
      expect(employee.reload.employee_compensation_changes.where(effective_on: Date.new(2026, 12, 1)).sole.pay_rate).to eq(18)
    end
  end

  it "allows a future client change after a staff edit effective today" do
    change!(effective_on: PayrollBusinessClock.today, pay_rate: 16)
    date = PayrollBusinessClock.today + 10
    change!(effective_on: date, pay_rate: 17, reject_scheduled_conflict: true)

    expect(employee.payroll_rate_on(date)).to eq(17)
    expect { change!(effective_on: date + 1, pay_rate: 18, reject_scheduled_conflict: true) }
      .to raise_error(described_class::ConflictError)
  end

  it "does not turn a cancelled future-only wage row into copied history" do
    date = PayrollBusinessClock.today + 10
    change!(effective_on: date, wage_rate_edits: [ { label: "Night Shift", rate: 22 } ])
    change!(effective_on: date, cancel: true)
    orphan = employee.employee_wage_rates.sole
    expect(orphan.label).to start_with(described_class::RESERVED_LABEL_PREFIX)

    target = create(:employee)
    described_class.copy_history!(source: employee, target: target, actor: actor) do
      { orphan.id => target.employee_wage_rates.create!(label: orphan.label, active: false) }
    end

    expect(target.employee_wage_rate_versions).to be_empty
    expect(target.wage_rates_on(date, include_inactive: true)).to be_empty
  end

  describe "approved and committed payroll" do
    let!(:committed) { period(Date.new(2026, 11, 1), Date.new(2026, 11, 15), status: "committed") }
    let!(:paid_item) { create(:payroll_item, company: company, pay_period: committed, employee: employee, pay_rate: 15, gross_pay: 1200) }

    it "refuses a change dated inside payroll that is already committed" do
      expect { change!(effective_on: "2026-11-10", pay_rate: 18) }.to raise_error(described_class::LockedPeriodError, /through 2026-11-15/)
      expect(employee.reload.pay_rate).to eq(15)
      expect(employee.employee_compensation_changes.count).to eq(1)
    end

    it "treats approved payroll as locked too" do
      committed.update_columns(status: "approved", committed_at: nil)
      expect { change!(effective_on: "2026-11-10", pay_rate: 18) }.to raise_error(described_class::LockedPeriodError)
    end

    it "records an explicit historical correction without changing the paid check" do
      before_item = paid_item.reload.attributes
      change!(effective_on: "2026-11-10", pay_rate: 18, historical_correction: true)
      expect(paid_item.reload.attributes).to eq(before_item)
      expect(employee.reload.employee_compensation_changes.find_by(effective_on: Date.new(2026, 11, 10))).to have_attributes(pay_rate: 18, historical_correction: true)
    end

    it "reports the actual last corrected day when a closer version already exists" do
      change!(effective_on: "2026-11-13", pay_rate: 17, historical_correction: true)
      result = change!(effective_on: "2026-11-10", pay_rate: 18, historical_correction: true)
      expect(result.compensation_change.ends_on).to eq(Date.new(2026, 11, 12))
      audit = AuditLog.where(action: "employee#compensation_changed", record_id: employee.id).order(:id).last
      expect(audit.metadata.fetch("correction_ends_on")).to eq("2026-11-12")
    end

    it "requires a reason for a historical correction" do
      expect do
        described_class.new(employee: employee, actor: actor, source: "staff", effective_on: "2026-11-10", pay_rate: 18, historical_correction: true).call!
      end.to raise_error(described_class::Error, /historical correction/)
    end

    it "defaults to the day after the last committed payroll" do
      result = change!(pay_rate: 18)
      expect(result.effective_on).to eq(Date.new(2026, 11, 16))
      expect(described_class.next_uncommitted_period_start(employee)).to eq(Date.new(2026, 11, 16))
    end

    it "is not locked by an off-cycle tips run" do
      committed.update_columns(run_purpose: "off_cycle_tips", includes_base_salary: false)
      expect(described_class.locked_through(employee)).to be_nil
    end
  end

  describe "wage-rate removal" do
    let!(:regular) { employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true) }
    let!(:weekend) { employee.employee_wage_rates.create!(label: "Weekend", rate: 20) }

    it "ends a removed rate instead of deleting it" do
      change!(effective_on: "2026-11-20", wage_rates: [ { id: regular.id, label: "Regular", rate: 15, is_primary: true } ], replace_missing_wage_rates: true)
      expect(weekend.reload.active).to be(false)
      expect(weekend.employee_wage_rate_versions.chronological.map { |row| [ row.effective_on.iso8601, row.ends_on&.iso8601, row.active ] })
        .to eq([ [ "2026-01-01", "2026-11-19", true ], [ "2026-11-20", nil, false ] ])
      expect(employee.reload.wage_rates_on(Date.new(2026, 11, 19)).map(&:label)).to eq(%w[Regular Weekend])
      expect(employee.wage_rates_on(Date.new(2026, 11, 20)).map(&:label)).to eq(%w[Regular])
    end

    it "reuses an ended rate's row when its label is added back" do
      change!(effective_on: "2026-11-19", wage_rates: [ { id: regular.id, label: "Regular", rate: 15, is_primary: true } ], replace_missing_wage_rates: true)
      change!(effective_on: "2026-11-20", wage_rates: [ { id: regular.id, label: "Regular", rate: 15, is_primary: true }, { label: "Weekend", rate: 22 } ],
        replace_missing_wage_rates: true)
      expect(weekend.reload).to have_attributes(active: true, rate: 22)
      expect(employee.employee_wage_rates.count).to eq(2)
    end
  end

  describe "pay type changes" do
    it "refuses to schedule a pay type change ahead" do
      expect do
        change!(effective_on: "2026-12-01", pay_rate: 52_000, basis: { employment_type: "salary", salary_type: "annual" })
      end.to raise_error(described_class::Error, /Pay type changes take effect immediately/)
    end
  end

  it "replaces the version on the requested date even if the amount equals today's" do
    date = Date.new(2026, 12, 1)
    change!(effective_on: date, pay_rate: 17)
    change!(effective_on: date, pay_rate: 15)
    expect(employee.compensation_on(date).pay_rate).to eq(15)
  end

  it "cancels an entire date, closes the timeline gap, and permits a basis conversion" do
    rate = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
    date = Date.new(2026, 12, 1)
    change!(effective_on: date, pay_rate: 17, wage_rate_edits: [ { id: rate.id, rate: 17 } ])
    change!(effective_on: date, cancel: true)
    expect(employee.default_payroll_rate_on(date)).to eq(15)
    expect(rate.employee_wage_rate_versions.sole.ends_on).to be_nil
    expect(AuditLog.where(record_id: employee.id, action: "employee#compensation_changed").last.metadata["cancelled"]).to be(true)
    change!(effective_on: "2026-11-20", pay_rate: 52_000, basis: { employment_type: "salary", salary_type: "annual" })
    expect(employee.reload.employment_type).to eq("salary")
  end

  it "activates a label swap without violating the cache index" do
    a = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
    b = employee.employee_wage_rates.create!(label: "Weekend", rate: 20)
    change!(effective_on: "2026-12-01", wage_rate_edits: [ { id: a.id, label: b.label }, { id: b.id, label: a.label } ])
    expect(a.reload.label).to eq("Regular")
    SyncEffectiveCompensationJob.perform_now(as_of: "2026-12-01")
    expect([ a.reload.label, b.reload.label ]).to eq(%w[Weekend Regular])
  end

  it "rejects duplicate labels introduced at a later boundary" do
    a = employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true)
    b = employee.employee_wage_rates.create!(label: "Weekend", rate: 20)
    change!(effective_on: "2026-12-01", wage_rate_edits: [ { id: a.id, label: "Holiday" } ])
    expect do
      change!(effective_on: "2026-11-20", wage_rate_edits: [ { id: b.id, label: "Holiday" } ])
    end.to raise_error(described_class::Error, /unique on 2026-12-01/)
    expect(b.reload.label).to eq("Weekend")
  end

  it "warns when the change starts in the middle of an open payroll" do
    period(Date.new(2026, 11, 16), Date.new(2026, 11, 30))
    result = change!(effective_on: "2026-11-20", pay_rate: 16)
    expect(result.warnings.sole).to include("mid-period on 2026-11-20")
  end

  it "records a readable before and after audit entry" do
    change!(effective_on: "2026-11-20", pay_rate: 16)
    audit = AuditLog.where(action: "employee#compensation_changed", record_id: employee.id).sole
    expect(audit.metadata).to include("effective_on" => "2026-11-20", "reason" => "Spec change", "source" => "staff")
    expect(audit.metadata.dig("before", "pay_rate")).to eq("15.0")
    expect(audit.metadata.dig("after", "pay_rate")).to eq("16.0")
  end

  it "records nothing when the submitted pay matches today's" do
    employee
    expect { change!(pay_rate: 15) }.not_to change(EmployeeCompensationChange, :count)
    expect(AuditLog.where(action: "employee#compensation_changed", record_id: employee.id)).to be_empty
  end
end
