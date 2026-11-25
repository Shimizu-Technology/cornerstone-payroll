# frozen_string_literal: true

module DemoCompany
  # Gives the demo employees their email aliases (D6), so email sign-up and
  # notices reach the firm-controlled mailbox. Addresses come only from the
  # caller (private configuration), must be allow-listed and are never stored
  # in the repository. They go to the roster's people in order; a person at
  # both employers (Kit Wren) gets the same address at each.
  #
  # Everything is checked before anything is written: the organization
  # administrator, each address and every target employee. Each change and its
  # audit row commit together. Safe to rerun: an employee who already has its
  # address is left as it is.
  class AssignEmployeeEmails
    class Refused < StandardError; end

    Outcome = Data.define(:name, :email, :status)
    Target = Data.define(:company, :person, :employee_id, :email)

    def initialize(organization:, actor:, emails:)
      @organization = organization
      @actor = actor
      @emails = Array(emails).flat_map { |entry| entry.to_s.split(",") }.filter_map { |entry| DemoOutbound.normalize(entry) }
    end

    def call
      authorize!
      people = Roster::PEOPLE.group_by { |person| [ person[:first], person[:last] ] }.values
      raise Refused, "Give at least one address" if @emails.empty?
      raise Refused, "Give each address once" if @emails.uniq.size != @emails.size
      raise Refused, "Give at most #{people.size} addresses, one per person" if @emails.size > people.size
      malformed = @emails.reject { |email| EmployeeLinks.email_format?(email) }
      raise Refused, "#{malformed.size} address(es) aren't valid email addresses; nothing was changed" if malformed.any?
      refused = @emails.reject { |email| DemoOutbound.allowed?(email) }
      raise Refused, "#{refused.size} address(es) aren't on the allow-list; nothing was changed" if refused.any?

      targets(people.first(@emails.size).zip(@emails)).map { |target| assign!(target) }
    end

    private

    attr_reader :organization, :actor

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    # Every selected employee, found before the first write.
    def targets(assignments)
      companies = demo_companies
      assignments.flat_map do |entries, email|
        entries.map do |person|
          company = companies.fetch(person[:company])
          id = TenantScope.with_company(company.id) do
            Employee.where(company_id: company.id, first_name: person[:first], last_name: person[:last]).pick(:id)
          end
          raise Refused, "Seed the demo employers first (rake demo:seed); nothing was changed" unless id

          Target.new(company, person, id, email)
        end
      end
    end

    def demo_companies
      [ Roster::KITCHEN, Roster::CATERING ].index_with do |key|
        company = TenantScope.as_system(reason: "Find the demo employers to give employee emails") do
          Company.demo.where(organization_id: organization.id).find_by("test_workspace_manifest ->> 'demo_fixture_key' = ?", key)
        end
        company || raise(Refused, "Seed the demo employers first (rake demo:seed); nothing was changed")
      end
    end

    def assign!(target)
      name = "#{target.person[:first]} #{target.person[:last]}"
      TenantScope.with_company(target.company.id) do
        Employee.transaction do
          employee = Employee.lock.find_by!(id: target.employee_id, company_id: target.company.id)
          next Outcome.new(name: name, email: target.email, status: "unchanged") if DemoOutbound.normalize(employee.email) == target.email

          employee.update!(email: target.email)
          AuditLog.record!(user: actor, organization_id: target.company.organization_id,
            company_id: target.company.id, action: "employees#demo_email_assigned", record_type: "employees",
            record_id: employee.id, subject_name: name, metadata: { email_domain: target.email.split("@", 2).last })
          Outcome.new(name: name, email: target.email, status: "assigned")
        end
      end
    end
  end
end
