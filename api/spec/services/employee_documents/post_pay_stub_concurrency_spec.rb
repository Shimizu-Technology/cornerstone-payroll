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

  it "uploads outside the transaction and discards a PDF when an earlier replacement changes its YTD" do
    upload_started = Queue.new
    release_upload = Queue.new
    uploaded_keys = []
    storage = instance_double(R2StorageService, delete: true)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:upload) do |key, _bytes, **|
      uploaded_keys << key
      if uploaded_keys.one?
        upload_started << ActiveRecord::Base.connection.transaction_open?
        release_upload.pop
      end
      true
    end

    posting = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(PayrollItem.find(later.id)).call
      end
    end
    expect(Timeout.timeout(10) { upload_started.pop }).to be(false)
    expect(EmployeeDocument.where(payroll_item_id: later.id)).to be_empty

    Timeout.timeout(10) do
      ReplaceCheckService.replace!(payroll_item: earlier, corrected_inputs: { hours_worked: 80 },
        reason: "Correct the July hours", actor: actor)
    end
    release_upload << true
    document = Timeout.timeout(15) { posting.value }

    expect(uploaded_keys.size).to eq(2)
    expect(storage).to have_received(:delete).with(uploaded_keys.first).once
    expect(document).to have_attributes(revision: 1, storage_key: uploaded_keys.last,
      payroll_facts_sha256: PayStubGenerator.new(later.reload, employee_copy: true).employee_payroll_facts_sha256)
    expect(EmployeeDocument.where(payroll_item_id: later.id)).to contain_exactly(document)
    expect(later.ytd_gross).to eq(2_400)
  ensure
    release_upload << true
    posting&.join(15)
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
