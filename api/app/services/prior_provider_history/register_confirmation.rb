# frozen_string_literal: true

module PriorProviderHistory
  # Confirms every listed pay date against the previous provider's paid
  # registers in one attested step. It applies the same field-level rules as
  # Plan to each pay date and refuses the whole request, saving nothing, when
  # any date fails, so a failing date is never marked as matched. On success it
  # stores each date's register totals exactly as an individual match does and
  # records a server-owned attestation in the shared draft and the audit log.
  class RegisterConfirmation
    ACKNOWLEDGEMENT = "CONFIRM ALL PAY DATES MATCH THE PAID REGISTERS"
    ATTESTATIONS_KEY = "register_attestations"
    MAX_ATTESTATIONS = 50
    MISSING_KEY = "Is missing its pay date ID; remove this pay date and add it again"
    DUPLICATE_KEY = "Shares its pay date ID with another pay date; remove one and add it again"

    class Conflict < StandardError
      attr_reader :draft

      def initialize(message, draft = nil)
        super(message)
        @draft = draft
      end
    end

    class Refused < ArgumentError
      attr_reader :failures

      def initialize(failures)
        @failures = failures
        count = failures.size
        super("#{count} pay #{count == 1 ? 'date needs' : 'dates need'} individual review before confirming all")
      end
    end

    # Fills a blank reference the same way as the page's "Fill blank references".
    def self.filled_reference(register_name, pay_date)
      "#{register_name} — paid #{pay_date.presence || 'date'}"
    end

    # Canonical content of one confirmed pay date: its dates, reference, register
    # totals and every paycheck amount, so a later edit to any of them is visible.
    def self.period_fingerprint(period)
      Digest::SHA256.hexdigest(JSON.generate(QuickbooksHistory::CanonicalJson.normalize(period.except("calculated_totals"))))
    end

    # Each attestation, annotated with whether it still describes the recorded
    # pay dates. Attestations are never removed or rewritten as audit history.
    def self.with_recorded_match(attestations, recorded_periods)
      recorded = recorded_periods.to_h { |period| [ period.fetch("key").to_s, period_fingerprint(period) ] }
      Array(attestations).map do |attestation|
        fingerprints = attestation["period_fingerprints"]
        status = if !fingerprints.is_a?(Hash)
          "unverifiable_historical_record"
        elsif fingerprints == recorded.slice(*fingerprints.keys) && fingerprints.size == recorded.size
          "matches_recorded_periods"
        else
          "does_not_match_recorded_periods"
        end
        attestation.merge("recorded_period_match" => status)
      end
    end

    def self.money_string(value)
      whole, fraction = value.to_d.round(2).to_s("F").split(".")
      "#{whole}.#{(fraction || '').ljust(2, '0')}"
    end

    # The statement shown in the confirm dialog and stored with the attestation.
    def self.statement(summary)
      "I confirm these #{summary.fetch('period_count')} pay dates / #{summary.fetch('paycheck_count')} paychecks totaling " \
        "$#{ActiveSupport::NumberHelper.number_to_delimited(summary.fetch('gross_pay'))} gross / " \
        "$#{ActiveSupport::NumberHelper.number_to_delimited(summary.fetch('net_pay'))} net match the previous provider’s paid registers."
    end

    def initialize(company:, actor:, payload:, lock_version:, step:, register_name:, acknowledgement:, expected:)
      @company, @actor = company, actor
      raise ArgumentError, "History payload must be an object" unless payload.is_a?(Hash)

      @payload = payload.deep_stringify_keys
      @lock_version, @step = lock_version, step
      @register_name = register_name.to_s.strip
      @acknowledgement = acknowledgement
      @expected = expected.to_h.stringify_keys
    end

    def call
      Authorization.ensure_authorized!(actor: actor, company_id: company.id)
      raise ArgumentError, "Tick the confirmation and confirm every pay date at once" unless acknowledgement == ACKNOWLEDGEMENT
      raise ArgumentError, "Register name must be at most 200 characters" if register_name.length > 200

      PriorProviderHistoryDraft.transaction do
        company.lock!
        @actor = Authorization.ensure_authorized!(actor: actor, company_id: company.id, lock: true)
        draft = PriorProviderHistoryDraft.lock.find_or_initialize_by(company_id: company.id)
        raise Conflict, "The saved draft was removed. Reload before starting again." if draft.new_record? && lock_version.present?
        if draft.persisted? && lock_version.to_s != draft.lock_version.to_s
          raise Conflict.new("#{draft.updated_by.name} saved newer changes. Reload to continue from their version.", draft)
        end

        periods = confirmed_periods!
        summary = summary_for(periods)
        unless summary.slice("period_count", "paycheck_count", "gross_pay", "net_pay") == expected_summary
          raise ArgumentError, "The pay dates or totals changed after you reviewed them. Check the new totals and confirm again."
        end

        attestation = summary.merge(
          "statement" => self.class.statement(summary), "acknowledgement" => acknowledgement,
          "actor_id" => actor.id, "actor_name" => actor.name, "attested_at" => Time.current.utc.iso8601,
          "register_name" => register_name.presence, "period_keys" => periods.map { |period| period.fetch("key").to_s },
          "period_fingerprints" => periods.to_h { |period| [ period.fetch("key").to_s, self.class.period_fingerprint(period) ] }
        )
        prior = Array(draft.persisted? ? draft.payload[ATTESTATIONS_KEY] : nil)
        raise ArgumentError, "Too many confirmations on this draft; discard it and start again" if prior.size >= MAX_ATTESTATIONS

        draft.update!(payload: payload.merge("periods" => periods, ATTESTATIONS_KEY => prior + [ attestation ]),
          step: step.to_i.clamp(0, 3), updated_by: actor)
        AuditLog.record!(user: actor, organization_id: company.organization_id, company_id: company.id,
          action: "prior_provider_histories#confirm_registers", record_type: "prior_provider_history_drafts", record_id: draft.id,
          subject_name: company.name, metadata: attestation.except("actor_name"))
        draft
      end
    end

    private

    attr_reader :company, :actor, :payload, :lock_version, :step, :register_name, :acknowledgement, :expected

    def expected_summary
      {
        "period_count" => Integer(expected.fetch("period_count").to_s, 10),
        "paycheck_count" => Integer(expected.fetch("paycheck_count").to_s, 10),
        "gross_pay" => self.class.money_string(total_amount(expected.fetch("gross_pay"), "gross")),
        "net_pay" => self.class.money_string(total_amount(expected.fetch("net_pay"), "net"))
      }
    rescue KeyError, TypeError
      raise ArgumentError, "Confirm the pay date count, paycheck count and gross and net totals shown"
    end

    # Aggregates may exceed the per-amount digit limit (up to 3,000 paychecks).
    def total_amount(value, label)
      string = value.to_s
      raise ArgumentError, "The confirmed #{label} total must be an amount like 1234.56" unless string.match?(/\A\d{1,14}(?:\.\d{1,2})?\z/)

      BigDecimal(string)
    end

    def tax_year = Integer(payload.fetch("tax_year").to_s, 10)
    def takeover_on = Date.iso8601(payload.fetch("takeover_on").to_s)

    def confirmed_periods!
      periods = payload["periods"]
      unless periods.is_a?(Array) && periods.size.in?(1..SourceAdapter::MAX_RUNS) && periods.all? { |row| row.is_a?(Hash) }
        raise ArgumentError, "Supply 1–#{SourceAdapter::MAX_RUNS} pay dates to confirm"
      end
      raise ArgumentError, "Too many paychecks" if periods.sum { |row| Array(row["paychecks"]).size } > SourceAdapter::MAX_PAYCHECKS

      year, takeover = begin
        [ tax_year, takeover_on ]
      rescue ArgumentError, KeyError, Date::Error
        raise ArgumentError, "Choose a takeover date in the tax year before confirming pay dates"
      end
      ids = periods.flat_map { |row| Array(row["paychecks"]).map { |check| check.is_a?(Hash) ? check["employee_id"].to_s.to_i : 0 } }
      employees = company.employees.where(id: ids.select(&:positive?)).index_by(&:id)
      failures = []
      key_counts = periods.map { |period| period["key"].to_s.strip }.tally
      confirmed = periods.map do |period|
        filled = period.merge("source_reference" => reference_for(period))
        # The key identifies the date in the attestation and its fingerprint.
        key = period["key"].to_s.strip
        reasons = []
        reasons << MISSING_KEY if key.empty? || key.length > 200
        reasons << DUPLICATE_KEY if reasons.empty? && key_counts[key] > 1
        reasons += period_problems(filled, year, takeover, employees)
        next failures << { "key" => period["key"].to_s, "pay_date" => period["pay_date"].to_s, "reasons" => reasons } if reasons.any?

        filled.merge("register_totals" => register_totals(filled))
      end
      raise Refused, failures if failures.any?

      confirmed
    end

    def reference_for(period)
      current = period["source_reference"].to_s
      return current if current.strip.present? || register_name.blank?

      self.class.filled_reference(register_name, period["pay_date"].to_s)
    end

    # Field-level problems only; roster/run eligibility stays in Plan at record time.
    def period_problems(period, year, takeover, employees)
      reasons = []
      reasons.concat(date_problems(period, year, takeover))
      reference = period["source_reference"].to_s
      reasons << "Needs a register reference (enter the register name above to fill it)" if reference.strip.blank?
      reasons << "Register reference is longer than 500 characters" if reference.length > 500
      rows = period["paychecks"]
      return reasons << "Has no paychecks" unless rows.is_a?(Array) && rows.any?

      rows.each do |row|
        name = paycheck_name(row, employees)
        unless row.is_a?(Hash)
          reasons << "#{name}: paycheck is not readable"
          next
        end
        reasons << "#{name}: check # / payment reference is longer than 255 characters" if row["provider_payment_reference"].to_s.length > 255
        begin
          Amounts.validate!(row)
        rescue ArgumentError => error
          reasons << "#{name}: #{error.message}"
        end
      end
      reasons.concat(register_problems(period)) if reasons.empty?
      reasons
    end

    def date_problems(period, year, takeover)
      start_date, end_date, pay_date = %w[start_date end_date pay_date].map { |key| Date.iso8601(period[key].to_s) }
      problems = []
      problems << "Period dates are out of order (start, end, then pay date)" unless start_date <= end_date && end_date <= pay_date
      problems << "Pay date is not in the past" unless pay_date < PayrollBusinessClock.today
      problems << "Pay date is not in #{year} before the takeover date" unless pay_date.year == year && pay_date < takeover
      problems
    rescue Date::Error, TypeError
      [ "Needs real start, end and pay dates" ]
    end

    # Entered register totals must already agree; blank ones take the paycheck
    # totals, exactly as "Matches the register" does for a single pay date.
    def register_problems(period)
      entered = period["register_totals"]
      return [] if entered.nil?
      return [ "Register totals are not readable" ] unless entered.is_a?(Hash)

      totals = Amounts.totals(period.fetch("paychecks"))
      Amounts::REGISTER_FIELDS.filter_map do |field|
        value = entered[field]
        next if value.nil? || value.to_s.strip.empty?
        next "Register #{field.humanize.downcase} is not a valid amount" unless value.to_s.match?(/\A\d{1,10}(?:\.\d{1,2})?\z/)
        next if BigDecimal(value.to_s) == totals.fetch(field).to_d

        "Doesn't match the register #{field.humanize.downcase} (register #{value}, paychecks #{self.class.money_string(totals.fetch(field))})"
      end
    end

    # Called only for dates whose paychecks already passed Amounts.validate!.
    def register_totals(period)
      totals = Amounts.totals(period.fetch("paychecks"))
      Amounts::REGISTER_FIELDS.to_h { |field| [ field, self.class.money_string(totals.fetch(field)) ] }
    end

    def summary_for(periods)
      checks = periods.flat_map { |period| period.fetch("paychecks") }
      totals = Amounts.totals(checks)
      {
        "period_count" => periods.size, "paycheck_count" => checks.size,
        "gross_pay" => self.class.money_string(totals.fetch("gross_pay")), "net_pay" => self.class.money_string(totals.fetch("net_pay"))
      }
    end

    def paycheck_name(row, employees)
      return "A paycheck" unless row.is_a?(Hash)

      employee = employees[row["employee_id"].to_s.to_i]
      row["source_employee_name"].to_s.strip.presence || employee&.full_name || "Employee #{row['employee_id']}"
    end
  end
end
