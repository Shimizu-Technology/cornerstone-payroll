# frozen_string_literal: true

require "rails_helper"

# Every generator that prints a worker, payee or client name must build its PDF
# for names outside Windows-1252 and keep the characters intact.
RSpec.describe "PDF generators with accented and non-Latin names" do
  let(:company) do
    create(:company, name: "Hagåtña Café Mañibusan", address_line1: "1 Marine Corps Dr", city: "Hagåtña",
      state: "GU", zip: "96910", bank_name: "Bank of Guam", next_check_number: 2001, check_stock_type: "bottom_check")
  end
  let(:pay_period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14), pay_date: Date.new(2026, 3, 19))
  end
  let!(:employees) do
    UnicodePdfNames::WORKERS.map do |worker|
      create(:employee, company: company, first_name: worker[:first_name], last_name: worker[:last_name],
        employment_type: "hourly", pay_rate: 15, address_line1: "12 Chalan Santo Papa", city: "Hagåtña",
        state: "GU", zip: "96910")
    end
  end
  let!(:payroll_items) do
    employees.each_with_index.map do |employee, index|
      create(:payroll_item, :with_check, pay_period: pay_period, employee: employee, check_number: (2001 + index).to_s,
        pay_rate: 15, hours_worked: 80, gross_pay: 1200, net_pay: 1000, withholding_tax: 100,
        social_security_tax: 74.4, medicare_tax: 17.4, total_deductions: 200)
    end
  end
  let(:primary_item) { payroll_items.find { |item| item.employee.last_name == "Wiśniewska" } }

  def expect_names(bytes, tokens = UnicodePdfNames::TOKENS)
    expect(bytes).to start_with("%PDF")
    text = unicode_pdf_text(bytes)
    tokens.each { |token| expect(text).to include(token), "missing #{token.inspect} in: #{text.first(400)}" }
  end

  it "prints a pay stub" do
    expect_names(PayStubGenerator.new(primary_item).generate, %w[Aleksandra Wiśniewska Hagåtña])
  end

  it "prints a paper check and its stubs" do
    expect_names(CheckGenerator.new(primary_item).generate, %w[Wiśniewska Hagåtña])
  end

  it "prints a First Hawaiian four-up check sheet" do
    items = payroll_items.first(3)
    expect_names(FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: items).generate,
      %w[Wiśniewska Mañibusan Nguyễn])
  end

  it "prints the paycheck history" do
    expect_names(PaycheckHistoryPdfGenerator.new(pay_period).generate)
  end

  it "prints the payroll summary by employee" do
    expect_names(PayrollSummaryByEmployeePdfGenerator.new(pay_period).generate)
  end

  it "prints the deductions and contributions report" do
    expect(DeductionsContributionsReportPdfGenerator.new(pay_period).generate).to start_with("%PDF")
  end

  it "prints the retirement plans report" do
    expect(RetirementPlansReportPdfGenerator.new(pay_period).generate).to start_with("%PDF")
  end

  it "prints the transmittal log" do
    expect(unicode_pdf_text(TransmittalLogPdfGenerator.new(pay_period).generate)).to include("Hagåtña Café Mañibusan")
  end

  it "prints the check sign-off sheet" do
    expect(CheckSignoffPdfGenerator.new(pay_period).generate).to start_with("%PDF")
  end

  it "prints the installment loan report" do
    employee = primary_item.employee
    EmployeeLoan.create!(company: company, employee: employee, name: "Préstamo Mañibusan", original_amount: 200,
      current_balance: 200, payment_amount: 25, start_date: Date.new(2026, 1, 1), status: "active")
    expect_names(InstallmentLoanReportPdfGenerator.new(company, as_of_date: Date.new(2026, 3, 1)).generate,
      %w[Wiśniewska Préstamo Mañibusan])
  end

  it "prints a non-employee check and voucher" do
    check = create(:non_employee_check, :with_check_number, company: company, payable_to: "Tano Builders Đức Ştefan")
    expect_names(NonEmployeeCheckGenerator.new(check).generate, %w[Đức Ştefan])
    expect_names(NonEmployeeCheckVoucherGenerator.new(check).generate, %w[Đức Ştefan])
  end

  it "prints an invoice for a client with an accented name" do
    invoice = create(:invoice, :with_line_item, company: company)
    invoice.invoice_recipient.update!(name: "Mañibusan Ştefănescu Trading")
    expect_names(InvoicePdfGenerator.new(invoice.reload).generate, %w[Mañibusan Ştefănescu])
  end

  it "prints a general transmittal" do
    transmittal = create(:general_transmittal, :with_item, company: company, recipient_name: "Jesús Mañibusan",
      title: "Q1 packet for Nguyễn Hương")
    expect_names(GeneralTransmittalPdfGenerator.new(transmittal).generate, %w[Mañibusan Nguyễn])
  end

  it "refuses checks and tax summaries whose names would print as empty boxes" do
    primary_item.employee.update!(first_name: "小明", last_name: "王")
    unprintable = [ PdfUnicodeFont::UnprintableName, /Employee "小明 王".*\(小 明 王\).*Latin letters/ ]

    expect { CheckGenerator.new(primary_item.reload).generate }.to raise_error(*unprintable)
    expect { FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: [ primary_item ]).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Payee "小明 王"/)

    check = create(:non_employee_check, :with_check_number, company: company, payable_to: "김민수 Builders")
    expect { NonEmployeeCheckGenerator.new(check).generate }.to raise_error(PdfUnicodeFont::UnprintableName, /\(김 민 수\)/)
    expect { NonEmployeeCheckVoucherGenerator.new(check).generate }.to raise_error(PdfUnicodeFont::UnprintableName)

    primary_item.employee.update!(first_name: "Aleksandra", last_name: "Wiśniewska", address_line1: "12 마을 Rd")
    expect { CheckGenerator.new(primary_item.reload).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Employee address .*\(마 을\)/)

    expect { W2GuPdfGenerator.new({ employees: [ { employee_name: "王小明" } ] }).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Employee "王小明"/)
    expect { W2GuPdfGenerator.new({ employees: [ { employee_name: "Kim Lee", employee_address: "1-2 東京都" } ] }).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Employee address "1-2 東京都"/)
    expect { W2GuPdfGenerator.new({ employer: { name: "王商事" }, employees: [] }).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Employer "王商事"/)
    expect { Form1099NecPdfGenerator.new({ payer: { name: "王商事" }, reportable_contractors: [] }).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Payer "王商事"/)
    expect { Form1099NecPdfGenerator.new({ reportable_contractors: [ { name: "Kim", business_name: "김 Trading" } ] }).generate }
      .to raise_error(PdfUnicodeFont::UnprintableName, /Contractor business "김 Trading"/)
  end

  it "prints CJK and Hangul names without failing the document" do
    primary_item.employee.update!(first_name: "小明", last_name: "王")
    other = payroll_items.last.employee
    other.update!(first_name: "민수", last_name: "김")

    expect(PayStubGenerator.new(primary_item.reload).generate).to start_with("%PDF")
    expect(PayrollSummaryByEmployeePdfGenerator.new(pay_period).generate).to start_with("%PDF")
  end
end
