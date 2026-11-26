# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::Adapters::MosaRevel, "layout descriptor" do
  let(:descriptor) { YAML.safe_load_file(Rails.root.join("config/payroll_intake/mosa_revel.yml")) }
  let(:excel_parser) { PayrollImport::LoanTipExcelParser }

  it "agrees with the current source roles, extensions, overtime policy, and period length" do
    expect(descriptor.values_at("key", "parser_version")).to eq([ described_class::SOURCE_TYPE, described_class::PARSER_VERSION ])
    expect(descriptor.fetch("files").keys).to eq(described_class.default_required_source_roles)
    descriptor.fetch("files").each do |role, definition|
      definition.fetch("extensions").each do |extension|
        expect(described_class.source_role_for(filename: "fixture#{extension}", content_type: nil)).to eq(role)
      end
      expect(definition["waiver_label"]).to eq(described_class.source_roles.fetch(role)[:waiver_label])
    end
    expect(descriptor.dig("pay_period", "length_days")).to eq(PayrollIntake::WorkweekEvidence::PERIOD_DAYS)
    expect(descriptor.dig("pay_period", "source_reports_overtime")).to eq(described_class.reports_overtime?)
  end

  it "agrees with the PDF parser's fixed columns and synthetic report header" do
    offsets = PayrollImport::RevelPdfParser::COLUMNS.transform_keys(&:to_s).transform_values { |range| [ range.begin, range.end ] }
    expect(descriptor.dig("revel_hours", "columns_zero_based_inclusive")).to eq(offsets)
    expect(RevelPdfFixtureHelper::REVEL_HEADER).to match(Regexp.new(descriptor.dig("revel_hours", "header_pattern"), Regexp::IGNORECASE))
  end

  it "agrees with the parser's accepted workbook versions, legacy sheet names, and one-time pay codes" do
    expect(descriptor.dig("workbook", "generated", "schema_versions"))
      .to eq(PayrollImport::MosaSupplementalTemplate::SUPPORTED_SCHEMA_VERSIONS)
    expect(descriptor.dig("workbook", "legacy", "sheets").keys).to eq([
      excel_parser::TIPS_BOH_SHEET, excel_parser::TIPS_FOH_SHEET, excel_parser::LOANS_SHEET,
      excel_parser::INSTALLMENT_SHEET, excel_parser::BONUS_SHEET
    ])
    expect(descriptor.dig("workbook", "legacy", "skipped_sheets")).to eq(excel_parser::SKIP_SHEETS)
    expect(descriptor.dig("workbook", "generated", "one_time_pay_codes"))
      .to eq(excel_parser::GENERATED_COMPONENT_TYPES.transform_values { |rule| rule.fetch(:tax_treatment) })
  end

  it "matches the production generator and the frozen v2 fixture at the workbook layout level" do
    layout = descriptor.dig("workbook", "generated")
    run = create(:pay_period)
    download = PayrollImport::MosaSupplementalTemplate.new(run).generate
    fixture = Rails.root.join("spec/fixtures/files/payroll_intake_golden/normal.xlsx").binread

    [ download, fixture ].each do |bytes|
      workbook = Roo::Excelx.new(StringIO.new(bytes))
      expect(workbook.sheets).to eq([ layout.fetch("detection_sheet"), *layout.fetch("sheets").keys ])
      expect(workbook.sheet(layout.fetch("detection_sheet")).column(1)[3, 13]).to eq(layout.fetch("metadata_labels"))
      layout.fetch("sheets").each do |name, sheet|
        expect(workbook.sheet(name).row(layout.fetch("header_row"))).to eq(sheet.fetch("columns"))
      end

      Zip::File.open_buffer(bytes) do |zip|
        xml = Nokogiri::XML(zip.read("xl/worksheets/sheet1.xml"))
        expect(xml.xpath("//*[local-name()='mergeCell']/@ref").map(&:value)).to eq(layout.fetch("merged_ranges"))
      end
    end
  end
end
