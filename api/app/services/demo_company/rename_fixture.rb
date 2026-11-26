# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module DemoCompany
  # Keyed, idempotent migration service that renames existing demo companies
  # (e.g. production demos) to Track D's simple employee names ("Employee 01"
  # through "Employee 11", with the two-employer worker keeping one number),
  # role-labeled client logins, and invented Guam-style addresses.
  #
  # Matching is strictly keyed:
  # - companies by demo_fixture_key (and optional explicit company_ids), always
  #   refusing any non-demo company;
  # - employees by deterministic 900-area SSN digits (or explicit employee_map);
  # - QuickBooks HistoricalWorker and HistoricalPaycheck rows by employee_id,
  #   keeping external_key and private_snapshot consistent so rerunning
  #   DemoCompany::Seed or uploading QuickbooksSample stub PDFs still matches;
  # - demo client and portal_employee logins by company_id, role, account links,
  #   and optional client_user_map.
  #
  # Defaults to dry_run: true so operators can inspect planned changes before
  # passing dry_run: false (or APPLY=true in rake demo:rename_fixture).
  class RenameFixture
    class Refused < StandardError; end

    Change = Data.define(:record_type, :record_id, :company_id, :key, :changes)
    Result = Data.define(:dry_run, :companies, :changes, :unmatched_employee_ids) do
      def counts
        changes.group_by(&:record_type).transform_values(&:size)
      end
    end

    KNOWN_FIXTURE_KEYS = [ Roster::KITCHEN, Roster::CATERING ].freeze
    COMPANY_FIELDS = %i[address_line1 city state zip bank_name bank_address filing_contact_name].freeze

    def initialize(organization:, actor:, dry_run: true, company_ids: nil, employee_map: {}, client_user_map: {})
      @organization = organization
      @actor = actor
      @dry_run = dry_run ? true : false
      @company_ids = normalize_ids(company_ids)
      @employee_map = employee_map.to_h.transform_keys { |id| Integer(id) }.transform_values(&:to_s)
      @client_user_map = client_user_map.to_h.transform_keys { |id| Integer(id) }.transform_values(&:to_s)
    end

    def call
      with_organization_lock do
        companies = system_scope do
          authorize!
          resolve_target_companies!
        end

        changes = []
        unmatched_employee_ids = []
        matched_by_company = {}

        companies.each do |company|
          company_changes, matched, unmatched = company_scope(company) { process_company!(company) }
          changes.concat(company_changes)
          unmatched_employee_ids.concat(unmatched)
          matched_by_company[company.id] = matched
        end

        user_changes = system_scope { process_users!(companies, matched_by_company) }
        changes.concat(user_changes)

        unless dry_run
          companies.each do |company|
            company_changes = changes.select { |change| change.company_id == company.id }
            next if company_changes.empty?

            company_scope(company) { record_audit!(company, company_changes) }
          end
        end

        Result.new(
          dry_run: dry_run,
          companies: companies,
          changes: changes,
          unmatched_employee_ids: unmatched_employee_ids.uniq.sort
        )
      end
    end

    private

    attr_reader :organization, :actor, :dry_run, :company_ids, :employee_map, :client_user_map

    def normalize_ids(raw)
      return nil if raw.nil?

      values = Array(raw).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:blank?)
      return nil if values.empty?

      values.map { |value| Integer(value) }.uniq
    rescue ArgumentError
      raise Refused, "Company IDs must be integers"
    end

    def authorize!
      allowed = organization.present? && actor&.organization_admin? && actor.payroll_access_allowed? &&
        actor.organization_id == organization.id && StaffRolePolicy.allowed?(actor, :manage_organization)
      raise Refused, "An organization administrator is required" unless allowed
    end

    def with_organization_lock(&)
      DedicatedAdvisoryLock.with_lock(Seed::LOCK_KEY_BASE + Integer(organization.id), wait_seconds: 0, &)
    rescue DedicatedAdvisoryLock::Unavailable
      raise Refused, "Another demo operation is in progress for this organization"
    end

    def system_scope(&)
      TenantScope.current ? yield : TenantScope.as_system(reason: "Rename demo fixture names and addresses", &)
    end

    def company_scope(company, &)
      TenantScope.current ? yield : TenantScope.with_company(company.id, &)
    end

    def fixture_key(company) = company.test_workspace_manifest["demo_fixture_key"]

    def spec_for(company) = Seed::COMPANIES.find { |entry| entry[:key] == fixture_key(company) }

    def demo!(company)
      raise Refused, "Refusing to modify #{company.name}: it is not a demo company" unless company.reload.demo?
    end

    def resolve_target_companies!
      scope = Company.where(organization_id: organization.id)
      companies = if company_ids
        found = scope.where(id: company_ids).order(:id).to_a
        missing = company_ids - found.map(&:id)
        raise Refused, "Demo company ID(s) not found in organization: #{missing.join(', ')}" if missing.any?
        found
      else
        scope.demo.where("test_workspace_manifest ->> 'demo_fixture_key' IN (?)", KNOWN_FIXTURE_KEYS).order(:id).to_a
      end

      raise Refused, "No demo companies found for this organization" if companies.empty?

      companies.each do |company|
        demo!(company)
        unless KNOWN_FIXTURE_KEYS.include?(fixture_key(company))
          raise Refused, "Refusing to rename #{company.name}: unrecognized demo fixture key"
        end
      end
      companies
    end

    def process_company!(company)
      if dry_run
        evaluate_company(company)
      else
        ApplicationRecord.transaction do
          company.lock!
          demo!(company)
          evaluate_company(company, apply: true)
        end
      end
    end

    def evaluate_company(company, apply: false)
      spec = spec_for(company)
      changes = []

      company_diff = plan_company_updates(company, spec)
      if company_diff.any?
        company.update!(company_diff) if apply
        changes << Change.new(record_type: "company", record_id: company.id, company_id: company.id,
          key: spec[:key], changes: company_diff)
      end

      changes.concat(plan_and_apply_help_contacts(company, spec, apply: apply))

      matched, unmatched, employee_changes = plan_and_apply_employees(company, spec[:key], apply: apply)
      changes.concat(employee_changes)

      changes.concat(plan_and_apply_quickbooks_history(company, matched, apply: apply))

      [ changes, matched, unmatched ]
    end

    def plan_company_updates(company, spec)
      desired = spec[:profile].slice(:address_line1, :city, :state, :zip, :filing_contact_name)
        .merge(spec[:bank].slice(:bank_name, :bank_address))
      desired.select { |field, value| company.public_send(field) != value }
    end

    def plan_and_apply_help_contacts(company, spec, apply:)
      changes = []
      existing_by_position = company.help_contacts.order(:position).index_by(&:position)
      spec[:help].each_with_index do |expected, index|
        contact = existing_by_position[index + 1]
        next unless contact
        next unless contact.role == expected[:role] || contact.email == expected[:email]
        next if contact.name == expected[:name]

        diff = { name: expected[:name] }
        contact.update!(diff) if apply
        changes << Change.new(record_type: "company_help_contact", record_id: contact.id, company_id: company.id,
          key: "#{spec[:key]}:help:#{contact.position}", changes: diff)
      end
      changes
    end

    def plan_and_apply_employees(company, company_key, apply:)
      matched = {}
      unmatched = []
      changes = []

      employees = company.employees.order(:id)
      employees = employees.lock if apply

      employees.each do |employee|
        person = resolve_roster_person(company_key, employee)
        unless person
          unmatched << employee.id
          next
        end

        previous_full_name = employee.full_name
        desired = {
          first_name: person[:first],
          last_name: person[:last],
          middle_name: nil,
          address_line1: Roster.address_line1_for(person),
          city: Roster::EMPLOYEE_CITY,
          state: Roster::EMPLOYEE_STATE,
          zip: Roster::EMPLOYEE_ZIP
        }
        diff = desired.select { |field, value| employee.public_send(field) != value }
        if diff.any?
          employee.update!(diff) if apply
          changes << Change.new(record_type: "employee", record_id: employee.id, company_id: company.id,
            key: person[:key], changes: diff)
        end

        matched[employee.id] = { person: person, previous_full_name: previous_full_name }
      end

      [ matched, unmatched, changes ]
    end

    def resolve_roster_person(company_key, employee)
      if employee_map.key?(employee.id)
        person = Roster.find_person(company_key, key: employee_map.fetch(employee.id))
        raise Refused, "Unknown roster key #{employee_map.fetch(employee.id).inspect} for employee #{employee.id}" unless person

        return person
      end

      Roster.find_person(company_key, ssn_digits: employee.ssn_digits)
    end

    def plan_and_apply_quickbooks_history(company, matched, apply:)
      return [] if matched.empty?

      changes = []
      batches = company.historical_import_batches
        .where(source_system: "quickbooks_online")
        .where.not(status: %w[failed reversed])
        .order(:id)
      batches = batches.lock if apply

      batches.each do |batch|
        changes.concat(rename_batch_workers(company, batch, matched, apply: apply))
        changes.concat(rename_batch_paychecks(company, batch, matched, apply: apply))
      end
      changes
    end

    def rename_batch_workers(company, batch, matched, apply:)
      workers = batch.historical_workers.where(employee_id: matched.keys).order(:id)
      workers = workers.lock if apply
      workers = workers.to_a
      return [] if workers.empty?

      planned = workers.filter_map do |worker|
        entry = matched.fetch(worker.employee_id)
        person = entry[:person]
        target_name = Roster.quickbooks_name(person)
        target_normalized = QuickbooksHistory::NameNormalizer.call(target_name)
        target_key = Digest::SHA256.hexdigest(target_normalized)

        diff = {}
        diff[:source_name] = target_name if worker.source_name != target_name
        diff[:normalized_name] = target_normalized if worker.normalized_name != target_normalized
        diff[:external_key] = target_key if worker.external_key != target_key

        new_snapshot = rewrite_worker_snapshot(worker, person, target_name, entry[:previous_full_name])
        diff[:private_snapshot] = new_snapshot unless new_snapshot.nil?

        next if diff.empty?

        { worker: worker, person: person, diff: diff }
      end
      return [] if planned.empty?

      if apply
        stage_conflicting_keys!(
          planned.map { |item| [ item[:worker], item[:diff][:external_key] ] },
          existing_keys: batch.historical_workers.pluck(:id, :external_key).to_h
        )
        now = Time.current
        planned.each do |item|
          columns = item[:diff].except(:private_snapshot).merge(updated_at: now)
          if item[:diff].key?(:private_snapshot)
            columns[:private_snapshot] = HistoricalWorker.type_for_attribute(:private_snapshot).serialize(item[:diff][:private_snapshot])
          end
          item[:worker].update_columns(columns)
        end
      end

      planned.map do |item|
        reported = item[:diff].except(:private_snapshot)
        reported[:private_snapshot] = "updated" if item[:diff].key?(:private_snapshot)
        Change.new(record_type: "historical_worker", record_id: item[:worker].id, company_id: company.id,
          key: item[:person][:key], changes: reported)
      end
    end

    def rewrite_worker_snapshot(worker, person, target_name, previous_full_name)
      return nil if worker.private_snapshot.blank?

      data = worker.private_snapshot_data
      return nil if data.empty?

      old_source = worker.source_name
      new_full = Roster.full_name(person)
      updated = data.transform_values do |value|
        next value unless value.is_a?(String)

        replaced = value
        replaced = replaced.gsub(old_source, target_name) if old_source.present? && old_source != target_name
        replaced = replaced.gsub(previous_full_name, new_full) if previous_full_name.present? && previous_full_name != new_full
        replaced
      end
      return nil if updated == data

      JSON.generate(updated)
    end

    def rename_batch_paychecks(company, batch, matched, apply:)
      paychecks = batch.historical_paychecks.where(employee_id: matched.keys).order(:source_row_number, :id)
      paychecks = paychecks.lock if apply
      paychecks = paychecks.to_a
      return [] if paychecks.empty?

      occurrences = Hash.new(0)
      planned = paychecks.filter_map do |paycheck|
        person = matched.fetch(paycheck.employee_id)[:person]
        target_name = Roster.quickbooks_name(person)
        target_normalized = QuickbooksHistory::NameNormalizer.call(target_name)
        signature = [ target_normalized, paycheck.pay_date.iso8601, paycheck.gross_pay.to_s("F"), paycheck.net_pay.to_s("F") ].join("|")
        occurrences[signature] += 1
        target_key = Digest::SHA256.hexdigest("#{signature}|#{occurrences[signature]}")

        diff = {}
        diff[:source_employee_name] = target_name if paycheck.source_employee_name != target_name
        diff[:external_key] = target_key if paycheck.external_key != target_key
        next if diff.empty?

        { paycheck: paycheck, person: person, diff: diff }
      end
      return [] if planned.empty?

      if apply
        stage_conflicting_keys!(
          planned.map { |item| [ item[:paycheck], item[:diff][:external_key] ] },
          existing_keys: batch.historical_paychecks.pluck(:id, :external_key).to_h
        )
        now = Time.current
        planned.each do |item|
          item[:paycheck].update_columns(item[:diff].merge(updated_at: now))
        end
      end

      planned.map do |item|
        Change.new(record_type: "historical_paycheck", record_id: item[:paycheck].id, company_id: company.id,
          key: item[:person][:key], changes: item[:diff])
      end
    end

    # Prevents transient unique-index collisions on (historical_import_batch_id,
    # external_key) if two rows in the same batch ever swap keys.
    def stage_conflicting_keys!(pairs, existing_keys:)
      target_keys = pairs.filter_map { |_row, key| key }.to_set
      return if target_keys.empty?

      pairs.each do |row, new_key|
        next if new_key.nil?
        next unless existing_keys.any? { |other_id, existing_key| other_id != row.id && existing_key == new_key }

        row.update_columns(external_key: "rename-tmp-#{row.id}-#{SecureRandom.hex(4)}")
      end
    end

    def process_users!(companies, matched_by_company)
      company_by_id = companies.index_by(&:id)
      matched_by_employee_id = matched_by_company.values.reduce({}, :merge)

      if dry_run
        evaluate_users(companies, company_by_id, matched_by_employee_id, apply: false)
      else
        ApplicationRecord.transaction do
          evaluate_users(companies, company_by_id, matched_by_employee_id, apply: true)
        end
      end
    end

    def evaluate_users(companies, company_by_id, matched_by_employee_id, apply:)
      changes = []
      companies.each do |company|
        changes.concat(evaluate_client_users(company, matched_by_employee_id, apply: apply))
        changes.concat(evaluate_portal_employee_users(company, company_by_id, matched_by_employee_id, apply: apply))
      end
      changes
    end

    def evaluate_client_users(company, matched_by_employee_id, apply:)
      return [] unless fixture_key(company) == Roster::KITCHEN

      users = User.where(company_id: company.id, role: "client").order(:id)
      users = users.lock if apply
      users = users.to_a
      return [] if users.empty?

      manager_employee_id = matched_by_employee_id.find do |_id, entry|
        entry[:person][:key] == "employee-10"
      end&.first

      linked_to_manager = if manager_employee_id
        EmployeeAccountLink.where(company_id: company.id, employee_id: manager_employee_id, user_id: users.map(&:id)).pluck(:user_id).to_set
      else
        Set.new
      end

      assignments = assign_client_labels(users, linked_to_manager)
      changes = []
      users.each do |user|
        target_name = assignments[user.id]
        next if target_name.blank? || user.name == target_name

        diff = { name: target_name }
        user.update!(diff) if apply
        changes << Change.new(record_type: "user", record_id: user.id, company_id: company.id,
          key: "client:#{user.id}", changes: diff)
      end
      changes
    end

    def assign_client_labels(users, linked_to_manager)
      assignments = {}
      users.each do |user|
        if client_user_map.key?(user.id)
          assignments[user.id] = client_user_map.fetch(user.id)
        elsif [ Roster::CLIENT_MANAGER_LABEL, Roster::CLIENT_USER_LABEL ].include?(user.name)
          assignments[user.id] = user.name
        end
      end

      remaining = users.reject { |user| assignments.key?(user.id) }
      unless assignments.value?(Roster::CLIENT_MANAGER_LABEL)
        manager = remaining.find { |user| linked_to_manager.include?(user.id) } ||
          remaining.find { |user| user.email.to_s.split("@", 2).first.to_s.match?(/manager/i) } ||
          remaining.first
        if manager
          assignments[manager.id] = Roster::CLIENT_MANAGER_LABEL
          remaining.delete(manager)
        end
      end

      extra_index = 1
      remaining.each do |user|
        label = if !assignments.value?(Roster::CLIENT_USER_LABEL)
          Roster::CLIENT_USER_LABEL
        else
          extra_index += 1
          "#{Roster::CLIENT_USER_LABEL} #{extra_index}"
        end
        assignments[user.id] = label
      end
      assignments
    end

    def evaluate_portal_employee_users(company, company_by_id, matched_by_employee_id, apply:)
      users = User.where(company_id: company.id, role: "portal_employee").order(:id)
      users = users.lock if apply
      users = users.to_a
      return [] if users.empty?

      links_by_user = EmployeeAccountLink.where(user_id: users.map(&:id)).group_by(&:user_id)
      changes = []
      users.each do |user|
        links = links_by_user[user.id]
        next if links.blank?
        next unless links.all? { |link| company_by_id.key?(link.company_id) && matched_by_employee_id.key?(link.employee_id) }

        numbers = links.map { |link| matched_by_employee_id.fetch(link.employee_id)[:person][:number] }.uniq
        next unless numbers.one?

        person = matched_by_employee_id.fetch(links.first.employee_id)[:person]
        target_name = Roster.full_name(person)
        next if user.name == target_name

        diff = { name: target_name }
        user.update!(diff) if apply
        changes << Change.new(record_type: "user", record_id: user.id, company_id: company.id,
          key: person[:key], changes: diff)
      end
      changes
    end

    def record_audit!(company, company_changes)
      AuditLog.record!(
        user: actor,
        organization_id: organization.id,
        company_id: company.id,
        action: "demo_company#fixture_renamed",
        record_type: "Company",
        record_id: company.id,
        subject_name: company.name,
        metadata: {
          fixture_key: fixture_key(company),
          counts: company_changes.group_by(&:record_type).transform_values(&:size)
        }
      )
    end
  end
end
