# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe IssueCorrectivePaycheckService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:tax_table) { create(:tax_table) }
  let!(:organization) { Organization.create!(name: "Corrective concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, auto_create_fit_check: false) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department, pay_rate: 15, pay_frequency: "biweekly") }
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 1),
      end_date: Date.new(2024, 1, 14), pay_date: Date.new(2024, 1, 19))
  end
  let!(:item) do
    row = period.payroll_items.build(employee: employee, company: company, employment_type: "hourly", pay_rate: 15, hours_worked: 60)
    PayrollCalculator.for(employee, row).calculate
    row.save!
    employee.ytd_totals_for(2024).add_payroll_item!(row)
    CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(row)
    row
  end

  after do
    period_ids = PayPeriod.where(company: company).pluck(:id)
    item_ids = PayrollItem.where(pay_period_id: period_ids).pluck(:id)
    connection = CheckEvent.connection
    begin
      connection.execute("ALTER TABLE check_events DISABLE TRIGGER check_events_append_only")
      CheckEvent.where(payroll_item_id: item_ids).delete_all
    ensure
      connection.execute("ALTER TABLE check_events ENABLE TRIGGER check_events_append_only")
    end
    PayrollLiabilityEntry.where(company: company).delete_all
    PayrollLiabilityPosting.where(company: company).delete_all
    PayrollItemEarning.where(payroll_item_id: item_ids).delete_all
    PayrollItem.where(id: item_ids).delete_all
    EmployeeYtdTotal.where(employee: employee).delete_all
    CompanyYtdTotal.where(company: company).delete_all
    PayPeriod.where(id: period_ids).delete_all
    EmployeeWageRate.where(employee: employee).delete_all
    Employee.where(id: employee.id).delete_all
    Department.where(id: department.id).delete_all
    User.where(id: actor.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
    tax_table.destroy!
  end

  [ false, true ].product([ false, true ]).each do |different_target, categorized|
    it "records one financial delta when #{different_target ? 'different reviewed' : 'identical'} targets compete from stale previews with #{categorized ? 'one verified rate row' : 'scalar hours'}" do
      if categorized
        rate = employee.employee_wage_rates.create!(label: "Regular Pay", rate: 15, active: true, is_primary: true)
        item.wage_rate_hours = [ { employee_wage_rate_id: rate.id, label: "Regular Pay", rate: 15,
          regular_hours: 60, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, active: true, is_primary: true } ]
        item.save!
      end
      locked, release, second_ready, results = Array.new(4) { Queue.new }
      allow_any_instance_of(described_class).to receive(:create_supplemental_period!).and_wrap_original do |original, *args|
        if Thread.current[:first_corrective]
          locked << true
          Timeout.timeout(10) { release.pop }
        end
        original.call(*args)
      end
      period_id, employee_id, actor_id = period.id, employee.id, actor.id
      worker = lambda do |first|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Thread.current[:first_corrective] = first
            arguments = { original_pay_period: PayPeriod.find(period_id), employee: Employee.find(employee_id),
              corrected_inputs: { hours_worked: different_target && !first ? 65 : 80 }, pay_date: Date.new(2024, 1, 26), reason: "Same verified target", actor: User.find(actor_id) }
            service = described_class.new(**arguments)
            proof = service.preview.fetch(:meta).fetch(:review_digest)
            service = described_class.new(**arguments, expected_review_digest: proof) if different_target
            second_ready << true unless first
            results << [ :ok, service.issue! ]
          rescue => error
            results << [ :error, error ]
          end
        end
      end
      first = worker.call(true)
      Timeout.timeout(10) { locked.pop }
      second = worker.call(false)
      Timeout.timeout(10) { second_ready.pop }
      release << true
      [ first, second ].each { |thread| Timeout.timeout(15) { thread.join } }
      outcomes = 2.times.map { results.pop }
      expect(outcomes.count { |status, _| status == :ok }).to eq(1)
      expect(outcomes.filter_map { |status, result| result if status == :error })
        .to contain_exactly(an_instance_of(different_target ? described_class::StalePreviewError : described_class::InvalidStateError))
      expect(period.supplemental_pay_periods.count).to eq(1)
      expect(employee.ytd_totals_for(2024).reload.gross_pay).to eq(1200)
      expect(CompanyYtdTotal.find_by!(company: company, year: 2024).gross_pay).to eq(1200)
      expect(item.reload.hours_worked).to eq(60)
    ensure
      release << true
      [ first, second ].compact.each { |thread| thread.join(15) }
    end
  end
end
