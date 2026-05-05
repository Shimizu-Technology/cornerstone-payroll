# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::ApplyImportService do
  describe "#call" do
    it "preserves existing holiday and PTO hours when applying imported regular and overtime hours" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      user = create(:user, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 72.0,
              "overtime_hours" => 4.0,
              "warnings" => []
            }
          ]
        }
      )
      item = create(
        :payroll_item,
        company: company,
        pay_period: pay_period,
        employee: employee,
        holiday_hours: 8.0,
        pto_hours: 4.0,
        hours_worked: 0,
        overtime_hours: 0
      )

      described_class.new(import: import, mappings: [], applied_by: user).call

      item.reload
      expect(item.hours_worked).to eq(72.0)
      expect(item.overtime_hours).to eq(4.0)
      expect(item.holiday_hours).to eq(8.0)
      expect(item.pto_hours).to eq(4.0)
    end

    it "treats an unmatched-employee warning as resolved when an employee mapping is supplied" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("mapped-warning-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => nil,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => [ { "code" => "unmatched_employee", "message" => "Map this source user" } ]
            }
          ]
        }
      )

      results = described_class.new(
        import: import,
        mappings: [ { source_user_id: "source-1", employee_id: employee.id, include: true } ],
        applied_by: create(:user, company: company)
      ).call

      expect(results[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).hours_worked).to eq(40.0)
    end

    it "recovers when a concurrent apply creates the employee mapping first" do
      company = create(:company)
      department = create(:department, company: company)
      employee = create(:employee, company: company, department: department)
      pay_period = create(:pay_period, company: company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("concurrent-mapping-payload"),
        processed_payload: {
          "rows" => [
            {
              "source_user_id" => "source-1",
              "source_email" => "worker@example.com",
              "source_display_name" => "Worker One",
              "employee_id" => employee.id,
              "regular_hours" => 40.0,
              "overtime_hours" => 0.0,
              "warnings" => []
            }
          ]
        }
      )
      lookup_attrs = {
        company: company,
        time_tracking_source: source,
        source_user_id: "source-1"
      }

      mapping = TimeTrackingEmployeeMapping.create!(lookup_attrs.merge(employee: employee))
      allow(TimeTrackingEmployeeMapping).to receive(:find_by).and_call_original
      allow(TimeTrackingEmployeeMapping).to receive(:find_by).with(lookup_attrs).and_return(nil, mapping)
      allow_any_instance_of(described_class).to receive(:create_mapping!).with(lookup_attrs, employee)
        .and_raise(ActiveRecord::RecordNotUnique, "duplicate key value")

      results = described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call

      expect(results[:errors]).to be_empty
      expect(pay_period.payroll_items.find_by!(employee: employee).hours_worked).to eq(40.0)
    end

    it "does not apply an import that is already applied" do
      company = create(:company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      import = TimeTrackingImport.create!(
        pay_period: create(:pay_period, company: company),
        time_tracking_source: source,
        start_date: Date.new(2024, 1, 1),
        end_date: Date.new(2024, 1, 14),
        fetch_start_date: Date.new(2024, 1, 1),
        fetch_end_date: Date.new(2024, 1, 14),
        source_payload_hash: Digest::SHA256.hexdigest("payload"),
        processed_payload: { "rows" => [] },
        status: "applied"
      )

      expect do
        described_class.new(import: import, mappings: [], applied_by: create(:user, company: company)).call
      end.to raise_error(ArgumentError, "Only previewed time tracking imports can be applied")
    end
  end
end
