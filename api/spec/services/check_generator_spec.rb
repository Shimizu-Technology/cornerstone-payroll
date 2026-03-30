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
      pay_rate: 15.24)
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
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee, :y)).to eq(180.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :amount, :y)).to eq(182.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :amount_words, :y)).to eq(156.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :memo, :y)).to eq(64.0)
    end

    it "uses compact stub row positions that stay within each third" do
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row1_y)).to eq(252.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row2_y)).to eq(188.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :row3_y)).to eq(128.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :table_height)).to eq(56.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :summary_box_h)).to eq(48.0)
      expect(CheckGenerator::DEFAULT_LAYOUT.dig(:stub, :summary_x_offset)).to eq(-18.0)
    end
  end
end
