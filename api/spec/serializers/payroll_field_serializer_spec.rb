# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFieldSerializer do
  let!(:field) { create(:payroll_field_definition) }

  before do
    [ true, true, false ].each do |active|
      employee = create(:employee, company: field.company)
      employee.employee_payroll_fields.create!(payroll_field_definition: field, active: active)
    end
  end

  it "returns impact counts without materializing unloaded employee assignments" do
    definition = PayrollFieldDefinition.find(field.id)
    expect(definition.association(:employee_payroll_fields)).not_to be_loaded
    result = described_class.call(definition)
    expect(result).to include(active_assignment_count: 2, assigned_employee_count: 3)
    expect(definition.association(:employee_payroll_fields)).not_to be_loaded
  end

  it "uses preloaded assignments without further SQL, including in-memory status changes" do
    definition = PayrollFieldDefinition.includes(:employee_payroll_fields).find(field.id)
    definition.employee_payroll_fields.find(&:active?).active = false
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { described_class.call(definition) }
    expect(result).to include(active_assignment_count: 1, assigned_employee_count: 3)
    expect(queries).to be_empty
  end
end
