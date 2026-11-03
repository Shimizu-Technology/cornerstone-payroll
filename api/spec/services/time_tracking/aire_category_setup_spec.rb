# frozen_string_literal: true

require "rails_helper"
RSpec.describe TimeTracking::AireCategorySetup do
  it "audits company2 setup, leaves other companies unchanged and configures the explicit Maintenance then Regular rule" do
    company = create(:company, id: 2)
    create(:pay_period, :committed, id: 61, company: company, start_date: "2026-08-01", end_date: "2026-08-15", pay_date: "2026-08-31")
    actor = create(:user, company: company, organization: company.organization, role: "org_admin")
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    anthony = create(:employee, company: company, first_name: "Anthony", last_name: "Ezra")
    create(:employee, company: company, first_name: "Isiah", last_name: "Gonzales")
    pilot = create(:employee, company: company)
    create(:employee_wage_rate, employee: pilot, label: "Flight Hours", rate: 30)
    args = { source: source, actor: actor, reason: "Reviewed November4 category activation configuration", evidence: "Leon approved Solo Flight and the scoped historical categories" }
    result = described_class.call!(**args)
    expect(result[:maintenance]).to include("otherwise Regular")
    expect(TimeTrackingCategoryMapping.find_by!(time_tracking_source: source, source_category_key: "solo")).to have_attributes(earning_label: "Flight Hours", import_enabled: true)
    expect(TimeTrackingCategoryMapping.find_by!(time_tracking_source: source, source_category_key: "maintenance")).to have_attributes(import_enabled: true, earning_label: "Maintenance", fallback_earning_label: "Regular", historical_employee_ids: [ anthony.id ])
    expect(AuditLog.where(action: "time_tracking_category_mapping#reviewed").count).to eq(4)
    expect { described_class.call!(**args) }.not_to change(AuditLog, :count)
    other = create(:time_tracking_source, company: create(:company), source_type: "aire_services")
    expect { described_class.call!(**args.merge(source: other)) }.to raise_error(ArgumentError, /only for company 2/)
    expect(TimeTrackingCategoryMapping.where(time_tracking_source: other)).not_to exist
  end
end
