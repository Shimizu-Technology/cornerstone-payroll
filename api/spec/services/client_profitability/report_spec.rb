# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientProfitability::Report do
  let(:practice) { create(:company, name: "Cornerstone") }
  let(:organization) { practice.organization }
  let(:acme) { create(:company, organization: organization, name: "Acme Bakery") }
  let(:beta) { create(:company, organization: organization, name: "Beta Builders") }
  let(:mark) { create(:employee, company: practice, first_name: "Mark", last_name: "Santos") }
  let(:benjo) { create(:employee, company: practice, first_name: "Benjo", last_name: "Cruz") }
  let(:loreen) { create(:employee, company: practice, first_name: "Loreen", last_name: "Reyes") }
  let(:settings) do
    ClientProfitabilitySetting.create!(organization: organization, practice_company: practice, tax_prep_service_names: [ "Tax Preparation" ])
  end
  let(:import) { WorkHourImport.create!(organization: organization, range_start: Date.new(2026, 10, 1), range_end: Date.new(2026, 10, 31), status: "succeeded", finished_at: Time.current) }

  def paycheck(employee, pay_date:, gross:, social_security:, medicare:)
    period = PayPeriod.find_by(company: practice, pay_date: pay_date) ||
      create(:pay_period, :committed, company: practice, start_date: pay_date - 14, end_date: pay_date - 5, pay_date: pay_date)
    create(:payroll_item, company: practice, employee: employee, pay_period: period, gross_pay: gross,
           employer_social_security_tax: social_security, employer_medicare_tax: medicare)
  end

  def hours(tax_user_id, hours, client_id: nil, client_name: nil, approval_state: "approved", system_kind: nil, category: "Bookkeeping",
            task: nil, work_date: Date.new(2026, 10, 12))
    WorkHourRow.create!(organization: organization, work_hour_import: import, tax_user_id: tax_user_id, email: "user#{tax_user_id}@example.com",
                        work_date: work_date, tax_client_id: client_id, client_name: client_name || (client_id ? "Tax client #{client_id}" : "Unassigned"),
                        unassigned: client_id.nil?, system_kind: system_kind, category: category, task: task, hours: hours,
                        approval_state: approval_state)
  end

  def issued_invoice(company:, lines:)
    recipient = create(:invoice_recipient, company: company, organization: organization)
    invoice = build(:invoice, company: company, organization: organization, invoice_recipient: recipient,
                    invoice_billing_profile: create(:invoice_billing_profile, organization: organization),
                    service_period_start: Date.new(2026, 10, 1), service_period_end: Date.new(2026, 10, 31), invoice_date: Date.new(2026, 11, 1))
    lines.each_with_index do |(name, amount, kind), index|
      invoice.line_items.build(item_name: name, description: "#{name} – October 2026", quantity: 1, rate: amount, position: index,
                               line_kind: kind || "service_fee")
    end
    invoice.save!
    invoice.issue!(actor: nil)
    invoice
  end

  before do
    FinanceBook.default_for!(organization)
    settings
    paycheck(mark, pay_date: Date.new(2026, 10, 15), gross: 3000, social_security: 186, medicare: 43.5) # 3,229.50
    paycheck(benjo, pay_date: Date.new(2026, 10, 15), gross: 2000, social_security: 124, medicare: 29) # 2,153.00
    paycheck(loreen, pay_date: Date.new(2026, 10, 15), gross: 1000, social_security: 62, medicare: 14.5) # 1,076.50, no Tax user
    paycheck(mark, pay_date: Date.new(2026, 11, 5), gross: 9999, social_security: 0, medicare: 0) # outside the period

    WorkHourClientLink.create!(organization: organization, tax_client_id: 345, disposition: "company", company: acme)
    WorkHourClientLink.create!(organization: organization, tax_client_id: 346, disposition: "company", company: beta)
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 12, disposition: "employee", employee: mark)
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 13, disposition: "employee", employee: benjo)
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 15, disposition: "no_payroll")

    hours(12, 6, client_id: 345, task: "Bank reconciliation")
    hours(12, 2, client_id: 345, approval_state: "pending")
    hours(12, 2, client_id: 346, approval_state: "clock")
    hours(12, 2, client_id: 500, client_name: "Internal – Cornerstone", system_kind: "internal", category: "Admin")
    hours(13, 4, client_id: 346)
    hours(13, 1)
    hours(13, 3, client_id: 999, client_name: "Gamma LLC")
    hours(14, 3, client_id: 345) # Ky: not linked yet, no cost
    hours(15, 1, client_id: 345) # Dafne: not on payroll
    hours(12, 50, client_id: 345, work_date: Date.new(2026, 11, 2)) # outside the period

    issued_invoice(company: acme, lines: [ [ "Monthly bookkeeping", 1000 ], [ "Tax Preparation", 500 ], [ "Reimbursement", 200, "reimbursement" ] ])
    issued_invoice(company: beta, lines: [ [ "Monthly bookkeeping", 800 ] ])
    issued_invoice(company: nil, lines: [ [ "Consulting", 300 ] ])
  end

  def report(**options)
    described_class.new(organization: organization, settings: settings.reload,
                        period: ClientProfitability::Period.parse("2026-10", "2026-10"), **options).call
  end

  def client(result, name)
    result[:clients].find { |line| line[:name] == name }
  end

  it "spreads each person's payroll cost across clients by approved hours and adds fees" do
    result = report

    expect(client(result, "Acme Bakery")).to include(hours: "10.00", pending_hours: "2.00", cost: "1937.70", fees: "1500.00",
                                                    tax_prep_fees: "500.00", other_fees: "1000.00", margin: "-437.70",
                                                    margin_percent: "-29.2", effective_rate: "150.00")
    expect(client(result, "Beta Builders")).to include(hours: "6.00", cost: "1722.40", fees: "800.00", margin: "-922.40")
    expect(result[:overhead]).to include(hours: "2.00", cost: "645.90", spread: false)
    expect(result[:unassigned].map { |line| line.slice(:kind, :name, :hours, :cost) }).to eq([
      { kind: "unlinked_client", name: "Gamma LLC", hours: "3.00", cost: "807.37" },
      { kind: "no_client", name: "No client chosen in Tax", hours: "1.00", cost: "269.13" }
    ])
    expect(result[:unallocated_costs]).to eq([ { employee_id: loreen.id, name: loreen.full_name, reason: "not_linked", cost: "1076.50" } ])
    expect(result[:unlinked_fees]).to eq(fees: "300.00", tax_prep_fees: "0.00")
    expect(result[:totals]).to include(cost: "6459.00", fees: "2600.00", tax_prep_fees: "500.00", margin: "-3859.00", hours: "22.00",
                                       pending_hours: "2.00")
  end

  it "drills down from a client to people and their categories and tasks" do
    people = client(report, "Acme Bakery")[:people]
    expect(people.map { |person| person.slice(:name, :hours, :pending_hours, :cost, :linked) }).to eq([
      { name: "Mark Santos", hours: "6.00", pending_hours: "2.00", cost: "1937.70", linked: true },
      { name: "user14@example.com", hours: "3.00", pending_hours: "0.00", cost: "0.00", linked: false },
      { name: "user15@example.com", hours: "1.00", pending_hours: "0.00", cost: "0.00", linked: true }
    ])
    expect(people.first[:categories]).to eq([
      { category: "Bookkeeping", task: "Bank reconciliation", hours: "6.00", pending_hours: "0.00" },
      { category: "Bookkeeping", task: nil, hours: "0.00", pending_hours: "2.00" }
    ])
  end

  it "costs pending hours only when asked" do
    result = report(cost_pending: true)
    expect(client(result, "Acme Bakery")).to include(hours: "12.00", cost: "2153.00")
    expect(result[:overhead]).to include(cost: "538.25")
    expect(result[:totals]).to include(cost: "6459.00")
  end

  it "spreads overhead across clients by hours without changing the total" do
    result = report(spread_overhead: true)
    expect(client(result, "Acme Bakery")).to include(direct_cost: "1937.70", overhead_cost: "403.69", cost: "2341.39")
    expect(client(result, "Beta Builders")).to include(overhead_cost: "242.21", cost: "1964.61")
    expect(result[:overhead]).to include(spread: true, cost: "645.90")
    expect(result[:totals]).to include(cost: "6459.00")
  end

  it "summarizes each person's cost per hour and flags people who aren't linked" do
    staff = report[:staff].to_h { |person| [ person[:name], person.slice(:status, :cost, :hours, :cost_per_hour) ] }
    expect(staff.fetch("Mark Santos")).to eq(status: "employee", cost: "3229.50", hours: "10.00", cost_per_hour: "322.95")
    expect(staff.fetch("user14@example.com")).to eq(status: "not_linked", cost: nil, hours: "3.00", cost_per_hour: nil)
    expect(staff.fetch("user15@example.com")).to eq(status: "no_payroll", cost: nil, hours: "1.00", cost_per_hour: nil)
  end

  it "reports months that haven't been pulled from Tax" do
    result = described_class.new(organization: organization, settings: settings,
                                 period: ClientProfitability::Period.parse("2026-10", "2026-11")).call
    expect(result[:coverage]).to include(missing_months: [ "2026-11" ], missing_month_labels: [ "November 2026" ])
  end

  it "keeps a person's pay unassigned when they logged no hours" do
    WorkHourRow.where(tax_user_id: 13).delete_all
    entry = report[:unallocated_costs].find { |cost| cost[:employee_id] == benjo.id }
    expect(entry).to include(reason: "no_hours", cost: "2153.00")
  end

  it "counts an employee's cost once when two Tax identities point at them" do
    WorkHourStaffLink.create!(organization: organization, tax_user_id: 16, disposition: "employee", employee: mark)
    hours(16, 4, client_id: 346)
    result = report
    marks = result[:staff].select { |person| person[:name] == "Mark Santos" }
    expect(marks.length).to eq(1)
    expect(marks.first).to include(cost: "3229.50", hours: "14.00", tax_user_ids: [ 12, 16 ])
    expect(result[:totals]).to include(cost: "6459.00")
  end

  it "stops reading a practice company that was moved to another organization" do
    other = create(:organization)
    practice.update_columns(organization_id: other.id)
    result = report
    expect(result[:practice_company]).to be_nil
    expect(result[:totals]).to include(cost: "0.00")
    expect(ClientProfitability::LinkQueue.new(organization: organization, settings: settings.reload).practice_employees).to eq([])
  end

  it "ignores unlinked (inactive) links" do
    WorkHourClientLink.find_by(tax_client_id: 345).update!(active: false)
    result = report
    expect(client(result, "Acme Bakery")).to include(hours: "0.00", fees: "1500.00")
    expect(result[:unassigned].map { |line| line[:name] }).to include("Tax client 345")
  end

  it "shows $0.00 fees per hour for a client with work but no billing" do
    unbilled = create(:company, organization: organization, name: "Unbilled Co")
    WorkHourClientLink.create!(organization: organization, tax_client_id: 999, disposition: "company", company: unbilled)
    line = client(report, "Unbilled Co")
    expect(line).to include(hours: "3.00", fees: "0.00", cost: "807.38", margin: "-807.38", margin_percent: nil, effective_rate: "0.00")
    expect(report[:overhead]).to include(hours: "2.00", effective_rate: "0.00")
  end

  it "reads both totals for the Annual Payroll Summary comparison in one REPEATABLE READ snapshot" do
    settings.update!(cost_basis: "work_period")
    allow(ApplicationRecord.connection).to receive(:transaction_open?).and_return(false)
    allow(ApplicationRecord).to receive(:transaction).and_call_original
    allow(ApplicationRecord).to receive(:transaction).with(isolation: :repeatable_read) { |&block| block.call }
    allow_any_instance_of(AnnualPayrollSummary).to receive(:payroll_cost_by_employee).and_wrap_original do |original, *args, **options|
      expect(ApplicationRecord).to have_received(:transaction).with(isolation: :repeatable_read)
      original.call(*args, **options)
    end
    result = report
    expect(result[:cost_basis]).to include(basis: "work_period")
    expect(ApplicationRecord).to have_received(:transaction).with(isolation: :repeatable_read).once
  end

  it "gives an invoice customer with no Payroll client its own row: fees, hours, cost and margin" do
    customer = Invoice.find_by!(organization_id: organization.id, company_id: nil).invoice_recipient
    WorkHourClientLink.create!(organization: organization, tax_client_id: 999, disposition: "recipient", invoice_recipient: customer)

    result = report
    line = result[:clients].find { |client| client[:kind] == "recipient" }
    expect(line).to include(name: customer.name, invoice_recipient_id: customer.id, company_id: nil, hours: "3.00", fees: "300.00",
                            cost: "807.37", margin: "-507.37", margin_percent: "-169.1", effective_rate: "100.00")
    expect(line[:people].map { |person| person[:name] }).to eq([ "Benjo Cruz" ])
    expect(result[:unassigned].map { |entry| entry[:name] }).not_to include("Gamma LLC")
    expect(result[:unlinked_fees]).to eq(fees: "0.00", tax_prep_fees: "0.00")
    # Nothing is counted twice or lost: the totals are the same as before linking.
    expect(result[:totals]).to include(cost: "6459.00", fees: "2600.00", hours: "22.00")
  end

  it "spreads overhead onto an invoice-customer row like any client" do
    customer = Invoice.find_by!(organization_id: organization.id, company_id: nil).invoice_recipient
    WorkHourClientLink.create!(organization: organization, tax_client_id: 999, disposition: "recipient", invoice_recipient: customer)
    result = report(spread_overhead: true)
    shares = result[:clients].sum(BigDecimal("0")) { |client| client[:overhead_cost].to_d }
    expect(shares).to eq(BigDecimal("645.90"))
    expect(result[:clients].find { |client| client[:kind] == "recipient" }[:overhead_cost].to_d).to be_positive
    expect(result[:totals]).to include(cost: "6459.00")
  end

  it "shows a client with fees but no hours" do
    WorkHourRow.where(tax_client_id: 346).delete_all
    expect(client(report, "Beta Builders")).to include(hours: "0.00", cost: "0.00", fees: "800.00", margin: "800.00", effective_rate: nil)
  end
