# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

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

  it "uses the shared payroll check-face defaults for printable check fields" do
    default_layout = described_class.default_layout_config.fetch("check_face")
    payroll_layout = CheckGenerator.default_layout_config.fetch("check_face")

    %w[date payee amount amount_words memo].each do |field|
      expect(default_layout.fetch(field)).to eq(payroll_layout.fetch(field))
    end
  end

  it "uses saved company check layout overrides for normal non-employee checks" do
    field = described_class.new(check).send(:layout_field, :payee)

    expect(field["x"]).to eq(86.0)
    expect(field["width"]).to eq(280.0)
    expect(field["y"]).to eq(CheckGenerator.default_layout_config.dig("check_face", "payee", "y"))
    expect(field["font_size"]).to eq(CheckGenerator.default_layout_config.dig("check_face", "payee", "font_size"))
  end

  it "can apply draft layout overrides instead of saved settings for settings-page test previews" do
    draft_layout = { check_face: { payee: { x: 72.5 } } }
    field = described_class.new(check, layout_config: draft_layout).send(:layout_field, :payee)

    expect(field["x"]).to eq(72.5)
    expect(field["width"]).to eq(CheckGenerator.default_layout_config.dig("check_face", "payee", "width"))
    expect(field["font_size"]).to eq(CheckGenerator.default_layout_config.dig("check_face", "payee", "font_size"))
  end

  it "generates a valid PDF when draft preview overrides are supplied" do
    pdf = described_class.new(check, layout_config: company.check_layout_config).generate

    expect(pdf).to start_with("%PDF")
  end
  it "uses the Guam created date in newly rendered stubs and filenames across UTC midnight" do
    check.update_columns(created_at: Time.utc(2026, 10, 21, 14, 42, 58))
    original_attributes = check.reload.attributes
    generator = described_class.new(check)
    bytes = generator.generate
    text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")
    expect(text).to include("Created 10/22/2026")
    expect(generator.filename).to end_with("_20261022.pdf")
    # Existing sealed packages fingerprinted the UTC source date; the new display
    # must not make their immutable saved bytes stale or require regeneration.
    expect(generator.render_input_payload.fetch("reference_rows")).to include([ "Created", "10/21/2026" ])
    expect(check.reload.attributes).to eq(original_attributes)
  end
end
