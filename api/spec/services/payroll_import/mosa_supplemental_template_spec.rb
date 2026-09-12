# frozen_string_literal: true

require "rails_helper"
require "caxlsx"

RSpec.describe PayrollImport::MosaSupplementalTemplate do
  let(:company) { create(:company, name: "MoSa Test", payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 9, 13),
      end_date: Date.new(2026, 9, 26),
      pay_date: Date.new(2026, 10, 2)
    )
  end

  def workbook_from(bytes)
    file = Tempfile.new([ "mosa-change-template", ".xlsx" ])
    file.binmode
    file.write(bytes)
    file.close
    [ Roo::Spreadsheet.open(file.path), file ]
  end

  it "generates a period-bound workbook prefilled with stable employee IDs" do
    employee = create(
      :employee,
      company: company,
      first_name: "Avery",
      last_name: "Example",
      employment_type: "salary",
      salary_type: "variable",
      pay_rate: 0
    )
    generator = described_class.new(pay_period)
    workbook, file = workbook_from(generator.generate)

    expect(workbook.sheets).to contain_exactly(
      "START HERE",
      described_class::EMPLOYEE_CHANGES_SHEET,
      described_class::OWNER_PERIOD_PAY_SHEET,
      described_class::ONE_TIME_COMPONENTS_SHEET,
      described_class::DEDUCTIONS_LOANS_SHEET
    )
    start = workbook.sheet("START HERE")
    metadata = (1..start.last_row).to_h { |row| [ start.cell(row, 1), start.cell(row, 2) ] }
    expect(metadata).to include(
      "Schema version" => described_class::SCHEMA_VERSION,
      "Company ID" => company.id,
      "Pay period start" => pay_period.start_date,
      "Pay period end" => pay_period.end_date,
      "Pay date" => pay_period.pay_date
    )
    changes = workbook.sheet(described_class::EMPLOYEE_CHANGES_SHEET)
    expect(changes.row(2).first(3)).to eq([ employee.id, employee.full_name, employee.department.name ])
    owner_pay = workbook.sheet(described_class::OWNER_PERIOD_PAY_SHEET)
    expect(owner_pay.row(2).first(5)).to eq([ employee.id, employee.full_name, nil, "THIS EMPLOYEE ONLY", pay_period.pay_date ])
    components = workbook.sheet(described_class::ONE_TIME_COMPONENTS_SHEET)
    expect(components.row(2).first(2)).to eq([ employee.id, employee.full_name ])
    expect(components.row(3).first(2)).to eq([ employee.id, employee.full_name ])
    expect(generator.filename).to eq("mosa-test-payroll-changes-2026-09-26.xlsx")
  ensure
    file&.unlink
  end

  it "prefills active recurring components as reviewable reference rows" do
    employee = create(:employee, company: company, first_name: "Sarah", last_name: "Owner")
    definition = create(
      :payroll_field_definition,
      company: company,
      name: "401k employee",
      kind: "deduction",
      tax_treatment: "pre_tax_deduction",
      category: "retirement",
      amount_type: "fixed"
    )
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: definition, amount: 125)

    workbook, file = workbook_from(described_class.new(pay_period).generate)
    row = workbook.sheet(described_class::DEDUCTIONS_LOANS_SHEET).row(2)

    expect(row.first(9)).to eq([
      employee.id, employee.full_name, definition.id, definition.name, "retirement", 125,
      "KEEP", nil, pay_period.pay_date
    ])
  ensure
    file&.unlink
  end
end