end

RSpec.describe ClientProfitability::Allocation do
  it "splits to the cent and always adds back up" do
    parts = described_class.split(BigDecimal("100"), a: 1, b: 1, c: 1)
    expect(parts.values.sum).to eq(100)
    expect(parts.values.sort).to eq([ BigDecimal("33.33"), BigDecimal("33.33"), BigDecimal("33.34") ])
    expect(described_class.split(BigDecimal("10"), a: 0)).to eq({})
  end
end

RSpec.describe ClientProfitability::Period do
  it "parses whole months and rejects bad input" do
    period = described_class.parse("2026-10", "2026-12")
    expect([ period.start_date, period.end_date, period.label ]).to eq([ Date.new(2026, 10, 1), Date.new(2026, 12, 31), "October 2026 – December 2026" ])
    expect { described_class.parse("2026-13", nil) }.to raise_error(ArgumentError, /month like/)
    expect { described_class.parse("2026-10", "2026-09") }.to raise_error(ArgumentError, /on or after/)
    expect { described_class.parse("2024-01", "2026-12") }.to raise_error(ArgumentError, /at most 24/)
  end
end

RSpec.describe InvoiceServiceFeeRevenue do
  it "splits out tax-prep fees by service name with the invoice discount, and leaves the default output alone" do
    invoice = create(:invoice, discount_type: "percent", discount_value: 10)
    invoice.line_items.build(item_name: "Bookkeeping", description: "Books", quantity: 1, rate: 600, position: 0)
    invoice.line_items.build(item_name: " tax  preparation ", description: "Form 1040", quantity: 1, rate: 400, position: 1)
    invoice.save!
    invoice.issue!(actor: nil)

    plain = described_class.call(finance_book: invoice.finance_book)
    expect(plain).to eq([ { company_id: invoice.company_id, service_month: Date.new(2026, 5, 1), amount: BigDecimal("900") } ])
    split = described_class.call(finance_book: invoice.finance_book, tax_prep_service_names: [ "Tax Preparation" ])
    expect(split.first).to include(amount: BigDecimal("900"), tax_prep_amount: BigDecimal("360"))
    expect(described_class.call(finance_book: invoice.finance_book, tax_prep_service_names: []).first[:tax_prep_amount]).to eq(0)
  end
