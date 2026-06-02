# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe CheckGenerator do
  let(:company) do
    create(:company,
      name: "MoSa's Restaurant",
      address_line1: "123 Marine Drive",
      city: "Tamuning",
      state: "GU",
      zip: "96913",
      bank_name: "Bank of Guam",
      bank_address: "111 W Marine Corps Dr, Tamuning, GU 96913",
      next_check_number: 1042,
      check_stock_type: "bottom_check",
      check_offset_x: 0.0,
      check_offset_y: 0.0)
  end

  let(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 14),
      pay_date: Date.new(2026, 3, 19))
  end

  let(:employee) do
    create(:employee,
      company: company,
      first_name: "John",
      last_name: "Santos",
      employment_type: "hourly",
      pay_rate: 15.24,
      address_line1: "123 Test St",
      city: "Barrigada",
      state: "GU",
      zip: "96913")
  end

  let(:payroll_item) do
    create(:payroll_item, :with_check,
      pay_period: pay_period,
      employee: employee,
      check_number: "1042",
      pay_rate: 15.24,
      hours_worked: 80,
      gross_pay: 1219.20,
      net_pay: 1008.14,
      withholding_tax: 120.00,
      social_security_tax: 75.59,
      medicare_tax: 17.68,
      total_deductions: 213.27)
  end

  subject(:generator) { described_class.new(payroll_item) }

  describe "#generate" do
    subject(:pdf) { generator.generate }

    it "returns a valid PDF binary" do
      expect(pdf).to start_with("%PDF")
    end

    it "produces a non-empty PDF" do
      expect(pdf.bytesize).to be > 5_000
    end

    it "returns a String (binary)" do
      expect(pdf).to be_a(String)
    end

    it "does not print decorative markers or a duplicate memo label on the check face" do
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

      expect(text).not_to include("**")
      expect(text).not_to include("*****")
      expect(text).not_to include("Memo:")
      expect(text).not_to include("BENEFITS")
      expect(text).not_to include("Pay Period:")
    end

    it "prints the employee mailing address on the check face" do
      text = PDF::Reader.new(StringIO.new(pdf)).pages.map(&:text).join("\n")

      expect(text).to include("123 Test St")
      expect(text).to include("Barrigada, GU 96913")
    end

    it "prints tips paid out as a deduction when present" do
      payroll_item.update!(tips_paid_out: 45.0, total_deductions: payroll_item.total_deductions + 45.0)

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Tips Paid Out")
      expect(text).to include("45.00")
    end

    it "prints custom deductions as labeled deductions on the check stubs" do
      payroll_item.update!(
        custom_deductions: [ { "label" => "Cash Advance", "amount" => 40.0 } ],
        total_deductions: payroll_item.total_deductions + 40.0,
        net_pay: payroll_item.net_pay - 40.0
      )

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Cash Advance")
      expect(text).to include("40.00")
    end

    it "prints payroll adjustment deduction YTD values on check stubs" do
      earlier_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 2, 1),
        end_date: Date.new(2026, 2, 14),
        pay_date: Date.new(2026, 2, 19))
      create(:payroll_item,
        pay_period: earlier_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.24,
        payroll_adjustments: [
          { "label" => "Uniform repayment", "amount" => 10.0, "treatment" => "post_tax_deduction", "active" => true }
        ],
        total_deductions: 10.0)
      payroll_item.update!(
        payroll_adjustments: [
          { "label" => "Uniform repayment", "amount" => 15.0, "treatment" => "post_tax_deduction", "active" => true }
        ],
        total_deductions: payroll_item.total_deductions + 15.0,
        net_pay: payroll_item.net_pay - 15.0
      )

      text = PDF::Reader.new(StringIO.new(generator.generate)).pages.map(&:text).join("\n")

      expect(text).to include("Uniform repayment")
      expect(text).to include("15.00")
      expect(text).to include("25.00")
    end
  end

  describe "#generate_voided" do
    subject(:pdf) { generator.generate_voided }

    it "returns a valid PDF binary" do
      expect(pdf).to start_with("%PDF")
    end

    it "produces a non-empty PDF" do
      expect(pdf.bytesize).to be > 5_000
    end
  end

  describe "#alignment_test" do
    subject(:pdf) { generator.alignment_test }

    it "returns a valid PDF binary" do
      expect(pdf).to start_with("%PDF")
    end
  end

  describe "#filename" do
    it "includes the check number" do
      expect(generator.filename).to include("1042")
    end

    it "includes the employee id" do
      expect(generator.filename).to include(employee.id.to_s)
    end

    it "includes the pay date" do
      expect(generator.filename).to include("20260319")
    end
  end

  describe "year-to-date totals" do
    it "limits payroll field YTD totals to the current calendar year" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent"
      )
      prior_year_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2025, 12, 1),
        end_date: Date.new(2025, 12, 14),
        pay_date: Date.new(2025, 12, 19))
      prior_year_item = create(:payroll_item,
        pay_period: prior_year_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.24)
      prior_year_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 90.0,
        source: "manual"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Rent Deduction",
        kind: "deduction",
        tax_treatment: "post_tax_deduction",
        category: "rent",
        amount: 25.0,
        source: "manual"
      )

      entry = payroll_item.payroll_item_field_entries.find { |candidate| candidate.label == "Rent Deduction" }

      expect(generator.send(:ytd_payroll_field_amount, entry)).to eq(25.0)
      expect(generator.send(:ytd_visible_deds)).to eq(generator.send(:ytd)[:deds] + 25.0)
    end

    it "prints taxable payroll field additions with year-to-date amounts in pay rows" do
      field = PayrollFieldDefinition.create!(
        company: company,
        name: "Certification Pay",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other"
      )
      earlier_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 2, 1),
        end_date: Date.new(2026, 2, 14),
        pay_date: Date.new(2026, 2, 19))
      earlier_item = create(:payroll_item,
        pay_period: earlier_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.24)
      earlier_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Certification Pay",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount: 10.0,
        source: "manual"
      )
      payroll_item.payroll_item_field_entries.create!(
        payroll_field_definition: field,
        label: "Certification Pay",
        kind: "addition",
        tax_treatment: "taxable_addition",
        category: "other",
        amount: 25.0,
        source: "manual"
      )

      field_row = generator.send(:pay_rows).find { |row| row.first == "Certification Pay" }

      expect(field_row[3]).to eq("25.00")
      expect(field_row[4]).to eq("35.00")
    end

    it "exclude committed payroll from later pay dates" do
      later_period = create(:pay_period, :committed,
        company: company,
        start_date: Date.new(2026, 4, 1),
        end_date: Date.new(2026, 4, 14),
        pay_date: Date.new(2026, 4, 19))

      create(:payroll_item,
        pay_period: later_period,
        employee: employee,
        company: company,
        employment_type: "hourly",
        pay_rate: 15.24,
        gross_pay: 500.00,
        net_pay: 420.00,
        withholding_tax: 40.00,
        social_security_tax: 31.00,
        medicare_tax: 7.25,
        additional_withholding: 5.00,
        retirement_payment: 10.00,
        roth_retirement_payment: 6.00,
        insurance_payment: 4.00,
        loan_payment: 3.00)

      ytd = generator.send(:ytd)

      expect(ytd[:gross]).to eq(1219.20)
      expect(ytd[:fit]).to eq(120.00)
      expect(ytd[:ss]).to eq(75.59)
      expect(ytd[:med]).to eq(17.68)
      expect(ytd[:net]).to eq(1008.14)
    end
  end

  describe "with top_check stock type" do
    before { company.update!(check_stock_type: "top_check") }

    it "still generates a valid PDF" do
      expect(generator.generate).to start_with("%PDF")
    end
  end

  describe "with non-zero offsets" do
    before { company.update!(check_offset_x: 0.1, check_offset_y: -0.05) }

    it "generates without error" do
      expect { generator.generate }.not_to raise_error
    end
  end

  describe "with layout overrides" do
    before do
      company.update!(
        check_layout_config: {
          check_face: {
            date: { x: 486.0, y: 238.0 },
            payee: { x: 48.0 }
          },
          stub: {
            row1_y: 254.0,
            summary_y_offset: -4.0,
            table_padding_x: 2.0
          }
        }
      )
    end

    it "generates without error" do
      expect { generator.generate }.not_to raise_error
    end

    it "generates an alignment test without error" do
      expect { generator.alignment_test }.not_to raise_error
    end
  end

  describe "default check face layout" do
    it "uses the tuned default field coordinates" do
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :date, :y)).to eq(216.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee, :x)).to eq(64.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee, :y)).to eq(168.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee_address, :y)).to eq(102.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :amount, :y)).to eq(182.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :amount_words, :y)).to eq(136.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :memo, :y)).to eq(64.0)
    end

    it "uses compact stub row positions that stay within each third" do
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row1_y)).to eq(252.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row2_y)).to eq(176.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row3_y)).to eq(118.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :table_height)).to eq(56.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :summary_box_h)).to eq(48.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :summary_x_offset)).to eq(-18.0)
    end
  end
end
