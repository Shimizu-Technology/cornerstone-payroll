# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe EmployeePayItemService, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { create(:organization) }
  let!(:company) { create(:company, organization: organization) }
  let!(:department) { create(:department, company: company) }
  let!(:employee) { create(:employee, company: company, department: department) }

  after do
    EmployeePayrollField.where(employee_id: employee.id).delete_all
    PayrollFieldDefinition.where(company_id: company.id).delete_all
    Employee.where(id: employee.id).delete_all
    Department.where(id: department.id).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  %w[employee_only client_wide].each do |scope|
    it "serializes competing #{scope} double submits to one saved item" do
      ready = Queue.new
      release = Queue.new
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            worker = Employee.find(employee.id)
            ready << true
            release.pop
            field, assignment, created = described_class.new(employee: worker).create_and_assign(
              scope: scope,
              field_attributes: { name: "Concurrent allowance", kind: "addition", tax_treatment: "taxable_addition", amount_type: "fixed" },
              assignment_attributes: { amount: 250, start_date: "2026-10-15" }
            )
            results << [ field.id, assignment.id, created ]
          rescue StandardError => e
            results << e
          end
        end
      end
      Timeout.timeout(10) { 2.times { ready.pop } }
      2.times { release << true }
      threads.each { |thread| Timeout.timeout(10) { thread.join } }
      rows = 2.times.map { results.pop }
      expect(rows).to all(be_an(Array))
      expect(rows.map { |row| row.take(2) }.uniq.length).to eq(1)
      expect(rows.map(&:last)).to contain_exactly(true, false)
      expect(PayrollFieldDefinition.where(company_id: company.id).count).to eq(1)
      expect(employee.employee_payroll_fields.count).to eq(1)
    ensure
      threads&.each { |thread| thread.kill if thread.alive? }
    end
  end
end
