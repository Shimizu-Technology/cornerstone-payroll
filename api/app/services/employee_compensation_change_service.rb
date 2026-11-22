# frozen_string_literal: true

# The one write path for pay rates and wage rates (M3-4).
#
# employees.pay_rate and the employee_wage_rates label/rate/primary/active
# columns are caches of the version in effect today. History lives in
# employee_compensation_changes and employee_wage_rate_versions, and payroll
# readers resolve rates from it on the pay period's end date.
#
# A change compares submitted values with the version on its effective date.
# It is recorded as a new version starting on `effective_on`; the version it
# interrupts ends the day before, and a later scheduled version stays in place.
# Payroll that was approved or committed for the employee on or after that
# date is protected: the change is refused unless it is an explicit
# historical correction, which records history without touching any paycheck.
#
# Model guards on Employee, EmployeeWageRate and both history tables reject
# rate mutations outside this service, and spec/lint/compensation_write_path_spec.rb
# rejects raw SQL or bulk updates of those columns anywhere else in the app.
class EmployeeCompensationChangeService
  class Error < StandardError; end
  # Raised (and rendered as 422) when a change would rewrite rates for payroll
  # that is already approved or committed.
  class LockedPeriodError < Error; end
  class ConflictError < Error; end
  # Raised by the model guards when code bypasses this service.
  class CompensationMutationError < StandardError; end

  BASIS_ATTRIBUTES = %w[employment_type salary_type pay_frequency contractor_pay_type].freeze
  COMPENSATION_ATTRIBUTES = %w[pay_rate].concat(BASIS_ATTRIBUTES).freeze
  WAGE_RATE_ATTRIBUTES = EmployeeWageRateVersion::SNAPSHOT_ATTRIBUTES
  LOCKING_STATUSES = %w[approved committed].freeze
  # Off-cycle tips, bonus and commission runs do not pay from the rate, and
  # correction runs keep their source's snapshot, so they do not lock it.
  LOCKING_RUN_PURPOSES = %w[regular final].freeze
  EFFECTIVE_DATE_CHOICES = %w[next_uncommitted_period today custom].freeze
  RESERVED_LABEL_PREFIX = "__compensation_cache__".freeze
  UNCHANGED = Object.new.freeze
  WRITE_CONTEXT_KEY = :employee_compensation_write_ids

  Result = Struct.new(:employee, :effective_on, :compensation_change, :wage_rate_versions, :warnings, keyword_init: true) do
    def changed?
      compensation_change.present? || wage_rate_versions.any?
    end
  end

  class << self
    # Run once all legacy writers are drained and before the dated writers/job
    # are enabled. Only the migration's baseline can be superseded by a legacy
    # cache value. A scheduled version whose cache has yet to activate is ignored.
    def reconcile_rollout!(employee_id, as_of:)
      Employee.transaction do
        company_id = Employee.where(id: employee_id).pick(:company_id)
        next unless company_id

        Company.lock.find(company_id)
        employee = Employee.lock.find(employee_id)
        compensation = employee.compensation_on(as_of)
        wage_rates = employee.employee_wage_rates.to_a
        new_employee = !compensation
        missing_rates = wage_rates.reject { |row| row.employee_wage_rate_versions.exists? || row.label.start_with?(RESERVED_LABEL_PREFIX) }
        latest = employee.employee_compensation_changes.where.not(source: "backfill").exists?
        changes = if compensation&.source == "backfill" && !latest
          legacy_changes(employee, compensation)
        else
          {}
        end
        edits = wage_rates.filter_map do |row|
          version = employee.wage_rate_version_for(row, as_of)
          next unless version&.source == "backfill" && !row.employee_wage_rate_versions.where.not(source: "backfill").exists?

          values = legacy_changes(row, version)
          values.merge(id: row.id) if values.any?
        end
        next if !new_employee && missing_rates.empty? && changes.empty? && edits.empty?

        record_initial!(employee, source: "rollout_reconciliation") if new_employee
        missing_rates.each { |row| record_wage_rate_created!(row, sync: false) }
        result = new(employee: employee, actor: nil, source: "rollout_reconciliation", pay_rate: changes.fetch("pay_rate", UNCHANGED),
          effective_on: reconciliation_date(employee, as_of), basis: changes.slice(*BASIS_ATTRIBUTES), wage_rate_edits: edits).call!
        sync_cache!(employee, as_of: as_of)
        { employee_id: employee.id, wage_rate_ids: (missing_rates.map(&:id) + result.wage_rate_versions.map(&:employee_wage_rate_id)).uniq }
      end
    end

    def writing?(employee_id)
      employee_id.present? && write_context.include?(employee_id)
    end

    # Opens the write context for one employee. Callers outside this class use
    # it only through the history-copy and initial-version helpers below.
    def writing_for(employee_id)
      added = employee_id.present? && write_context.add?(employee_id)
      yield
    ensure
      write_context.delete(employee_id) if added
    end

    # The latest pay period end date that is approved or committed for this
    # employee, or nil when no payroll for them is locked yet.
    def locked_through(employee)
      PayPeriod.joins(:payroll_items)
        .where(company_id: employee.company_id, status: LOCKING_STATUSES, run_purpose: LOCKING_RUN_PURPOSES)
        .where(payroll_items: { employee_id: employee.id })
        .maximum(:end_date)
    end

    # "Start of next uncommitted pay period": the day after the employee's
    # last approved or committed payroll, or, before their first one, the start
    # of their pay history (so the change applies to all of their payroll).
    def next_uncommitted_period_start(employee)
      locked = locked_through(employee)
      locked ? locked + 1 : baseline_effective_on(employee)
    end
    alias default_effective_on next_uncommitted_period_start

    def baseline_effective_on(employee)
      employee.employee_compensation_changes.where(historical_correction: false).minimum(:effective_on) || initial_effective_on(employee)
    end

    def initial_effective_on(employee)
      created_on = employee.created_at ? PayrollBusinessClock.date_for(employee.created_at) : PayrollBusinessClock.today
      [ employee.hire_date, created_on ].compact.min
    end

    def effective_date_options(employee)
      today = PayrollBusinessClock.today
      locked = locked_through(employee)
      {
        next_uncommitted_period: next_uncommitted_period_start(employee),
        today: today,
        locked_through: locked,
        earliest_allowed: locked ? locked + 1 : nil
      }
    end

    # Records the first version for a newly created employee and any wage
    # rates created with it. Called from Employee's after_create, inside the
    # creation transaction.
    def record_initial!(employee, source: nil, reason: nil)
      writing_for(employee.id) do
        effective_on = initial_effective_on(employee)
        employee.employee_compensation_changes.create!(
          employee.attributes.slice(*EmployeeCompensationChange::SNAPSHOT_ATTRIBUTES).merge(
            company_id: employee.company_id,
            effective_on: effective_on,
            reason: reason.presence || "Initial pay setup",
            source: source.presence || "employee_creation",
            created_by_id: Current.user&.id || employee.try(:created_by_id)
          )
        )
      end
    end

    # A wage rate added outside a compensation change (an employee creation
    # path or setup code) starts on the default effective date: the start of
    # the employee's pay history while nothing is locked, otherwise the day
    # after their last approved or committed payroll.
    def record_wage_rate_created!(wage_rate, sync: true)
      employee = wage_rate.employee
      writing_for(employee.id) do
        effective_on = default_effective_on(employee)
        wage_rate.employee_wage_rate_versions.create!(
          wage_rate.attributes.slice(*WAGE_RATE_ATTRIBUTES).merge(
            company_id: employee.company_id,
            employee_id: employee.id,
            effective_on: effective_on,
            reason: "Wage rate added",
            source: "wage_rate_created",
            created_by_id: Current.user&.id
          )
        )
        sync_cache!(employee) if sync
      end
    end

    # Copies the source employee's full compensation history onto a copied
    # employee (test workspaces, rehearsal promotion). The block copies the
    # wage-rate rows inside the write context and returns
    # { source_wage_rate_id => target_wage_rate }.
    def copy_history!(source:, target:)
      writing_for(target.id) do
        purge_history_under_context!([ target.id ])
        rate_map = block_given? ? yield.to_h : {}
        changes = source.employee_compensation_changes.chronological.to_a
        if changes.empty?
          record_initial!(target, source: "copied_setup", reason: "Copied pay setup")
        else
          changes.each do |change|
            target.employee_compensation_changes.create!(copied_attributes(change, target))
          end
        end
        source.employee_wage_rate_versions.chronological.each do |version|
          target_rate = rate_map.fetch(version.employee_wage_rate_id)
          target.employee_wage_rate_versions.create!(
            copied_attributes(version, target).merge(employee_wage_rate_id: target_rate.id)
          )
        end
        rate_map.each_value do |target_rate|
          next if target_rate.employee_wage_rate_versions.exists?

          record_wage_rate_created!(target_rate)
        end
      end
    end

    # Rehearsal promotion replaces a mapped employee's setup wholesale: its
    # compensation history and wage-rate rows are removed, then copied from
    # the rehearsal with copy_history!.
    def purge_test_workspace_history!(company)
      raise Error, "Compensation history teardown is limited to test workspaces" unless company.test_workspace?
      raise Error, "Compensation history teardown requires a transaction" unless company.class.connection.transaction_open?

      company.lock!
      purge_history_under_context!(company.employees.select(:id))
    end

    def purge_compensation_setup!(employee_ids)
      ids = Array(employee_ids).compact
      purge_history_under_context!(ids)
      EmployeeWageRate.where(employee_id: ids).delete_all
    end

    # Rewrites the cache columns from the version in effect on `as_of`.
    # SyncEffectiveCompensationJob runs this daily so scheduled changes
    # activate on their effective date.
    def sync_cache!(employee, as_of: PayrollBusinessClock.today)
      writing_for(employee.id) do
        reset_history_associations!(employee)
        desired_compensation = employee.compensation_on(as_of)&.snapshot || {}
        stored = Employee.find(employee.id)
        changes = desired_compensation.reject { |attribute, value| comparable(stored[attribute]) == comparable(value) }
        employee.update_columns(changes) if changes.any?

        desired_rates = employee.employee_wage_rates.reload.index_with do |row|
          employee.wage_rate_version_for(row, as_of)&.snapshot ||
            { "label" => row.label.start_with?(RESERVED_LABEL_PREFIX) ? row.label : reserved_label,
              "active" => false, "is_primary" => false }
        end
        desired_rates.each do |row, desired|
          row.update_columns(label: reserved_label) if row.label != desired["label"]
        end
        desired_rates.each do |row, desired|
          changes = desired.reject { |attribute, value| comparable(row[attribute]) == comparable(value) }
          row.update_columns(changes) if changes.any?
        end
        reset_history_associations!(employee)
      end
    end

    def reset_history_associations!(employee)
      %i[employee_wage_rates employee_wage_rate_versions employee_compensation_changes].each do |name|
        employee.association(name).reset
      end
    end

    def revision(employee)
      versions = [ employee.employee_compensation_changes, employee.employee_wage_rate_versions ]
      timeline = versions.map do |rows|
        rows.chronological.map { |row| [ row.id, row.effective_on, row.ends_on, row.snapshot, row.updated_at.iso8601(6) ] }
      end
      today = PayrollBusinessClock.today
      current = [ employee.compensation_on(today)&.id, employee.wage_rates_on(today, include_inactive: true).map do |row|
        employee.wage_rate_version_for(row, today)&.id
      end ]
      Digest::SHA256.hexdigest([ timeline, current ].to_json)
    end

    def snapshot(employee, date)
      employee.compensation_on(date)&.snapshot || employee.attributes.slice(*COMPENSATION_ATTRIBUTES)
    end

    def validate_basis_transition!(employee, date, basis, historical_correction: false)
      today = PayrollBusinessClock.today
      current = snapshot(employee, date)
      changed = basis.stringify_keys.select { |key, value| current[key] != value }
      return if changed.empty?

      if date > today
        raise Error, "Pay type changes take effect immediately. Choose today or an earlier date when the pay type also changes."
      end
      if !historical_correction && employee.employee_compensation_changes.where("effective_on > ?", today).exists?
        raise Error, "A pay change is already scheduled. Cancel it before changing the pay type."
      end

      proposed = Employee.instantiate(employee.attributes.merge(current).merge(changed))
      return if proposed.valid?

      raise Error, proposed.errors.full_messages.to_sentence
    end

    def reserved_label
      "#{RESERVED_LABEL_PREFIX}#{SecureRandom.uuid}"
    end

    def comparable(value)
      case value
      when BigDecimal, Numeric then BigDecimal(value.to_s).round(6).to_s("F")
      when nil then nil
      else value
      end
    end

    private

    def reconciliation_date(employee, as_of)
      open_end = PayPeriod.joins(:payroll_items).where(company_id: employee.company_id, status: %w[draft calculated])
        .where(payroll_items: { employee_id: employee.id }).minimum(:end_date)
      [ [ open_end || as_of, as_of ].min, default_effective_on(employee) ].max
    end

    def legacy_changes(cache, version)
      return {} if cache.updated_at <= version.created_at

      cache.attributes.slice(*version.snapshot.keys).reject do |field, value|
        comparable(value) == comparable(version[field])
      end
    end

    def write_context
      ActiveSupport::IsolatedExecutionState[WRITE_CONTEXT_KEY] ||= Set.new
    end

    def purge_history_under_context!(ids)
      EmployeeWageRateVersion.where(employee_id: ids).delete_all
      EmployeeCompensationChange.where(employee_id: ids).delete_all
    end

    def copied_attributes(record, target)
      record.attributes.except("id", "company_id", "employee_id", "employee_wage_rate_id", "created_at", "updated_at")
        .merge("company_id" => target.company_id)
    end
  end

  # pay_rate: the requested new pay rate (omit to leave it unchanged).
  # wage_rates: a full desired wage-rate list in EmployeeWageRateSyncService
  #   format; rows left out are kept unless replace_missing_wage_rates is set,
  #   in which case they are ended, never deleted.
  # wage_rate_edits: single-row edits applied as given, each
  #   { id:, label:, rate:, is_primary:, active: } or { id:, remove: true }.
  def initialize(employee:, actor:, source:, reason: nil, effective_on: nil, pay_rate: UNCHANGED,
                 wage_rates: nil, replace_missing_wage_rates: false, wage_rate_edits: [],
                 historical_correction: false, basis: {}, expected_revision: UNCHANGED, cancel: false,
                 reject_scheduled_conflict: false)
    @employee = employee
    @actor = actor
    @source = source.to_s
    @reason = reason.to_s.strip
    @basis = basis.stringify_keys.slice(*BASIS_ATTRIBUTES)
    @expected_revision = expected_revision
    @cancel = cancel
    @reject_scheduled_conflict = reject_scheduled_conflict
    @requested_effective_on = effective_on
    @pay_rate = pay_rate
    @wage_rates = wage_rates
    @replace_missing_wage_rates = replace_missing_wage_rates
    @wage_rate_edits = Array(wage_rate_edits)
    @historical_correction = ActiveModel::Type::Boolean.new.cast(historical_correction) == true
  end

  def call!
    result = nil
    Employee.transaction(requires_new: true) do
      Company.lock.find(employee.company_id)
      # Lock a fresh copy rather than reloading the caller's record, whose
      # saved changes feed the request audit.
      @locked = Employee.find(employee.id)
      @locked.with_lock do
        self.class.reset_history_associations!(employee)
        self.class.writing_for(employee.id) { result = @cancel ? cancel! : apply! }
      end
    end
    result
  end

  private

  attr_reader :employee, :actor, :source, :reason, :pay_rate, :wage_rates, :wage_rate_edits

  def apply!
    effective_on = resolve_effective_on
    current = self.class.snapshot(employee, effective_on)
    before_rates = wage_rate_snapshots(effective_on)
    requested = @basis.dup
    requested["pay_rate"] = normalized_pay_rate unless pay_rate.equal?(UNCHANGED)
    changes = requested.reject { |key, value| self.class.comparable(current[key]) == self.class.comparable(value) }
    edits = desired_wage_rate_edits(before_rates)
    if changes.any? || edits.any? || @historical_correction
      validate_revision!
      validate_effective_on!(effective_on)
    end
    self.class.validate_basis_transition!(employee, effective_on, changes.slice(*BASIS_ATTRIBUTES),
                                         historical_correction: @historical_correction)
    validate_scheduled_conflict!(effective_on) if @reject_scheduled_conflict && (changes.any? || edits.any?)

    compensation_change = if changes.any?
      apply_version!(employee.employee_compensation_changes, effective_on, current.merge(changes), restore: current)
    end
    wage_rate_versions = edits.map do |id, values|
      row = id ? employee.employee_wage_rates.find(id) : employee.employee_wage_rates.create!(label: self.class.reserved_label, active: false)
      prior = before_rates[id]
      desired = (prior || { "active" => true, "is_primary" => false }).merge(values)
      restore = prior || desired.merge("active" => false, "is_primary" => false)
      owners = { "employee_id" => employee.id }
      apply_version!(row.employee_wage_rate_versions, effective_on, desired.merge(owners), restore: restore.merge(owners))
    end

    finish!(effective_on, current, before_rates) if changes.any? || edits.any?
    result(effective_on, compensation_change, wage_rate_versions)
  end

  def cancel!
    validate_revision!
    effective_on = resolve_effective_on
    raise Error, "Choose a scheduled date and explain why this change is being cancelled" if effective_on <= PayrollBusinessClock.today || reason.blank?

    validate_effective_on!(effective_on)
    current = self.class.snapshot(employee, effective_on)
    before_rates = wage_rate_snapshots(effective_on)
    versions = employee.employee_compensation_changes.where(effective_on: effective_on).to_a +
      employee.employee_wage_rate_versions.where(effective_on: effective_on).to_a
    raise ConflictError, "There is no longer a scheduled change on that date." if versions.empty?

    versions.each do |version|
      scope = version.is_a?(EmployeeCompensationChange) ? employee.employee_compensation_changes : version.employee_wage_rate.employee_wage_rate_versions
      previous = scope.where(effective_on: ...effective_on).chronological.last
      ends_on = version.ends_on
      version.destroy!
      previous&.update!(ends_on: ends_on)
    end
    finish!(effective_on, current, before_rates, cancelled: true)
    result(effective_on, nil, [])
  end

  def finish!(effective_on, current, before_rates, cancelled: false)
    self.class.reset_history_associations!(employee)
    validate_wage_timeline!(effective_on)
    self.class.sync_cache!(employee)
    invalidate_intake_confirmation!
    audit!(effective_on, current, before_rates, mid_period_warnings(effective_on), cancelled: cancelled)
  end

  def result(effective_on, compensation_change, wage_rate_versions)
    warnings = (compensation_change || wage_rate_versions.any?) ? mid_period_warnings(effective_on) : []
    Result.new(employee: employee, effective_on: effective_on, compensation_change: compensation_change,
               wage_rate_versions: wage_rate_versions, warnings: warnings)
  end

  def validate_revision!
    return if @expected_revision.equal?(UNCHANGED) || @expected_revision == self.class.revision(employee)

    raise ConflictError, "Pay settings changed. Reload the employee before editing compensation."
  end

  def validate_scheduled_conflict!(effective_on)
    dates = [ effective_on, PayrollBusinessClock.today ].min
    return unless employee.employee_compensation_changes.where(effective_on: dates..).where.not(source: %w[backfill employee_creation]).exists? ||
      employee.employee_wage_rate_versions.where(effective_on: dates..).where.not(source: %w[backfill wage_rate_created]).exists?

    raise ConflictError, "The employee already has a compensation change on or after the proposed date. Review their pay history."
  end

  # A manager's payroll confirmation for an intake exception covers the pay
  # setup they saw; any recorded change, including a scheduled one, needs a
  # fresh confirmation (as a direct pay-rate edit always did).
  def invalidate_intake_confirmation!
    changed = Employee.where(id: employee.id).where.not(intake_exception: {}).where.not(intake_payroll_confirmed_at: nil)
      .update_all(intake_payroll_confirmed_at: nil, updated_at: Time.current)
    return unless changed.positive?

    employee.intake_payroll_confirmed_at = nil
    employee.clear_attribute_changes([ :intake_payroll_confirmed_at ])
  end

  def resolve_effective_on
    value = @requested_effective_on
    return self.class.default_effective_on(employee) if value.blank?
    return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

    Date.iso8601(value.to_s)
  rescue Date::Error, ArgumentError
    raise Error, "Choose a valid effective date for the pay change"
  end

  def validate_effective_on!(effective_on)
    locked = self.class.locked_through(employee)
    if @historical_correction
      raise Error, "Choose a date in locked payroll for a historical correction" if !locked || effective_on > locked
      raise Error, "Explain why this is a historical correction" if reason.blank?
      unless StaffRolePolicy.allowed?(actor || Current.user, :manage_client_configuration, company: employee.company)
        raise Error, "Client configuration access is required for historical pay corrections"
      end
      @restore_on = locked + 1
      return
    end
    return if locked.nil? || effective_on > locked

    raise LockedPeriodError,
          "Payroll for #{employee.full_name} is approved or committed through #{locked.iso8601}. " \
          "Choose #{(locked + 1).iso8601} or later, or record this as a historical correction."
  end

  def normalized_pay_rate
    @normalized_pay_rate ||= BigDecimal(pay_rate.to_s).round(2)
  rescue ArgumentError, TypeError
    raise Error, "Pay rate must be a number"
  end

  def wage_rate_snapshots(date)
    employee.wage_rates_on(date, include_inactive: true).to_h do |row|
      [ row.id, row.attributes.slice(*WAGE_RATE_ATTRIBUTES) ]
    end
  end

  def desired_wage_rate_edits(before_rates)
    edits = wage_rate_edits.map { |edit| edit.to_h.symbolize_keys }
    unless wage_rates.nil?
      edits += EmployeeWageRateSyncService.normalize_payload(wage_rates)
      if @replace_missing_wage_rates
        ids = edits.filter_map { |edit| edit[:id] }
        edits += before_rates.filter_map { |id, row| { id: id, remove: true } if row["active"] && !ids.include?(id) }
      end
    end
    edits.filter_map do |edit|
      id = edit[:id].presence&.to_i
      raise Error, "Unknown wage rate on this date" if id && !before_rates.key?(id)

      values = if edit[:remove]
        { "active" => false, "is_primary" => false }
      else
        normalize_wage_edit(edit)
      end
      unless id
        id = before_rates.find { |_, row| !row["active"] && row["label"].casecmp?(values["label"].to_s) }&.first
        values["active"] = true unless values.key?("active")
      end
      if (prior = before_rates[id])
        values = values.reject { |key, value| self.class.comparable(prior[key]) == self.class.comparable(value) }
      end
      [ id, values ] if values.any?
    end
  rescue ArgumentError
    raise Error, "Wage rates must be numbers"
  end

  def normalize_wage_edit(edit)
    values = edit.stringify_keys.slice(*WAGE_RATE_ATTRIBUTES)
    boolean = ActiveModel::Type::Boolean.new
    values["label"] = values["label"].to_s.strip if values.key?("label")
    if values["label"]&.start_with?(RESERVED_LABEL_PREFIX)
      raise Error, "Choose a different wage rate label"
    end
    values["rate"] = BigDecimal(values["rate"].to_s).round(2) if values.key?("rate") && !values["rate"].nil?
    %w[active is_primary].each { |key| values[key] = boolean.cast(values[key]) if values.key?(key) }
    values
  end

  def validate_wage_timeline!(effective_on)
    versions = employee.employee_wage_rate_versions.to_a
    boundaries = versions.flat_map { |version| [ version.effective_on, version.ends_on && version.ends_on + 1 ] }
    ([ effective_on ] + boundaries.compact.select { |date| date >= effective_on }).uniq.sort.each do |date|
      rates = employee.wage_rates_on(date, include_inactive: true)
      if rates.map { |rate| rate.label.downcase }.uniq.size != rates.size
        raise Error, "Wage rate labels must be unique on #{date.iso8601}"
      end
      if rates.count { |rate| rate.active? && rate.is_primary? } > 1
        raise Error, "Choose one primary wage rate on #{date.iso8601}"
      end
    end
  end

  def apply_version!(scope, effective_on, values, restore:)
    if @restore_on && !scope.where(effective_on: (effective_on + 1)..@restore_on).exists?
      insert_version!(scope, @restore_on, restore, historical_correction: false)
    end
    insert_version!(scope, effective_on, values)
  end

  # Inserts a version into one timeline: the version covering the date ends
  # the day before, a later version keeps its start, and a version already
  # starting on the same date is replaced.
  def insert_version!(scope, effective_on, values, historical_correction: @historical_correction)
    attributes = values.merge(
      "company_id" => employee.company_id,
      "reason" => reason.presence || default_reason,
      "source" => source,
      "historical_correction" => historical_correction,
      "created_by_id" => actor&.id
    )
    existing = scope.find_by(effective_on: effective_on)
    if existing
      existing.update!(attributes)
      return existing
    end

    covering = scope.covering(effective_on).first
    following = scope.where("effective_on > ?", effective_on).order(:effective_on).first
    covering&.update!(ends_on: effective_on - 1)
    scope.create!(attributes.merge("effective_on" => effective_on, "ends_on" => following && (following.effective_on - 1)))
  end

  def default_reason
    @historical_correction ? "Historical pay correction" : "Pay rate updated"
  end

  # Rates resolve on the pay period end date, so an open period that starts
  # before and ends on or after the change pays every hour at the new rate.
  def mid_period_warnings(effective_on)
    PayPeriod.where(company_id: employee.company_id, status: %w[draft calculated], correction_status: nil, run_purpose: LOCKING_RUN_PURPOSES)
      .where("start_date < :date AND end_date >= :date", date: effective_on)
      .order(:start_date).map do |period|
        "The #{period.start_date.iso8601} to #{period.end_date.iso8601} payroll is open and this change starts " \
          "mid-period on #{effective_on.iso8601}. That payroll uses the rate in effect on #{period.end_date.iso8601} " \
          "for every hour; split the hours or choose #{period.start_date.iso8601} if part of the period should use the earlier rate."
      end
  end

  def audit!(effective_on, previous, before_rates, warnings, cancelled:)
    AuditLog.record!(
      user: actor || Current.user,
      company_id: employee.company_id,
      action: "employee#compensation_changed",
      record_type: "Employee",
      record_id: employee.id,
      subject_name: employee.full_name,
      metadata: {
        effective_on: effective_on.iso8601,
        reason: reason.presence || default_reason,
        source: source,
        historical_correction: @historical_correction,
        cancelled: cancelled,
        correction_ends_on: @restore_on&.prev_day&.iso8601,
        before: previous.merge(wage_rates: printable_rates(before_rates)),
        after: self.class.snapshot(employee, effective_on).merge(wage_rates: printable_rates(wage_rate_snapshots(effective_on))),
        warnings: warnings
      }
    )
  end

  def printable_rates(rates)
    rates.map { |id, rate| rate.merge("id" => id, "rate" => rate["rate"]&.to_d&.to_s("F")) }
  end
end
