# frozen_string_literal: true

# The one write path for pay rates and wage rates (M3-4).
#
# employees.pay_rate and the employee_wage_rates label/rate/primary/active
# columns are caches of the version in effect today. History lives in
# employee_compensation_changes and employee_wage_rate_versions, and payroll
# readers resolve rates from it on the pay period's end date.
#
# A change is the difference between the submitted values and today's values.
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
  # Raised by the model guards when code bypasses this service.
  class CompensationMutationError < StandardError; end

  BASIS_ATTRIBUTES = %w[employment_type salary_type pay_frequency contractor_pay_type].freeze
  WAGE_RATE_ATTRIBUTES = EmployeeWageRateVersion::SNAPSHOT_ATTRIBUTES
  LOCKING_STATUSES = %w[approved committed].freeze
  # Off-cycle tips, bonus and commission runs do not pay from the rate, and
  # correction runs keep their source's snapshot, so they do not lock it.
  LOCKING_RUN_PURPOSES = %w[regular final].freeze
  EFFECTIVE_DATE_CHOICES = %w[next_uncommitted_period today custom].freeze
  UNCHANGED = Object.new.freeze
  WRITE_CONTEXT_KEY = :employee_compensation_write_ids

  Result = Struct.new(:employee, :effective_on, :compensation_change, :wage_rate_versions, :warnings, keyword_init: true) do
    def changed?
      compensation_change.present? || wage_rate_versions.any?
    end
  end

  class << self
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
      employee.employee_compensation_changes.minimum(:effective_on) || initial_effective_on(employee)
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
    def record_wage_rate_created!(wage_rate)
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
        comp = employee.compensation_on(as_of)
        stored = Employee.where(id: employee.id).pick(:pay_rate)
        if comp && [ stored, employee.pay_rate ].any? { |value| comparable(value) != comparable(comp.pay_rate) }
          employee.update_columns(pay_rate: comp.pay_rate, updated_at: Time.current)
        end
        employee.employee_wage_rates.reload.each do |row|
          desired = employee.wage_rate_version_for(row, as_of)&.snapshot || { "active" => false }
          changes = desired.reject { |attribute, value| comparable(row.public_send(attribute)) == comparable(value) }
          row.update_columns(changes.merge("updated_at" => Time.current)) if changes.any?
        end
        reset_history_associations!(employee)
      end
    end

    def reset_history_associations!(employee)
      %i[employee_wage_rates employee_wage_rate_versions employee_compensation_changes].each do |name|
        employee.association(name).reset
      end
    end

    def comparable(value)
      case value
      when BigDecimal, Numeric then BigDecimal(value.to_s).round(6).to_s("F")
      when nil then nil
      else value
      end
    end

    private

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
                 historical_correction: false)
    @employee = employee
    @actor = actor
    @source = source.to_s
    @reason = reason.to_s.strip
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
        self.class.writing_for(employee.id) { result = apply! }
      end
    end
    result
  end

  private

  attr_reader :employee, :actor, :source, :reason, :pay_rate, :wage_rates, :wage_rate_edits

  def apply!
    today = PayrollBusinessClock.today
    effective_on = resolve_effective_on
    current = employee.compensation_on(today)
    before_rates = wage_rate_snapshots

    pay_rate_changed = !pay_rate.equal?(UNCHANGED) &&
      self.class.comparable(normalized_pay_rate) != self.class.comparable(@locked.pay_rate)
    basis_changed = current.present? && BASIS_ATTRIBUTES.any? { |attribute| current.public_send(attribute) != @locked.public_send(attribute) }

    apply_wage_rate_rows!
    after_rates = wage_rate_snapshots
    touched_rates = after_rates.filter_map do |id, after|
      before = before_rates[id]
      changed = before ? after.select { |attribute, value| self.class.comparable(before[attribute]) != self.class.comparable(value) } : after
      [ id, changed ] if changed.any?
    end.to_h

    if !pay_rate_changed && !basis_changed && touched_rates.empty?
      return Result.new(employee: employee, effective_on: effective_on, compensation_change: nil, wage_rate_versions: [], warnings: [])
    end

    validate_effective_on!(effective_on, today, basis_changed: basis_changed)

    compensation_change = if pay_rate_changed || basis_changed
      record_compensation_version!(effective_on, pay_rate_changed: pay_rate_changed)
    end
    wage_rate_versions = touched_rates.map do |id, changed|
      record_wage_rate_version!(employee.employee_wage_rates.find(id), effective_on, changed, before_rates[id])
    end

    self.class.sync_cache!(employee, as_of: today)
    invalidate_intake_confirmation!
    warnings = mid_period_warnings(effective_on)
    audit!(effective_on, current, before_rates, warnings)
    Result.new(employee: employee, effective_on: effective_on, compensation_change: compensation_change,
               wage_rate_versions: wage_rate_versions, warnings: warnings)
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

  def validate_effective_on!(effective_on, today, basis_changed:)
    raise Error, "Explain why this is a historical correction" if @historical_correction && reason.blank?
    if basis_changed && effective_on > today
      raise Error, "Pay type changes take effect immediately. Choose today or an earlier date when the pay type also changes."
    end
    if basis_changed && employee.employee_compensation_changes.where("effective_on > ?", effective_on).exists?
      raise Error, "A pay change is already scheduled after #{effective_on.iso8601}. Cancel it before changing the pay type."
    end

    locked = self.class.locked_through(employee)
    return if locked.nil? || effective_on > locked || @historical_correction

    raise LockedPeriodError,
          "Payroll for #{employee.full_name} is approved or committed through #{locked.iso8601}. " \
          "Choose #{(locked + 1).iso8601} or later, or record this as a historical correction."
  end

  def normalized_pay_rate
    @normalized_pay_rate ||= BigDecimal(pay_rate.to_s).round(2)
  rescue ArgumentError, TypeError
    raise Error, "Pay rate must be a number"
  end

  def wage_rate_snapshots
    employee.employee_wage_rates.reload.to_h { |row| [ row.id, row.attributes.slice(*WAGE_RATE_ATTRIBUTES) ] }
  end

  def apply_wage_rate_rows!
    unless wage_rates.nil?
      EmployeeWageRateSyncService.new(
        employee: employee, wage_rates: wage_rates, replace_missing: @replace_missing_wage_rates
      ).apply_under_compensation_context!
    end
    wage_rate_edits.each { |edit| apply_wage_rate_edit!(edit.to_h.symbolize_keys) }
  end

  def apply_wage_rate_edit!(edit)
    row = edit[:id].present? ? employee.employee_wage_rates.find(edit[:id]) : nil
    if edit[:remove]
      # An ended rate is no longer anyone's primary rate.
      row&.update!(active: false, is_primary: false)
      return
    end
    attributes = edit.slice(:label, :rate, :is_primary, :active)
    if row
      row.update!(attributes)
    else
      reusable = employee.employee_wage_rates.find_by(label: attributes[:label].to_s.strip, active: false)
      reusable ? reusable.update!(attributes.merge(active: attributes.fetch(:active, true))) : employee.employee_wage_rates.create!(attributes)
    end
  end

  def record_compensation_version!(effective_on, pay_rate_changed:)
    base = (employee.compensation_on(effective_on) || employee.employee_compensation_changes.chronological.first)&.snapshot ||
      @locked.attributes.slice(*EmployeeCompensationChange::SNAPSHOT_ATTRIBUTES)
    values = base.merge(@locked.attributes.slice(*BASIS_ATTRIBUTES))
    values["pay_rate"] = normalized_pay_rate if pay_rate_changed
    insert_version!(employee.employee_compensation_changes, effective_on, values)
  end

  def record_wage_rate_version!(row, effective_on, changed, before)
    base = employee.wage_rate_version_for(row, effective_on)&.snapshot || before || row.attributes.slice(*WAGE_RATE_ATTRIBUTES)
    insert_version!(row.employee_wage_rate_versions, effective_on,
                    base.merge(changed).merge("company_id" => employee.company_id, "employee_id" => employee.id))
  end

  # Inserts a version into one timeline: the version covering the date ends
  # the day before, a later version keeps its start, and a version already
  # starting on the same date is replaced.
  def insert_version!(scope, effective_on, values)
    attributes = values.merge(
      "company_id" => employee.company_id,
      "reason" => reason.presence || default_reason,
      "source" => source,
      "historical_correction" => @historical_correction,
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
    PayPeriod.where(company_id: employee.company_id, status: %w[draft calculated], correction_status: nil)
      .where("start_date < :date AND end_date >= :date", date: effective_on)
      .order(:start_date).map do |period|
        "The #{period.start_date.iso8601} to #{period.end_date.iso8601} payroll is open and this change starts " \
          "mid-period on #{effective_on.iso8601}. That payroll uses the rate in effect on #{period.end_date.iso8601} " \
          "for every hour; split the hours or choose #{period.start_date.iso8601} if part of the period should use the earlier rate."
      end
  end

  def audit!(effective_on, previous, before_rates, warnings)
    after_rates = employee.employee_wage_rates.reload.to_h { |row| [ row.id, row.attributes.slice(*WAGE_RATE_ATTRIBUTES) ] }
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
        before: { pay_rate: previous&.pay_rate&.to_s("F"), wage_rates: printable_rates(before_rates) },
        after: { pay_rate: employee.compensation_on(effective_on)&.pay_rate&.to_s("F"), wage_rates: printable_rates(after_rates) },
        warnings: warnings
      }
    )
  end

  def printable_rates(rates)
    rates.values.map { |rate| rate.merge("rate" => rate["rate"]&.to_d&.to_s("F")) }
  end
end
