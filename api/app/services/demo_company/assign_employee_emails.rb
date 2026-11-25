# frozen_string_literal: true

module DemoCompany
  # Gives the demo employees their email aliases (D6), so email sign-up and
  # notices reach the firm-controlled mailbox. Addresses come only from the
  # caller (private configuration), must be allow-listed and are never stored
  # in the repository. They go to the roster's people in order; a person at
  # both employers (Kit Wren) gets the same address at each. Safe to rerun:
  # an employee who already has its address is left as it is.
  class AssignEmployeeEmails
    class Refused < StandardError; end

    Outcome = Data.define(:name, :email, :status)

    def initialize(organization:, emails:)
      @organization = organization
      @emails = Array(emails).flat_map { |entry| entry.to_s.split(",") }.filter_map { |entry| DemoOutbound.normalize(entry) }
    end

    def call
      people = Roster::PEOPLE.group_by { |person| [ person[:first], person[:last] ] }.values
      raise Refused, "Give at least one address" if @emails.empty?
      raise Refused, "Give each address once" if @emails.uniq.size != @emails.size
      raise Refused, "Give at most #{people.size} addresses, one per person" if @emails.size > people.size
      refused = @emails.reject { |email| DemoOutbound.allowed?(email) }
      raise Refused, "#{refused.size} address(es) aren't on the allow-list; nothing was changed" if refused.any?

      companies = demo_companies
      people.first(@emails.size).zip(@emails).flat_map do |entries, email|
        entries.map { |person| assign!(companies.fetch(person[:company]), person, email) }
      end
    end

    private

    def demo_companies
      [ Roster::KITCHEN, Roster::CATERING ].index_with do |key|
        company = TenantScope.as_system(reason: "Find the demo employers to give employee emails") do
          Company.demo.where(organization_id: @organization.id).find_by("test_workspace_manifest ->> 'demo_fixture_key' = ?", key)
        end
        company || raise(Refused, "Seed the demo employers first (rake demo:seed)")
      end
    end

    def assign!(company, person, email)
      name = "#{person[:first]} #{person[:last]}"
      TenantScope.with_company(company.id) do
        employee = Employee.lock.find_by(company_id: company.id, first_name: person[:first], last_name: person[:last])
        raise Refused, "Seed the demo employers first (rake demo:seed)" unless employee
        next Outcome.new(name: name, email: email, status: "unchanged") if DemoOutbound.normalize(employee.email) == email

        employee.update!(email: email)
        AuditLog.record!(actor: AuditActor.system_job("demo:assign_employee_emails"), organization_id: company.organization_id,
          company_id: company.id, action: "employees#demo_email_assigned", record_type: "employees", record_id: employee.id,
          subject_name: name, metadata: { email_domain: email.split("@", 2).last })
        Outcome.new(name: name, email: email, status: "assigned")
      end
    end
  end
end
