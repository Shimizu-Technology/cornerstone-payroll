# frozen_string_literal: true

require "rails_helper"

RSpec.describe NonEmployeeCheckGenerator do
  let(:company) do
    create(:company,
      name: "MoSa's Restaurant",
      check_stock_type: "bottom_check",
      check_offset_x: 0,
      check_offset_y: 0,
      check_layout_config: {
        check_face: {
          payee: { x: 86.0, width: 280.0 }
        }
      })
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

  it "keeps normal non-employee check output on the legacy layout" do
    field = described_class.new(check).send(:layout_field, :payee)

    expect(field).to eq(NonEmployeeCheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee))
  end

  it "can apply draft layout overrides for settings-page test previews only" do
    field = described_class.new(check, layout_config: company.check_layout_config).send(:layout_field, :payee)

    expect(field[:x]).to eq(86.0)
    expect(field[:width]).to eq(280.0)
    expect(field[:font_size]).to eq(NonEmployeeCheckGenerator::DEFAULT_LAYOUT.dig(:check_face, :payee, :font_size))
  end

  it "generates a valid PDF when draft preview overrides are supplied" do
    pdf = described_class.new(check, layout_config: company.check_layout_config).generate

    expect(pdf).to start_with("%PDF")
  end
end
