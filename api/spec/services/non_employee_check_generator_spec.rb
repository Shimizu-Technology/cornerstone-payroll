# frozen_string_literal: true

require "rails_helper"

RSpec.describe NonEmployeeCheckGenerator do
  let(:company) do
    create(:company,
      name: "MoSa's Restaurant",
      check_stock_type: "bottom_check",
      check_offset_x: 0,
      check_offset_y: 0)
  end

  let(:check) do
    create(:non_employee_check, :standalone, :with_check_number,
      company: company,
      payable_to: "Treasurer of Guam",
      amount: 438.22,
      check_type: "grt",
      payment_period_type: "month",
      tax_year: 2026,
      tax_month: 5)
  end

  subject(:generator) { described_class.new(check) }

  describe "#generate" do
    it "returns a valid PDF binary" do
      expect(generator.generate).to start_with("%PDF")
    end

    it "uses check layout overrides from the company" do
      company.update!(
        check_layout_config: {
          check_face: {
            payee: { x: 86.0, width: 280.0 }
          }
        }
      )

      field = generator.send(:layout_field, :check_face, :payee)

      expect(field["x"]).to eq(86.0)
      expect(field["width"]).to eq(280.0)
      expect(field["font_size"]).to eq(NonEmployeeCheckGenerator.default_layout_config.dig("check_face", "payee", "font_size"))
    end

    it "falls back to defaults when a custom field override is malformed" do
      company.update!(
        check_layout_config: {
          check_face: {
            payee: "bad override"
          }
        }
      )

      field = generator.send(:layout_field, :check_face, :payee)

      expect(field).to eq(NonEmployeeCheckGenerator.default_layout_config.dig("check_face", "payee"))
    end
  end
end
