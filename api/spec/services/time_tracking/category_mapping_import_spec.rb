# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Configured AIRE import categories" do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:employee) { create(:employee, company: company) }
  let(:period) { create(:pay_period, company: company) }
  let(:category) { { key: "aire_solo", name: "Solo" } }
  let(:preview) { TimeTracking::BatchImportPreviewService.new(pay_period: period, source: source) }
  def configure
    TimeTrackingCategoryMapping.create!(company: company, time_tracking_source: source, source_category_key: "solo",
      earning_label: "Flight Hours", import_enabled: true, reviewed_by: actor,
      reason: "Reviewed Solo as Flight Hours configuration", evidence: "Leon November4 category decision")
  end
  it "treats a category and the same earning named with Hours as one match" do
    ground = create(:employee_wage_rate, employee: employee, label: "Ground Instruction Hours", rate: 30)
    create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 30)

    rate, method = preview.send(:find_wage_rate, { key: "aire_ground_instruction", name: "Ground Instruction" }, employee.employee_wage_rates.to_a, employee_id: employee.id)
    expect([ rate, method ]).to eq([ ground, "label" ])
  end

  it "keeps the exactly named earning when both spellings exist" do
    plain = create(:employee_wage_rate, employee: employee, label: "Ground Instruction", rate: 25)
    hours = create(:employee_wage_rate, employee: employee, label: "Ground Instruction Hours", rate: 30)

    expect(preview.send(:find_wage_rate, { key: "aire_ground_instruction", name: "Ground Instruction" }, [ plain, hours ], employee_id: employee.id)).to eq([ plain, "label" ])
  end

  it "estimates a contractor's reported overtime at the contract rate" do
    category = { payroll_rate_cents: 3000, regular_hours: 1, overtime_hours: 2 }

    expect(preview.send(:payroll_gross_delta_cents, [ category ], OvertimePremium.multiplier("contractor"))).to eq(9000)
    expect(preview.send(:payroll_gross_delta_cents, [ category ], OvertimePremium.multiplier("hourly"))).to eq(12000)
  end

  it "uses configured Maintenance first, then Regular, and blocks when neither exists" do
    policy = TimeTrackingCategoryMapping.create!(company: company, time_tracking_source: source, source_category_key: "maintenance",
      earning_label: "Maintenance", fallback_earning_label: "Regular", import_enabled: true, reviewed_by: actor,
      reason: "Reviewed Maintenance then Regular company rule", evidence: "Leon November4 continued historical earning decision")
    regular = create(:employee_wage_rate, employee: employee, label: "Regular", rate: 14.7)
    maintenance = create(:employee_wage_rate, employee: employee, label: "Maintenance", rate: 19)
    expect(policy.matching_rate([ regular, maintenance ])).to eq(maintenance)
    expect(policy.matching_rate([ regular ])).to eq(regular)
    rate, _, message = preview.send(:find_wage_rate, { key: "aire_maintenance", name: "Aircraft Maintenance" }, [], employee_id: employee.id)
    expect(rate).to be_nil
    expect(message).to include("Maintenance or Regular")
  end

  it "requires refresh when an audited company mapping changes after preview" do
    configure
    digest = TimeTracking::CanonicalPayload.checksum(TimeTrackingCategoryMapping.where(time_tracking_source: source).order(:id).map(&:attributes))
    import = create(:time_tracking_import, pay_period: period, time_tracking_source: source, processed_payload: { "category_configuration_checksum" => digest })
    TimeTrackingCategoryMapping.find_by!(time_tracking_source: source).update!(earning_label: "Changed component")
    service = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor)
    expect { service.send(:validate_preview_provenance!) }.to raise_error(ArgumentError, /category configuration changed/)
  end

  it "uses each employee's own Flight rate and does not change another company's default" do
    flight = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 32)
    ground = create(:employee_wage_rate, employee: employee, label: "Ground", rate: 19)
    configure
    expect(preview.send(:find_wage_rate, category, [ flight, ground ], employee_id: employee.id)).to include(flight, "company_category_mapping")
    other = create(:time_tracking_source, company: create(:company), source_type: "aire_services")
    expect(TimeTracking::BatchImportPreviewService.new(pay_period: period, source: other).send(:find_wage_rate, category, [ flight ], employee_id: employee.id).first).to be_nil
  end
  it "blocks missing Flight rates clearly and never falls back to Ground" do
    configure
    ground = create(:employee_wage_rate, employee: employee, label: "Ground", rate: 19)
    rate, _, message = preview.send(:find_wage_rate, category, [ ground ], employee_id: employee.id)
    expect(rate).to be_nil
    expect(message).to include("active Flight Hours rate")
    import = create(:time_tracking_import, pay_period: period, time_tracking_source: source)
    service = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor)
    expect { service.send(:wage_rate_for_category, category, [ ground ], {}) }.to raise_error(ArgumentError, /active Flight Hours rate/)
  end
  it "prevents an import override from bypassing the company category mapping" do
    configure
    flight = create(:employee_wage_rate, employee: employee, label: "Flight Hours", rate: 32)
    ground = create(:employee_wage_rate, employee: employee, label: "Ground", rate: 19)
    import = create(:time_tracking_import, pay_period: period, time_tracking_source: source)
    service = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor)
    expect(service.send(:wage_rate_for_category, category.merge(employee_wage_rate_id: ground.id), [ flight, ground ], {})).to eq(flight)
  end
end
