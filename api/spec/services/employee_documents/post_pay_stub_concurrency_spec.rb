# frozen_string_literal: true

require "rails_helper"
require "timeout"

# A replacement of an earlier check refreshes the later checks' YTD while it
# holds the company lock. A stub posting for one of those later checks must
# take its locks in the same order, or each waits on the other.
RSpec.describe EmployeeDocuments::PostPayStub, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:tax_table) { @tax_table = create(:tax_table, tax_year: 2024) }
  let!(:organization) { @organization = Organization.create!(name: "Stub Lock Order #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, auto_create_fit_check: false, next_check_number: 1001) }
  let!(:employee) do
    create(:employee, company: company, department: Department.create!(company: company, name: "Lock Order"), pay_rate: 15.00, pay_frequency: "biweekly", filing_status: "single", allowances: 0)
  end
  let!(:actor) { create(:user, company: company, organization: organization, role: "admin") }
  let!(:earlier) { committed_item(Date.new(2024, 7, 20), hours_worked: 66.67) }
  let!(:later) { committed_item(Date.new(2024, 8, 20), hours_worked: 80, delivery: "direct_deposit") }

  after { cleanup! }

  def committed_item(pay_date, hours_worked:, delivery: "paper_check")
    period = create(:pay_period, :committed, company: company, start_date: pay_date - 19, end_date: pay_date - 6, pay_date: pay_date)
    item = period.payroll_items.build(employee: employee, company_id: company.id, employment_type: "hourly",
      pay_rate: 15.00, hours_worked: hours_worked, payment_delivery_method: delivery)
    PayrollCalculator.for(employee, item).calculate
    item.save!
    EmployeeYtdTotal.find_or_create_by!(employee_id: employee.id, year: 2024).add_payroll_item!(item)
    CompanyYtdTotal.find_or_create_by!(company_id: company.id, year: 2024).add_payroll_item!(item)
    company.reload.assign_check_numbers!([ item ]) if delivery == "paper_check"
    item.reload
  end

  it "posts a later stub while an earlier check's replacement refreshes its YTD, without a deadlock" do
    allow(R2StorageService).to receive(:new).and_return(instance_double(R2StorageService, upload: true, delete: true))
    posting_generated = Queue.new
    release_posting = Queue.new
    allow_any_instance_of(PayStubGenerator).to receive(:generate).and_wrap_original do |original, *args|
      if Thread.current[:stub_posting]
        posting_generated << true
        release_posting.pop
      end
      original.call(*args)
    end
    results = Queue.new
    backend = Queue.new

    posting = Thread.new do
      Thread.current[:stub_posting] = true
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(PayrollItem.find(later.id)).call
        results << [ :ok, :posting ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
    Timeout.timeout(10) { posting_generated.pop }

    replacement = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        backend << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
        ReplaceCheckService.replace!(payroll_item: PayrollItem.find(earlier.id), corrected_inputs: { hours_worked: 80 },
          reason: "Correct the July hours", actor: User.find(actor.id))
        results << [ :ok, :replacement ]
      rescue StandardError => e
        results << [ :error, e ]
      end
    end
    wait_for_database_lock!(backend.pop)
    release_posting << true
    [ posting, replacement ].each { |thread| Timeout.timeout(15) { thread.join } }

    expect(2.times.map { results.pop }).to contain_exactly([ :ok, :posting ], [ :ok, :replacement ])
    expect(EmployeeDocument.where(payroll_item_id: later.id).pluck(:revision)).to eq([ 1 ])
    expect(later.reload.ytd_gross).to eq(2_400)
  end

  def wait_for_database_lock!(backend_pid)
    Timeout.timeout(5) do
      loop do
        state = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(backend_pid)}"
        )
        break if state == "Lock"

        sleep 0.01
      end
    end
  end

  # Only what this example committed; a fixture that failed to build is skipped.
  def cleanup!
    TaxTable.where(id: @tax_table&.id).delete_all
    return unless @organization

    organization_id = @organization.id
    company_ids = Company.where(organization_id: organization_id).pluck(:id)
    employee_ids = Employee.where(company_id: company_ids).pluck(:id)
    item_ids = PayrollItem.where(company_id: company_ids).pluck(:id)
    EmployeeDocument.where(company_id: company_ids).update_all(replaces_document_id: nil)
    EmployeeDocument.where(company_id: company_ids).delete_all
    connection = CheckEvent.connection
    connection.execute("ALTER TABLE check_events DISABLE TRIGGER check_events_append_only")
    CheckEvent.where(payroll_item_id: item_ids).delete_all
    connection.execute("ALTER TABLE check_events ENABLE TRIGGER check_events_append_only")
    PayrollLiabilityEntry.where(company_id: company_ids).delete_all
    PayrollLiabilityPosting.where(company_id: company_ids).delete_all
    PayrollItemEarning.where(payroll_item_id: item_ids).delete_all
    PayrollItemDeduction.where(payroll_item_id: item_ids).delete_all
    PayrollItem.where(id: item_ids).delete_all
    EmployeeYtdTotal.where(employee_id: employee_ids).delete_all
    CompanyYtdTotal.where(company_id: company_ids).delete_all
    PayPeriod.where(company_id: company_ids).delete_all
    AuditLog.where(company_id: company_ids).delete_all
    EmployeeCompensationChange.where(employee_id: employee_ids).delete_all
    Employee.where(id: employee_ids).delete_all
    Department.where(company_id: company_ids).delete_all
    User.where(company_id: company_ids).delete_all
    Company.where(id: company_ids).delete_all
    Organization.where(id: organization_id).delete_all
  end
end
