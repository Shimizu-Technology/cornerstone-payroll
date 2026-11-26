# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::Registry do
  after { described_class.reset! }

  it "registers the built-in descriptors backed by mosa_revel.yml and SpikeEmail" do
    expect(described_class.keys).to contain_exactly("mosa_revel", "spike_email")

    mosa = described_class.fetch("mosa_revel")
    expect(mosa).to have_attributes(
      key: "mosa_revel",
      label: "Revel hours + Cornerstone workbook",
      source_label: "MoSa Revel hours and payroll changes",
      parser_version: "mosa_revel:v1",
      adapter_class: PayrollIntake::Adapters::MosaRevel,
      extraction: "deterministic",
      idempotency: "files_period_roster_loans_and_workweek"
    )
    expect(mosa.reports_overtime?).to be(true)
    expect(mosa.deterministic?).to be(true)
    expect(mosa.accepts_pasted_text?).to be(false)
    expect(mosa.portal_submittable?).to be(true)
    expect(mosa.portal_role_map).to eq("revel_payroll" => "revel_hours", "changes_workbook" => "supplemental_workbook")
    expect(mosa.default_required_source_roles).to eq(%w[revel_hours supplemental_workbook])
    expect(mosa.source_role_for(filename: "report.pdf", content_type: nil)).to eq("revel_hours")
    expect(mosa.source_role_for(filename: "changes.xlsx", content_type: nil)).to eq("supplemental_workbook")
    expect(mosa.source_role_for(filename: "notes.txt", content_type: "text/plain")).to eq("supporting_document")

    spike = described_class.fetch("spike_email")
    expect(spike).to have_attributes(
      key: "spike_email",
      parser_version: "spike_email:v3",
      adapter_class: PayrollIntake::Adapters::SpikeEmail,
      extraction: "text_and_ai"
    )
    expect(spike.reports_overtime?).to be(false)
    expect(spike.accepts_pasted_text?).to be(true)
    expect(spike.portal_submittable?).to be(false)
    expect(spike.default_required_source_roles).to eq([])
  end

  it "raises UnknownAdapterError for unregistered keys" do
    expect(described_class.find("unknown_adapter")).to be_nil
    expect(described_class.registered?("unknown_adapter")).to be(false)
    expect { described_class.fetch("unknown_adapter") }.to raise_error(described_class::UnknownAdapterError)
  end

  it "lets future adapters register dynamically and become discoverable across intake checks" do
    custom_adapter = Class.new do
      def self.descriptor
        @descriptor ||= PayrollIntake::Descriptor.new(
          key: "synthetic_workbook",
          label: "Synthetic universal workbook",
          parser_version: "synthetic_workbook:v1",
          adapter_class: self,
          extraction: "deterministic",
          idempotency: "files_and_workweek",
          reports_overtime: true,
          files: [
            {
              role: "universal_workbook",
              label: "Cornerstone workbook",
              accept: %w[.xlsx .csv],
              max: 1,
              required_by_default: true,
              portal_role: "payroll_workbook",
              provides: %w[regular_hours overtime_hours reported_tips]
            }
          ],
          portal: { submittable: true, role_map: { "payroll_workbook" => "universal_workbook" } }
        )
      end
    end

    described_class.register(custom_adapter)

    expect(described_class.registered?("synthetic_workbook")).to be(true)
    expect(described_class.adapter_for("synthetic_workbook")).to eq(custom_adapter)
    expect(OperatingProfileCatalog.registered_intake_adapters).to include("synthetic_workbook")
    expect(PayrollIntake::SourceCompleteness.default_required_roles("synthetic_workbook")).to eq([ "universal_workbook" ])
    expect(PayrollIntake::PreviewService.source_reports_overtime?("synthetic_workbook")).to be(true)

    company = create(:company, payroll_intake_source_types: [ "synthetic_workbook" ])
    expect(described_class.for_company(company).map(&:key)).to eq([ "synthetic_workbook" ])

    profile = PayrollIntake::ProfileBuilder.new(company: company).call
    expect(profile.fetch("adapters").pluck("key")).to eq([ "synthetic_workbook" ])
  end
end