RSpec.describe PayrollImport::LoanTipExcelParser, "generated MoSa template" do
  def generated_workbook(employee_id:, employee_name:, period_start: Date.new(2026, 9, 13), period_end: Date.new(2026, 9, 26), pay_date: Date.new(2026, 10, 2), no_changes: "NO", owner_scope: "THIS EMPLOYEE ONLY", include_other_changes: true, schema_version: PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION, owner_period_pay: BigDecimal("9000.00"), tips_boh: nil, tips_foh: nil, recurring_loan_amount: nil)
    file = Tempfile.new([ "generated-mosa-changes", ".xlsx" ])
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |sheet|
      [
        [ "Schema version", schema_version ],
        [ "Company ID", 44 ],
        [ "Pay period start", period_start ],
        [ "Pay period end", period_end ],
        [ "Pay date", pay_date ],
        [ "Template revision", 2 ],
        [ "Prior revision replaced", 1 ],
        [ "Submitter", "Payroll contact" ],
        [ "Submitted at", "2026-09-27T09:00:00+10:00" ],
        [ "Revel filename", "payroll_2026-09-13_to_2026-09-26.pdf" ],
        [ "No supplemental changes? (YES/NO)", no_changes ],
        [ "Attestation", "Confirmed" ]
      ].each { |row| sheet.add_row(row) }
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) do |sheet|
      sheet.add_row(Array.new(8) { |index| "Header #{index}" })
      if include_other_changes || !tips_boh.nil? || !tips_foh.nil?
        sheet.add_row([ employee_id, employee_name, "FOH", tips_boh || 10, tips_foh || 25, "YES", "Email approval", "Test change" ])
      end
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::OWNER_PERIOD_PAY_SHEET) do |sheet|
      sheet.add_row(Array.new(7) { |index| "Header #{index}" })
      sheet.add_row([ employee_id, employee_name, owner_period_pay, owner_scope, pay_date, "Owner instruction", "Separate amount" ]) unless owner_period_pay.nil?
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::ONE_TIME_COMPONENTS_SHEET) do |sheet|
      sheet.add_row(Array.new(10) { |index| "Header #{index}" })
      if include_other_changes
        sheet.add_row([ employee_id, employee_name, "REIMBURSEMENT", "Travel reimbursement", 150, "reimbursement", nil, pay_date, "Approved receipt", "September travel" ])
        sheet.add_row([ employee_id, employee_name, "POST-TAX DEDUCTION", "Uniform repayment", 20, "other", "MoSa", pay_date, "Signed instruction", nil ])
      end
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) do |sheet|
      sheet.add_row(Array.new(17) { |index| "Header #{index}" })
      if include_other_changes || !recurring_loan_amount.nil?
        amount = recurring_loan_amount || 5
        opening = include_other_changes ? 300 : 0
        payment = include_other_changes ? 50 : 0
        ending = include_other_changes ? 250 : 0
        sheet.add_row([ employee_id, employee_name, 9, "Owner loan", "loan", 50, "KEEP", amount, Date.new(2026, 9, 13), nil, opening, 0, payment, ending, "MoSa", "Signed schedule", nil ])
      end
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::HOUR_CORRECTIONS_SHEET) do |sheet|
      sheet.add_row(Array.new(10) { |index| "Header #{index}" })
    end
    package.serialize(file.path)
    file
  end

  [ nil, "cornerstone-mosa-supplemental/typo" ].each do |schema_version|
    label = schema_version.nil? ? "blank" : "misspelled"

    it "rejects a #{label} schema when START HERE is present" do
      file = generated_workbook(employee_id: 44, employee_name: "Avery Example", schema_version: schema_version)

      expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /version is not supported/)
    ensure
      file&.unlink
    end
  end

  it "treats negative tips and loan amounts as changes when no changes is attested" do
    negative_tips = generated_workbook(
      employee_id: 44,
      employee_name: "Avery Example",
      no_changes: "YES",
      include_other_changes: false,
      owner_period_pay: nil,
      tips_boh: BigDecimal("-1.00"),
      tips_foh: BigDecimal("0.00")
    )
    negative_loan = generated_workbook(
      employee_id: 44,
      employee_name: "Avery Example",
      no_changes: "YES",
      include_other_changes: false,
      owner_period_pay: nil,
      recurring_loan_amount: BigDecimal("-1.00")
    )

    expect { described_class.parse(negative_tips.path) }.to raise_error(ArgumentError, /says there are no supplemental changes/)
    expect { described_class.parse(negative_loan.path) }.to raise_error(ArgumentError, /says there are no supplemental changes/)
  ensure
    negative_tips&.unlink
    negative_loan&.unlink
  end

  it "accepts zero values when no changes is attested" do
    file = generated_workbook(
      employee_id: 44,
      employee_name: "Avery Example",
      no_changes: "YES",
      include_other_changes: false,
      owner_period_pay: nil,
      tips_boh: BigDecimal("0.00"),
      tips_foh: BigDecimal("0.00"),
      recurring_loan_amount: BigDecimal("0.00")
    )

    expect(described_class.parse(file.path)).to contain_exactly(include(total_tips: BigDecimal("0.00")))
  ensure
    file&.unlink
  end

  it "rejects a combined owner amount" do
    file = generated_workbook(employee_id: 44, employee_name: "Avery Example", owner_scope: "BOTH OWNERS")

    expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /Combined owner amounts are not accepted/)
  ensure
    file&.unlink
  end

  it "parses supported changes by stable employee ID and reconciles loan balances" do
    file = generated_workbook(employee_id: 44, employee_name: "Avery Example")
    parsed = described_class.parse_with_metadata(file.path)

    expect(parsed[:metadata]).to include(
      schema_version: PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION,
      company_id: 44,
      period_start: Date.new(2026, 9, 13),
      period_end: Date.new(2026, 9, 26),
      pay_date: Date.new(2026, 10, 2),
      prior_revision_replaced: "1",
      submitter: "Payroll contact",
      attestation: "Confirmed"
    )
    expect(parsed[:rows]).to contain_exactly(include(
      employee_id: 44,
      employee_name: "Avery Example",
      total_tips: 35.0,
      tips_boh: 10.0,
      tips_foh: 25.0,
      tips_already_paid: true,
      period_pay: 9_000.0,
      period_pay_evidence: include(scope: "THIS EMPLOYEE ONLY", source: "Owner instruction"),
      payroll_components: contain_exactly(
        include(label: "Travel reimbursement", amount: 150.0, tax_treatment: "non_taxable_addition"),
        include(label: "Uniform repayment", amount: 20.0, tax_treatment: "post_tax_deduction", payee_name: "MoSa")
      ),
      one_payroll_deduction: 0.0,
      recurring_loan_deduction: 5.0,
      installment_beginning_balance: 300.0,
      installment_new_amount: 0.0,
      installment_payment: 50.0,
      installment_estimated_ending_balance: 250.0,
      loan_deduction: 55.0
    ))
  ensure
    file&.unlink
  end

  it "rejects recurring setup changes and new loan advances instead of silently treating them as one-payroll deductions" do
    file = generated_workbook(employee_id: 44, employee_name: "Avery Example")
    sheet = Roo::Spreadsheet.open(file.path).sheet(PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET)
    expect(sheet.cell(2, 7)).to eq("KEEP")

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |start|
      start.add_row([ "Schema version", PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION ])
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) { |changes| changes.add_row(Array.new(12)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) do |loans|
      loans.add_row(Array.new(17))
      loans.add_row([ 44, "Avery Example", 9, "Owner loan", "loan", 50, "CHANGE", 75, nil, nil, 300, 25, 75, 250 ])
    end
    package.serialize(file.path)

    expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /must be made and reviewed in Cornerstone/)
  ensure
    file&.unlink
  end

  it "rejects owner pay when the sender attests that there are no supplemental changes" do
    file = generated_workbook(employee_id: 44, employee_name: "Avery Example", no_changes: "YES", include_other_changes: false)

    expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /says there are no supplemental changes/)
  ensure
    file&.unlink
  end

  it "rejects populated hour corrections from an earlier workbook version" do
    file = generated_workbook(employee_id: 44, employee_name: "Avery Example")
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |start|
      start.add_row([ "Schema version", PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION ])
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) { |changes| changes.add_row(Array.new(12)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) { |loans| loans.add_row(Array.new(17)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::HOUR_CORRECTIONS_SHEET) do |hours|
      hours.add_row(Array.new(10))
      hours.add_row([ 44, "Avery Example", Date.new(2026, 9, 14), "regular", "ADD", 2, "Missed punch" ])
    end
    package.serialize(file.path)

    expect { described_class.parse(file.path) }.to raise_error(ArgumentError, /cannot silently change Revel hours/)
  ensure
    file&.unlink
  end

  it "rejects an ending balance that does not reconcile" do
    file = Tempfile.new([ "bad-generated-mosa-changes", ".xlsx" ])
    file_path = file.path
    file.close
    # Build the same source with an intentionally wrong ending balance.
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "START HERE") do |sheet|
      sheet.add_row([ "Schema version", PayrollImport::MosaSupplementalTemplate::SCHEMA_VERSION ])
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::EMPLOYEE_CHANGES_SHEET) { |sheet| sheet.add_row(Array.new(12)) }
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::DEDUCTIONS_LOANS_SHEET) do |sheet|
      sheet.add_row(Array.new(17))
      sheet.add_row([ 44, "Avery Example", 9, "Owner loan", "loan", 50, "CHANGE", nil, nil, nil, 300, 25, 50, 999 ])
    end
    package.workbook.add_worksheet(name: PayrollImport::MosaSupplementalTemplate::HOUR_CORRECTIONS_SHEET) { |sheet| sheet.add_row(Array.new(10)) }
    package.serialize(file_path)

    expect { described_class.parse(file_path) }.to raise_error(ArgumentError, /must equal ending balance/)
  ensure
    file&.unlink
  end
end