end

RSpec.describe WorkHourStaffLink do
  it "only links employees of the organization's current staff payroll client" do
    practice = create(:company)
    other = create(:company, organization: practice.organization)
    ClientProfitabilitySetting.create!(organization: practice.organization, practice_company: practice)
    inside = described_class.new(organization: practice.organization, tax_user_id: 1, disposition: "employee",
                                 employee: create(:employee, company: practice))
    outside = described_class.new(organization: practice.organization, tax_user_id: 2, disposition: "employee",
                                  employee: create(:employee, company: other))
    expect(inside).to be_valid
    expect(outside).not_to be_valid
    expect(outside.errors[:employee].join).to match(/staff payroll/)
  end
end

RSpec.describe WorkHourClientLink do
  let(:company) { create(:company) }
  let(:organization) { company.organization }
  let(:book) { FinanceBook.default_for!(organization) }
  let(:customer) { create(:invoice_recipient, organization: organization, company: nil, finance_book: book, name: "Roland's Watch Repair (Ponce)") }

  it "links an invoice customer that has no Payroll client, and nothing else" do
    expect(described_class.new(organization: organization, tax_client_id: 1, disposition: "recipient", invoice_recipient: customer)).to be_valid
    with_client = create(:invoice_recipient, organization: organization, company: company, finance_book: book)
    expect(described_class.new(organization: organization, tax_client_id: 2, disposition: "recipient", invoice_recipient: with_client))
      .not_to be_valid
    elsewhere = create(:invoice_recipient, company: nil, organization: create(:organization))
    expect(described_class.new(organization: organization, tax_client_id: 3, disposition: "recipient", invoice_recipient: elsewhere))
      .not_to be_valid
    expect(described_class.new(organization: organization, tax_client_id: 4, disposition: "company", company: company, invoice_recipient: customer))
      .not_to be_valid
  end

  it "is backed by the database check on dispositions" do
    link = described_class.create!(organization: organization, tax_client_id: 5, disposition: "recipient", invoice_recipient: customer)
    expect { described_class.transaction(requires_new: true) { link.update_columns(invoice_recipient_id: nil) } }
      .to raise_error(ActiveRecord::CheckViolation)
    expect { described_class.transaction(requires_new: true) { link.reload.update_columns(company_id: company.id) } }
      .to raise_error(ActiveRecord::CheckViolation)
  end
end
