# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, "payroll intake settings" do
  let(:company) { build(:company, payroll_intake_source_types: [ "mosa_revel" ]) }

  it "uses each source's default required files until the client overrides them" do
    expect(company.payroll_intake_required_sources("mosa_revel")).to eq(%w[revel_hours supplemental_workbook])

    company.payroll_intake_settings = { "mosa_revel" => { "required_sources" => [ "revel_hours" ] } }
    expect(company).to be_valid
    expect(company.payroll_intake_required_sources("mosa_revel")).to eq([ "revel_hours" ])
  end

  it "rejects unknown source types and file roles" do
    company.payroll_intake_settings = { "mosa_revel" => { "required_sources" => [ "timesheet" ] } }
    expect(company).not_to be_valid
    expect(company.errors[:payroll_intake_settings].join).to include("unknown mosa_revel source files")

    company.payroll_intake_settings = { "other_source" => {} }
    expect(company).not_to be_valid

    company.payroll_intake_settings = { "mosa_revel" => { "required_sources" => "revel_hours" } }
    expect(company).not_to be_valid
  end
end
