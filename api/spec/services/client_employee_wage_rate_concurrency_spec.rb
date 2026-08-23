# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe ClientEmployeeUpdateService, :postgres_concurrency, type: :service do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "Client wage concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization, name: "Client wage concurrency #{SecureRandom.hex(4)}") }
  let!(:department) { Department.create!(company: company, name: "Concurrency") }
  let!(:client_user) { create(:user, company: company, organization: organization, role: "client") }
  let!(:employee) { create(:employee, company: company, department: department) }
  let!(:wage_rate) do
    employee.employee_wage_rates.create!(
      label: "Regular",
      rate: 18,
      is_primary: true,
      active: true
    )
  end

  after do
    EmployeeChangeRequest.where(employee_id: employee.id).delete_all
    EmployeeWageRate.where(employee_id: employee.id).delete_all
    Employee.where(id: employee.id).delete_all
    Department.where(id: department.id).delete_all
    User.where(id: client_user.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  it "stores one coherent wage-rate baseline while a direct admin update competes" do
    first_snapshot_read = Queue.new
    release_client = Queue.new
    results = Queue.new
    paused = false
    pause_mutex = Mutex.new

    allow_any_instance_of(described_class).to receive(:current_wage_rates_payload).and_wrap_original do |original, *args|
      payload = original.call(*args)
      should_pause = Thread.current[:client_wage_request] && pause_mutex.synchronize do
        next false if paused

        paused = true
      end
      if should_pause
        first_snapshot_read << true
        release_client.pop
      end
      payload
    end

    client_thread = Thread.new do
      Thread.current[:client_wage_request] = true
      ActiveRecord::Base.connection_pool.with_connection do
        worker = Employee.find(employee.id)
        actor = User.find(client_user.id)
        result = described_class.new(
          employee: worker,
          attrs: {
            wage_rates: [
              { id: wage_rate.id, label: "Regular", rate: 19.75, is_primary: true, active: true }
            ]
          },
          requested_by: actor,
          company: Company.find(company.id)
        ).update!
        results << [ :client, result.change_request.id ]
      rescue StandardError => e
        results << [ :client_error, e ]
      end
    end

    first_snapshot_read.pop
    admin_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        EmployeeWageRate.find(wage_rate.id).update_with_employee_lock(rate: 20)
        results << [ :admin, :updated ]
      rescue StandardError => e
        results << [ :admin_error, e ]
      end
    end

    admin_was_blocked = admin_thread.join(0.2).nil?
    release_client << true
    [ client_thread, admin_thread ].each { |thread| Timeout.timeout(10) { thread.join } }

    expect(admin_was_blocked).to eq(true)
    outcomes = 2.times.map { results.pop }
    expect(outcomes.map(&:first)).to contain_exactly(:client, :admin)
    request_id = outcomes.find { |kind, _| kind == :client }.last
    request = EmployeeChangeRequest.find(request_id)

    expect(request.original_values.fetch("wage_rates")).to contain_exactly(
      include("id" => wage_rate.id, "label" => "Regular", "rate" => 18.0)
    )
    expect(request.proposed_changes.fetch("wage_rates")).to contain_exactly(
      include("id" => wage_rate.id, "label" => "Regular", "rate" => 19.75)
    )
    expect(wage_rate.reload.rate.to_f).to eq(20.0)
  end
end
