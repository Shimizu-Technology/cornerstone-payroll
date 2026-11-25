# frozen_string_literal: true

require "tmpdir"

module DemoCompany
  # Seeds the two permanent demo employers from DemoCompany::Roster.
  #
  # Harbor Finch Kitchen starts the way a real migrated client does: its
  # January–July 2026 QuickBooks history is imported, prepared, applied,
  # verified, reviewed, locked and bridged into YTD through the real services,
  # and only then does native payroll run from the August 7 payday. Harbor
  # Finch Catering is native-only. Native periods run through the real
  # calculator and are committed through the normal lifecycle.
  #
  # Safe to run again (a finished run is a no-op), safe if interrupted (each
  # step and period resumes), and serialized per organization. It writes only
  # to demo companies, creates no logins, sends no email and leaves every
  # employee-app switch off.
  class Seed
    class Refused < StandardError; end

    Result = Data.define(:companies, :employees_created, :periods_committed, :periods_skipped, :quickbooks_imported)

    COMPANIES = [
      {
        key: Roster::KITCHEN, name: "Harbor Finch Kitchen", slug: "harborfinch",
        # The 07 EIN prefix is never issued, so the number can't collide with a real employer.
        profile: { ein: "07-2026101", address_line1: "214 Marine Corps Drive", city: "Hagåtña", state: "GU", zip: "96910",
                   phone: "(671) 555-0140", email: "office@harborfinch.example", filing_contact_name: "Maren Fable",
                   historical_payroll_enabled: true },
        bank: { bank_name: "Tasi Cove Savings", bank_address: "88 Chalan Santo Papa, Hagåtña, GU 96910" },
        branding: { "display_name" => "Harbor Finch Kitchen", "primary_color" => "#1F4E5F", "accent_color" => "#E3A857" },
        help: [ { name: "Maren Fable", role: "General manager", phone: "(671) 555-0141", email: "manager@harborfinch.example" },
                { name: "Front office", role: "Payroll questions", phone: "(671) 555-0142", email: "office@harborfinch.example" } ],
        departments: [ "Kitchen", "Front of house", "Office" ]
      },
      {
        key: Roster::CATERING, name: "Harbor Finch Catering", slug: "harborfinch-catering",
        profile: { ein: "07-2026102", address_line1: "17 Route 8", city: "Maite", state: "GU", zip: "96910",
                   phone: "(671) 555-0150", email: "events@harborfinch-catering.example", filing_contact_name: "Maren Fable" },
        bank: { bank_name: "Tasi Cove Savings", bank_address: "88 Chalan Santo Papa, Hagåtña, GU 96910" },
        branding: { "display_name" => "Harbor Finch Catering", "primary_color" => "#2E5E4E", "accent_color" => "#F2C14E" },
        help: [ { name: "Events desk", role: "Scheduling and pay", phone: "(671) 555-0151", email: "events@harborfinch-catering.example" } ],
        departments: [ "Events" ]
      }
    ].freeze

    REVIEW_NOTE = "Verified against the retained QuickBooks employee setup and the client's hiring records."
    # Fixed 64-bit base for the per-organization seed lock, distinct from the
    # other DedicatedAdvisoryLock bases.
    LOCK_KEY_BASE = 4_200_000_000_000_000_000

    def initialize(organization:, actor:)
      @organization = organization
      @actor = actor
      @employees_created = 0
      @periods_committed = 0
      @periods_skipped = 0
      @quickbooks_imported = false
    end

    # Organization-level reads and company creation run as system; each
    # company's own writes run in that company's scope. Scopes never nest.
    def call
      with_organization_lock do
        companies = system_scope do
          authorize!
          COMPANIES.map { |spec| ensure_company!(spec) }
        end
        companies.each { |company| company_scope(company) { apply_company_profile!(company) } }
        kitchen = companies.find { |company| fixture_key(company) == Roster::KITCHEN }
        company_scope(kitchen) { seed_quickbooks_history!(kitchen) }
        companies.each { |company| company_scope(company) { seed_native_payroll!(company) } }
        Result.new(companies: companies, employees_created: @employees_created, periods_committed: @periods_committed,
          periods_skipped: @periods_skipped, quickbooks_imported: @quickbooks_imported)
      end
    end

    private

    attr_reader :organization, :actor

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    # One run per organization at a time; a second concurrent run is refused.
    # The lock lives on its own connection, so it is safe under transaction
    # pooling and always released when the block ends, even on an error.
    def with_organization_lock(&)
      DedicatedAdvisoryLock.with_lock(LOCK_KEY_BASE + Integer(organization.id), wait_seconds: 0, &)
    rescue DedicatedAdvisoryLock::Unavailable
      raise Refused, "Another seed run is in progress for this organization"
    end

    # Enters a scope only when none is active (the DemoOutbound pattern).
    def system_scope(&)
      TenantScope.current ? yield : TenantScope.as_system(reason: "Seed the demo employers", &)
    end

    def company_scope(company, &)
      TenantScope.current ? yield : TenantScope.with_company(company.id, &)
    end

    def fixture_key(company) = company.test_workspace_manifest["demo_fixture_key"]

    def find_company(spec)
      Company.where(organization_id: organization.id).where("test_workspace_manifest ->> 'demo_fixture_key' = ?", spec[:key]).first
    end

    def ensure_company!(spec)
      company = find_company(spec)
      if company.nil?
        if Company.where("lower(subdomain_slug) = ?", spec[:slug]).exists?
          raise Refused, "The #{spec[:slug]} address belongs to another company"
        end

        begin
          company = Create.new(organization: organization, actor: actor, name: spec[:name], fixture_key: spec[:key], profile: spec[:profile]).call
        rescue ActiveRecord::RecordNotUnique, ArgumentError => error
          # A concurrent run created it first: use that one.
          company = find_company(spec) || raise(error)
        end
      end
      demo!(company)
      company
    end

    def apply_company_profile!(company)
      spec = spec_for(company)
      company.with_lock do
        demo!(company)
        # Fill only what is still blank, so later edits by testers survive.
        updates = spec[:bank].reject { |field, _| company.public_send(field).present? }
        updates[:subdomain_slug] = spec[:slug] if company.subdomain_slug.blank?
        updates[:branding] = spec[:branding] if company.branding.blank?
        updates[:historical_payroll_enabled] = true if spec.dig(:profile, :historical_payroll_enabled) && !company.historical_payroll_enabled?
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

    def spec_for(company) = COMPANIES.find { |entry| entry[:key] == fixture_key(company) }

    def departments_for(company)
      spec_for(company)[:departments].index_with { |name| Department.find_or_create_by!(company: company, name: name) }
    end

    # -- QuickBooks history (Kitchen) ------------------------------------------

    def seed_quickbooks_history!(company)
      demo!(company)
      begin
        batch = HistoricalImportBatch.where(company: company, source_system: "quickbooks_online").where.not(status: %w[failed reversed]).order(:id).last
        return if batch&.locked? && batch.historical_ytd_bridges.where(status: "applied").exists?

        batch ||= Dir.mktmpdir("harbor-finch-quickbooks") do |dir|
          files = QuickbooksSample.new(output_dir: dir).call.files
          QuickbooksHistory::ImportService.new(company: company, files: files, actor: actor).call.batch
        end
        @quickbooks_imported = true
        prepare_employees_from_quickbooks!(company, batch)

        lifecycle = QuickbooksHistory::LifecycleService.new(batch: batch.reload, actor: actor)
        lifecycle.apply!(acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT) if batch.previewed?
        approve_cutover!(batch.reload) unless batch.reload.locked?
        lifecycle.lock! unless batch.reload.locked?
        activate_ytd_bridge!(batch.reload)
      end
    end

    def prepare_employees_from_quickbooks!(company, batch)
      bootstrap = batch.historical_client_bootstrap
      unless bootstrap&.applied?
        bootstrap = QuickbooksHistory::ClientBootstrapPreviewService.new(batch: batch, actor: actor).call
        # The W-4 elections take effect from the start of the history, so the
        # seeded native payroll (which follows it) can use them.
        QuickbooksHistory::ClientBootstrapApplyService.new(bootstrap: bootstrap, actor: actor,
          acknowledgement: QuickbooksHistory::ClientBootstrapApplyService::ACKNOWLEDGEMENT,
          w4_effective_on: Roster::CALENDAR_ANCHOR).call
      end

      departments = departments_for(company)
      Roster.people_for(company_key(company)).select { |person| person[:quickbooks] }.each do |person|
        employee = Employee.find_by!(company: company, first_name: person[:first], last_name: person[:last])
        complete_profile!(employee, person, departments.fetch(person[:dept]))
        resolve_setup_reviews!(employee, person)
      end
    end

    def approve_cutover!(batch)
      verification = QuickbooksHistory::CutoverVerificationService.new(batch: batch, actor: actor).call
      raise Refused, "The QuickBooks history did not verify: #{Array(verification.review&.evidence&.dig('exceptions')).size} exception(s)" unless verification.passed

      review = verification.review
      return if review.approved?

      service = QuickbooksHistory::CutoverReviewService.new(review: review, actor: actor)
      service.save!(
        exception_dispositions: Array(review.evidence["exceptions"]).to_h { |exception| [ exception.fetch("key"), "Reviewed against the retained QuickBooks reports." ] },
        attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
        approval_notes: "QuickBooks January–July 2026 history reconciled to its Tax and Wage Summaries."
      )
      service.approve!(acknowledgement: HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT)
    end

    def activate_ytd_bridge!(batch)
      return if batch.historical_ytd_bridges.where(status: "applied").exists?

      bridge = QuickbooksHistory::YtdBridgePreviewService.new(batch: batch, actor: actor).call
      QuickbooksHistory::YtdBridgeApplyService.new(bridge: bridge, actor: actor,
        acknowledgement: QuickbooksHistory::YtdBridgeApplyService::ACKNOWLEDGEMENT).call
    end

    def resolve_setup_reviews!(employee, person)
      employee.reload
      Array(employee.configuration_review_items).map { |item| item["code"] }.uniq.each do |code|
        EmployeeConfigurationReviewService.new(employee: employee.reload, actor: actor).resolve!(
          code: code, resolution_note: REVIEW_NOTE, acknowledgement: EmployeeConfigurationReviewService::ACKNOWLEDGEMENT,
          source_reference: "QuickBooks employee details, #{person[:first]} #{person[:last]}", effective_on: person[:hire_date]
        )
      end
    end

    # -- People ----------------------------------------------------------------

    def company_key(company) = fixture_key(company)

    # Fills the fields the employee app and payroll need, without overwriting
    # anything a tester has since changed.
    def complete_profile!(employee, person, department)
      fill = {
        department: employee.department || department,
        date_of_birth: employee.date_of_birth || person[:dob],
        phone: employee.phone.presence || person[:phone],
        hire_date: employee.hire_date || person[:hire_date],
        payment_delivery_method: employee.payment_delivery_method.presence || person[:delivery],
        bank_routing_number_encrypted: employee.bank_routing_number_encrypted.presence || person[:routing],
        bank_account_number_encrypted: employee.bank_account_number_encrypted.presence || person[:account],
        address_line1: employee.address_line1.presence || "#{100 + Roster::PEOPLE.index(person)} Chalan Pasaheru",
        city: employee.city.presence || "Hagåtña", state: employee.state.presence || "GU", zip: employee.zip.presence || "96910"
      }
      employee.update!(fill.select { |field, value| employee.public_send(field) != value })
    end

    def ensure_native_employee!(company, department, person)
      existing = Employee.find_by(company: company, first_name: person[:first], last_name: person[:last])
      if existing
        # Repairs a run that stopped between the employee and its election.
        create_initial_w4_election!(existing) unless existing.employee_w4_elections.exists?
        return existing
      end

      salary = person[:type] == "salary"
      # The employee and its initial W-4 election are saved together.
      employee = ApplicationRecord.transaction do
        Employee.create!(
        company: company, department: department, first_name: person[:first], last_name: person[:last],
        email: nil, ssn_encrypted: person[:ssn], employment_type: salary ? "salary" : "hourly",
        salary_type: "annual", pay_rate: person[:rate], pay_frequency: "biweekly", status: "active",
        filing_status: "single", allowances: 0, w4_effective_on: person[:hire_date], hire_date: person[:hire_date],
        date_of_birth: person[:dob], phone: person[:phone], payment_delivery_method: person[:delivery],
        bank_routing_number_encrypted: person[:routing], bank_account_number_encrypted: person[:account],
        address_line1: "#{100 + Roster::PEOPLE.index(person)} Chalan Pasaheru", city: "Hagåtña", state: "GU", zip: "96910"
        ).tap { |created| create_initial_w4_election!(created) }
      end
      @employees_created += 1
      employee
    end

    def create_initial_w4_election!(employee)
      EmployeeW4ElectionChangeService.new(
        employee: employee,
        attributes: EmployeeW4Election::PROFILE_ATTRIBUTES.index_with { |attribute| employee.public_send(attribute) },
        actor: actor, source: "employee_creation", reason: "Initial W-4 election"
      ).call!
    end

    # A fixed uniform deduction for one tipped server, set up once.
    def ensure_deduction!(company, employee, person)
      return unless person[:uniform_deduction]

      definition = company.payroll_field_definitions.find_by(name: "Uniform") || company.payroll_field_definitions.create!(
        name: "Uniform", kind: "deduction", category: "other", tax_treatment: "post_tax_deduction", amount_type: "fixed",
        default_amount: person[:uniform_deduction], show_in_payroll_grid: true
      )
      EmployeePayrollField.find_or_create_by!(employee: employee, payroll_field_definition: definition) do |field|
        field.amount = person[:uniform_deduction]
        field.active = true
      end
    end

    # -- Native payroll --------------------------------------------------------

    def seed_native_payroll!(company)
      demo!(company)
      begin
        departments = departments_for(company)
        workweek, schedule = ensure_calendar!(company)
        people = Roster.people_for(company_key(company))
        employees = people.to_h do |person|
          employee = ensure_native_employee!(company, departments.fetch(person[:dept]), person)
          complete_profile!(employee, person, departments.fetch(person[:dept]))
          ensure_deduction!(company, employee, person)
          [ person, employee ]
        end

        Roster.native_periods.each do |period_spec|
          apply_status_changes!(employees, period_spec)
          apply_raises!(employees, period_spec)
          period = period_for_window!(company, schedule, workweek, period_spec)
          next if period_spec[:open]

          unless period
            @periods_skipped += 1
            next
          end
          run_and_commit!(period, employees, period_spec) ? @periods_committed += 1 : @periods_skipped += 1
        end
      end
    end

    def ensure_calendar!(company)
      workweek = company.company_workweeks.order(:effective_on, :id).first || CompanyWorkweek.create!(
        company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
        source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
        notes: "Sunday workweek", effective_on: Roster::CALENDAR_ANCHOR
      )
      schedule = company.company_pay_schedules.order(:effective_on, :id).first || CompanyPaySchedule.create!(
        company: company, frequency: "biweekly", period_rule: "biweekly", pay_date_rule: "days_after_period_end",
        pay_date_offset_days: 6, period_start_weekday: 0, period_anchor_date: Roster::CALENDAR_ANCHOR, timezone: "Pacific/Guam",
        source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: actor, confirmed_at: Time.current,
        notes: "Biweekly, paid the Friday after the period ends", effective_on: Roster::CALENDAR_ANCHOR
      )
      [ workweek, schedule ]
    end

    # The window's period to work on: an unfinished one to resume, or a new
    # draft. Any other period already in the window (committed or voided,
    # including a voided one with its correction) means the window is done.
    def period_for_window!(company, schedule, workweek, period_spec)
      existing = PayPeriod.where(company: company, start_date: period_spec[:start_date], end_date: period_spec[:end_date]).order(:id).to_a
      # A committed or voided period means the window is done, so a draft
      # beside it is never committed as a second regular payroll.
      return nil if existing.any? { |period| period.committed? || period.voided? }
      if existing.any?
        return existing.find { |period| period.status.in?(%w[draft calculated approved]) && period.correction_status.nil? }
      end

      PayPeriod.create!(company: company, company_pay_schedule: schedule, company_workweek: workweek,
        start_date: period_spec[:start_date], end_date: period_spec[:end_date], pay_date: period_spec[:pay_date],
        status: "draft", run_purpose: "regular", run_purpose_source: "operator_selected", includes_base_salary: true)
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
        # Rehire once; a tester's later termination stays in place.
        next unless person[:rehire_before] && period_spec[:index] == person[:rehire_before] && employee.status == "terminated"
        next if employee.employee_status_events.exists?(event_type: "reactivated")

        EmployeeStatusTransitionService.reactivate!(employee: employee, actor: actor, attributes: {
          effective_date: period_spec[:start_date], internal_notes: "Rehired for the fall season", source: "operator"
        })
      end
    end

    # One effective-dated raise, recorded through the normal compensation
    # change service once.
    def apply_raises!(employees, period_spec)
      employees.each do |person, employee|
        raise_spec = person[:raise]
        next unless raise_spec && period_spec[:index] == raise_spec[:from_index]
        next if employee.reload.employee_compensation_changes.where(effective_on: period_spec[:start_date]).exists?

        EmployeeCompensationChangeService.new(employee: employee, actor: actor, source: "operator",
          reason: "Annual review raise", effective_on: period_spec[:start_date], pay_rate: raise_spec[:rate]).call!
      end
    end

    # Returns true when the period was committed by this run.
    def run_and_commit!(period, employees, period_spec)
      ApplicationRecord.transaction do
        period.lock!
        demo!(period.company)
        next false if period.committed? || period.voided? || !period.status.in?(%w[draft calculated approved])

        # An approved period resumed after an interruption only needs its commit.
        calculate_period!(period, employees, period_spec) if period.draft? || period.calculated?
        PayPeriodLifecycleService.new(pay_period: period.reload, actor: actor).commit!(
          expected_next_check_number: period.company.reload.next_check_number
        )
        true
      end
    end

    def calculate_period!(period, employees, period_spec)
      working = employees.select { |_person, employee| employee.reload.status == "active" }
      working.each do |person, employee|
          item = period.payroll_items.find_or_initialize_by(employee_id: employee.id)
          hours = person[:type] == "salary" ? 0 : (person.dig(:short_hours, period_spec[:index]) || person[:hours])
          item.assign_attributes(
            company_id: period.company_id, employee: employee, employment_type: employee.employment_type,
            pay_rate: employee.payroll_rate_on(period.end_date), payment_delivery_method: person[:delivery],
            hours_worked: hours,
            overtime_hours: Array(person[:overtime])[period_spec[:index]] || 0,
            tips: Array(person[:tips])[period_spec[:index]] || 0,
            reported_tips: Array(person[:tips])[period_spec[:index]] || 0
          )
          item.save! if item.new_record?
          item.calculate!
      end
      period.update!(status: "calculated", calculated_at: Time.current, calculated_by_id: actor.id, approved_at: nil, approved_by_id: nil)
      PayrollReview::RevisionService.new(pay_period: period, actor: actor).issue!
      PayPeriodLifecycleService.new(pay_period: period.reload, actor: actor).approve!
    end
  end
end
