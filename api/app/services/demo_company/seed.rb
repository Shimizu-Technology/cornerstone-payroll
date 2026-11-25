# frozen_string_literal: true

module DemoCompany
  # Seeds the two permanent demo employers with fictional people and several
  # months of biweekly payroll, run through the real calculator and committed
  # through the normal lifecycle. Safe to run again: each company, person and
  # pay period is found before it is created, and a committed period is never
  # touched. Each period is calculated and committed in its own transaction,
  # so an interrupted run resumes where it stopped.
  #
  # It only ever writes to demo companies, creates no logins and sends no
  # email, and leaves every employee-app switch off.
  class Seed
    class Refused < StandardError; end

    Result = Data.define(:companies, :employees_created, :periods_committed, :periods_skipped)

    CITY = { city: "Hagåtña", state: "GU", zip: "96910" }.freeze

    COMPANIES = [
      {
        key: "harbor-finch-kitchen", name: "Harbor Finch Kitchen", slug: "harborfinch",
        # The 07 EIN prefix is never issued, so the number can't collide with a real employer.
        profile: { ein: "07-2026101", address_line1: "214 Marine Corps Drive", phone: "(671) 555-0140",
                   email: "office@harborfinch.example", filing_contact_name: "Maren Fable", **CITY },
        bank: { bank_name: "Tasi Cove Savings", bank_address: "88 Chalan Santo Papa, Hagåtña, GU 96910" },
        branding: { "display_name" => "Harbor Finch Kitchen", "primary_color" => "#1F4E5F", "accent_color" => "#E3A857" },
        help: [ { name: "Maren Fable", role: "General manager", phone: "(671) 555-0141", email: "manager@harborfinch.example" },
                { name: "Front office", role: "Payroll questions", phone: "(671) 555-0142", email: "office@harborfinch.example" } ],
        departments: [ "Kitchen", "Front of house", "Office" ]
      },
      {
        key: "harbor-finch-catering", name: "Harbor Finch Catering", slug: "harborfinch-catering",
        profile: { ein: "07-2026102", address_line1: "17 Route 8, Maite", phone: "(671) 555-0150",
                   email: "events@harborfinch-catering.example", filing_contact_name: "Maren Fable", city: "Maite", state: "GU", zip: "96910" },
        bank: { bank_name: "Tasi Cove Savings", bank_address: "88 Chalan Santo Papa, Hagåtña, GU 96910" },
        branding: { "display_name" => "Harbor Finch Catering", "primary_color" => "#2E5E4E", "accent_color" => "#F2C14E" },
        help: [ { name: "Events desk", role: "Scheduling and pay", phone: "(671) 555-0151", email: "events@harborfinch-catering.example" } ],
        departments: [ "Events" ]
      }
    ].freeze

    # SSNs use the 900 area, which is never issued. Each person has a distinct
    # last four; Kit Wren keeps one identity at both employers. Routing
    # numbers fail the ABA checksum, so no real account is stored.
    PEOPLE = [
      { company: "harbor-finch-kitchen", first: "Robin", last: "Lantern", dept: "Kitchen", type: "hourly", rate: 17.50,
        ssn: "900-01-1001", delivery: "direct_deposit", routing: "123456789", account: "4011001", hours: 80, overtime: [ 0, 6, 0, 4, 0, 8, 0 ] },
      { company: "harbor-finch-kitchen", first: "Ellis", last: "Quill", dept: "Office", type: "salary", rate: 52_000,
        ssn: "900-01-1002", delivery: "direct_deposit", routing: "987654321", account: "4011002" },
      { company: "harbor-finch-kitchen", first: "Rowan", last: "Drift", dept: "Front of house", type: "hourly", rate: 9.25,
        ssn: "900-01-1003", delivery: "paper_check", hours: 72, tips: [ 410.25, 388.50, 452.75, 401.00, 476.20, 395.40, 430.10 ] },
      { company: "harbor-finch-kitchen", first: "Avery", last: "Sprig", dept: "Front of house", type: "hourly", rate: 11.00,
        ssn: "900-01-1004", delivery: "paper_check", hours: 32 },
      { company: "harbor-finch-kitchen", first: "Jules", last: "Reed", dept: "Kitchen", type: "hourly", rate: 13.75,
        ssn: "900-01-1005", delivery: "paper_check", hours: 80, terminate_after: 3 },
      { company: "harbor-finch-kitchen", first: "Quinn", last: "Sable", dept: "Kitchen", type: "hourly", rate: 14.25,
        ssn: "900-01-1006", delivery: "direct_deposit", routing: "123456781", account: "4011006", hours: 80, terminate_after: 1, rehire_before: 4 },
      { company: "harbor-finch-kitchen", first: "Maren", last: "Fable", dept: "Office", type: "salary", rate: 68_000,
        ssn: "900-01-1007", delivery: "direct_deposit", routing: "987654322", account: "4011007" },
      { company: "harbor-finch-kitchen", first: "Kit", last: "Wren", dept: "Kitchen", type: "hourly", rate: 12.50,
        ssn: "900-01-1008", delivery: "paper_check", hours: 40 },
      { company: "harbor-finch-kitchen", first: "Sky", last: "Lark", dept: "Front of house", type: "hourly", rate: 10.50,
        ssn: "900-01-1009", delivery: "paper_check", hours: 64 },
      { company: "harbor-finch-kitchen", first: "Drew", last: "Flint", dept: "Kitchen", type: "hourly", rate: 15.00,
        ssn: "900-01-1010", delivery: "direct_deposit", routing: "123456782", account: "4011010", hours: 80 },
      { company: "harbor-finch-catering", first: "Kit", last: "Wren", dept: "Events", type: "hourly", rate: 13.00,
        ssn: "900-01-1008", delivery: "paper_check", hours: 24 },
      { company: "harbor-finch-catering", first: "Morgan", last: "Tide", dept: "Events", type: "hourly", rate: 14.00,
        ssn: "900-01-1011", delivery: "paper_check", hours: 48 }
    ].freeze

    # Seven finished biweekly periods from August 2, 2026, paid the Friday
    # after they end, plus one open period left in draft.
    FIRST_PERIOD_START = Date.new(2026, 8, 2)
    COMMITTED_PERIODS = 7
    HIRE_DATE = Date.new(2026, 7, 1)

    def initialize(organization:, actor:)
      @organization = organization
      @actor = actor
      @employees_created = 0
      @periods_committed = 0
      @periods_skipped = 0
    end

    def call
      authorize!
      companies = COMPANIES.map { |spec| ensure_company!(spec) }
      companies.each { |company| seed_company!(company) }
      Result.new(companies: companies, employees_created: @employees_created,
        periods_committed: @periods_committed, periods_skipped: @periods_skipped)
    end

    def self.periods
      (0..COMMITTED_PERIODS).map do |index|
        start = FIRST_PERIOD_START + (14 * index)
        { index: index, start_date: start, end_date: start + 13, pay_date: start + 19, open: index == COMMITTED_PERIODS }
      end
    end

    private

    attr_reader :organization, :actor

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    def ensure_company!(spec)
      company = Company.where(organization_id: organization.id)
        .where("test_workspace_manifest ->> 'demo_fixture_key' = ?", spec[:key]).first
      if company.nil?
        if Company.where("lower(subdomain_slug) = ?", spec[:slug]).exists?
          raise Refused, "The #{spec[:slug]} address belongs to another company"
        end

        company = Create.new(organization: organization, actor: actor, name: spec[:name], fixture_key: spec[:key],
          profile: spec[:profile]).call
      end
      demo!(company)

      company.with_lock do
        demo!(company)
        # Fill only what is still blank, so later edits by testers survive.
        updates = spec[:bank].reject { |field, _| company.public_send(field).present? }
        updates[:subdomain_slug] = spec[:slug] if company.subdomain_slug.blank?
        updates[:branding] = spec[:branding] if company.branding.blank?
        company.update!(updates) if updates.any?
        if company.help_contacts.none?
          spec[:help].each_with_index { |contact, index| company.help_contacts.create!(contact.merge(position: index + 1)) }
        end
      end
      company
    end

    # Every write is preceded by this check, so a live company is never touched.
    def demo!(company)
      raise Refused, "Refusing to seed #{company.name}: it is not a demo company" unless company.reload.demo?
    end

    def seed_company!(company)
      TenantScope.with_company(company.id) do
        spec = COMPANIES.find { |entry| entry[:key] == company.test_workspace_manifest["demo_fixture_key"] }
        departments = spec[:departments].index_with { |name| Department.find_or_create_by!(company: company, name: name) }
        workweek, schedule = ensure_calendar!(company)
        people = PEOPLE.select { |person| person[:company] == spec[:key] }
        employees = people.to_h { |person| [ person, ensure_employee!(company, departments.fetch(person[:dept]), person) ] }

        self.class.periods.each do |period_spec|
          apply_status_changes!(employees, period_spec)
          period = ensure_period!(company, schedule, workweek, period_spec)
          next if period_spec[:open]

          if period.committed?
            @periods_skipped += 1
            next
          end
          run_and_commit!(period, employees, period_spec)
          @periods_committed += 1
        end
      end
    end

    def ensure_calendar!(company)
      workweek = company.company_workweeks.order(:effective_on, :id).first || CompanyWorkweek.create!(
        company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
        source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
        notes: "Sunday workweek", effective_on: HIRE_DATE
      )
      schedule = company.company_pay_schedules.order(:effective_on, :id).first || CompanyPaySchedule.create!(
        company: company, frequency: "biweekly", period_rule: "biweekly", pay_date_rule: "days_after_period_end",
        pay_date_offset_days: 6, period_start_weekday: 0, period_anchor_date: FIRST_PERIOD_START, timezone: "Pacific/Guam",
        source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
        notes: "Biweekly, paid the Friday after the period ends", effective_on: HIRE_DATE
      )
      [ workweek, schedule ]
    end

    def ensure_employee!(company, department, person)
      existing = Employee.find_by(company: company, first_name: person[:first], last_name: person[:last])
      return existing if existing

      salary = person[:type] == "salary"
      employee = Employee.create!(
        company: company, department: department, first_name: person[:first], last_name: person[:last],
        email: nil, ssn_encrypted: person[:ssn], employment_type: salary ? "salary" : "hourly",
        salary_type: "annual", pay_rate: person[:rate], pay_frequency: "biweekly", status: "active",
        filing_status: "single", allowances: 0, w4_effective_on: HIRE_DATE, hire_date: HIRE_DATE,
        payment_delivery_method: person[:delivery],
        bank_routing_number_encrypted: person[:routing], bank_account_number_encrypted: person[:account],
        address_line1: "#{100 + PEOPLE.index(person)} Chalan Pasaheru", **CITY
      )
      EmployeeW4ElectionChangeService.new(
        employee: employee,
        attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) },
        actor: actor, source: "employee_creation", reason: "Initial W-4 election"
      ).call!
      @employees_created += 1
      employee
    end

    # Terminations and the rehire happen between periods, in pay-date order,
    # and only once.
    def apply_status_changes!(employees, period_spec)
      employees.each do |person, employee|
        employee.reload
        if person[:terminate_after] && period_spec[:index] == person[:terminate_after] + 1 &&
            employee.status == "active" && !employee.employee_status_events.exists?(event_type: "terminated")
          EmployeeStatusTransitionService.terminate!(employee: employee, actor: actor, attributes: {
            effective_date: period_spec[:start_date] - 1, last_worked_on: period_spec[:start_date] - 1,
            reason_category: "voluntary", source: "operator"
          })
        end
        next unless person[:rehire_before] && period_spec[:index] == person[:rehire_before] && employee.status == "terminated"

        EmployeeStatusTransitionService.reactivate!(employee: employee, actor: actor, attributes: {
          effective_date: period_spec[:start_date], internal_notes: "Rehired for the fall season", source: "operator"
        })
      end
    end

    def ensure_period!(company, schedule, workweek, period_spec)
      PayPeriod.find_by(company: company, start_date: period_spec[:start_date], end_date: period_spec[:end_date], correction_status: nil) ||
        PayPeriod.create!(company: company, company_pay_schedule: schedule, company_workweek: workweek,
          start_date: period_spec[:start_date], end_date: period_spec[:end_date], pay_date: period_spec[:pay_date],
          status: "draft", run_purpose: "regular", run_purpose_source: "operator_selected", includes_base_salary: true)
    end

    def run_and_commit!(period, employees, period_spec)
      ApplicationRecord.transaction do
        period.lock!
        demo!(period.company)
        working = employees.select { |_person, employee| employee.reload.status == "active" }
        working.each do |person, employee|
          item = period.payroll_items.find_or_initialize_by(employee_id: employee.id)
          item.assign_attributes(
            company_id: period.company_id, employee: employee, employment_type: employee.employment_type,
            pay_rate: employee.pay_rate, payment_delivery_method: person[:delivery],
            hours_worked: person[:type] == "salary" ? 0 : person[:hours],
            overtime_hours: Array(person[:overtime])[period_spec[:index]] || 0,
            tips: Array(person[:tips])[period_spec[:index]] || 0,
            reported_tips: Array(person[:tips])[period_spec[:index]] || 0
          )
          item.save! if item.new_record?
          item.calculate!
        end
        period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: actor.id, approved_at: nil, approved_by_id: nil)
        PayrollReview::RevisionService.new(pay_period: period, actor: actor).issue!
        lifecycle = PayPeriodLifecycleService.new(pay_period: period.reload, actor: actor)
        lifecycle.approve!
        PayPeriodLifecycleService.new(pay_period: period.reload, actor: actor).commit!(
          expected_next_check_number: period.company.reload.next_check_number
        )
      end
    end
  end
end
