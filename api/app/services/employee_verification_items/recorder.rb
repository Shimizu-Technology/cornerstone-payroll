# frozen_string_literal: true

module EmployeeVerificationItems
  # Creates, coalesces, and supersedes EmployeeVerificationItem records under
  # the canonical Company -> PayPeriod -> Employee lock order (§4.2, §4.3).
  #
  # Invariants:
  # - Every writer acquires Company.lock first so PayPeriodLifecycleService#commit!
  #   verification-acknowledgement snapshot checks remain race-safe.
  # - Items acknowledged in any committed pay run can NEVER be superseded;
  #   subsequent edits create a new pending_verification item whose before_values
  #   preserve the last-verified baseline and link metadata["prior_unverified_item_id"].
  # - Tax IDs (SSN / EIN) are always masked before persisting to JSONB.
  class Recorder
    IDENTIFIER_KEYS = %w[ssn ssn_encrypted contractor_ein].freeze
    NON_PAY_EVENT_KINDS = %w[profile_change].freeze

    def self.record!(...)
      new(...).record!
    end

    def self.requeue_returned_items!(employee:, actor:, touched_fields:)
      fields = Array(touched_fields).map(&:to_s).uniq
      return [] if fields.empty?

      ApplicationRecord.transaction do
        Company.lock.find(employee.company_id)
        returned_items = EmployeeVerificationItem
          .where(company_id: employee.company_id, employee_id: employee.id, status: "returned_to_client")
          .order(:id)
          .lock
          .to_a

        requeued = []
        returned_items.each do |item|
          next if item.acknowledged_in_committed_run?
          next unless item.event_kind == "new_hire" || (Array(item.changed_fields).map(&:to_s) & fields).any?

          item.update!(
            status: "pending_verification",
            resubmitted_at: Time.current,
            source_actor: actor
          )
          PortalNotifications.employee_verification_queued!(item)
          requeued << item
        end
        requeued
      end
    end

    def self.tax_filing_impact_for(employee)
      return nil unless employee&.persisted?

      committed_periods = PayPeriod
        .where(company_id: employee.company_id, status: "committed")
        .where("correction_status IS NULL OR correction_status <> ?", "voided")
        .joins(:payroll_items)
        .merge(PayrollItem.financially_reportable)
        .where(payroll_items: { employee_id: employee.id })
        .distinct
        .pluck(:pay_date)

      historical_years = employee.historical_employee_ytd_balances
        .joins(:historical_ytd_bridge)
        .where(historical_ytd_bridges: { status: "applied" })
        .distinct
        .pluck(:tax_year)

      years = (committed_periods.map(&:year) + historical_years).uniq.sort
      return nil if years.empty?

      committed_year_quarters = committed_periods.map { |date| [ date.year, ((date.month - 1) / 3) + 1 ] }.uniq

      filing_records = PayrollFilingRecord
        .where(company_id: employee.company_id, tax_year: years)
        .where.not(status: "rejected")
        .to_a

      filed_quarters = []
      filing_records.each do |record|
        if record.quarter.present?
          if committed_year_quarters.include?([ record.tax_year, record.quarter ]) || historical_years.include?(record.tax_year)
            filed_quarters << "#{record.tax_year}-Q#{record.quarter}"
          end
        else
          filed_quarters << "#{record.tax_year}-Annual"
        end
      end

      form_500_dates = Form500Filing
        .where(company_id: employee.company_id, status: %w[paid filed])
        .joins(:pay_period)
        .where(pay_periods: {
          id: PayPeriod
            .where(company_id: employee.company_id, status: "committed")
            .joins(:payroll_items)
            .merge(PayrollItem.financially_reportable)
            .where(payroll_items: { employee_id: employee.id })
            .select(:id)
        })
        .pluck("pay_periods.pay_date")

      form_500_dates.each do |date|
        filed_quarters << "#{date.year}-Q#{((date.month - 1) / 3) + 1}"
      end

      {
        "committed_tax_years" => years,
        "filed_quarters" => filed_quarters.uniq.sort,
        "w2c_or_941c_review_required" => true
      }
    end

    def self.sanitize_values(values)
      return {} unless values.is_a?(Hash)

      values.each_with_object({}) do |(key, value), acc|
        string_key = key.to_s
        acc[string_key] = if IDENTIFIER_KEYS.include?(string_key)
          mask_identifier(string_key, value)
        else
          serialize_value(value)
        end
      end
    end

    def self.mask_identifier(key, value)
      return nil if value.blank?
      digits = value.to_s.gsub(/\D/, "")
      return nil if digits.blank?
      return "***-**-#{digits.last(4)}" if %w[ssn ssn_encrypted].include?(key.to_s)

      "Ending in #{digits.last(4)}"
    end

    def self.serialize_value(value)
      case value
      when Hash
        sanitize_values(value)
      when Array
        value.map { |nested| serialize_value(nested) }
      when BigDecimal
        value.to_f
      when Date, Time, DateTime
        value.iso8601
      else
        value
      end
    end

    def initialize(employee:, actor:, event_kind:, changed_fields: [], before_values: {}, after_values: {},
                   effective_on: nil, source_record: nil, metadata: {}, affects_pay: nil)
      @employee = employee
      @actor = actor
      @event_kind = event_kind.to_s
      @changed_fields = Array(changed_fields).map(&:to_s).reject(&:blank?).uniq
      @before_values = self.class.sanitize_values(before_values)
      @after_values = self.class.sanitize_values(after_values)
      @effective_on = effective_on&.to_date
      @source_record = source_record
      @metadata = (metadata || {}).deep_stringify_keys
      @affects_pay = affects_pay.nil? ? !NON_PAY_EVENT_KINDS.include?(@event_kind) : affects_pay == true
    end

    def record!
      ApplicationRecord.transaction do
        Company.lock.find(employee.company_id)

        open_items = EmployeeVerificationItem
          .where(company_id: employee.company_id, employee_id: employee.id, event_kind: event_kind)
          .open_items
          .order(created_at: :desc, id: :desc)
          .lock
          .to_a

        if open_items.empty?
          create_item!(
            changed_fields: changed_fields,
            before_values: before_values,
            after_values: after_values,
            metadata: metadata
          )
        else
          latest = open_items.first
          oldest_before = open_items.reverse_each.with_object({}) do |item, values|
            values.merge!(item.before_values.to_h) { |_field, older, _newer| older }
          end
          merged_before = before_values.merge(oldest_before)

          if latest.acknowledged_in_committed_run?
            create_item!(
              changed_fields: changed_fields,
              before_values: merged_before,
              after_values: after_values,
              metadata: metadata.merge("prior_unverified_item_id" => latest.id)
            )
          elsif latest.status == "returned_to_client"
            latest.update!(
              status: "pending_verification",
              resubmitted_at: Time.current,
              source_actor: actor,
              source_record: source_record || latest.source_record,
              effective_on: effective_on || latest.effective_on,
              changed_fields: (Array(latest.changed_fields) + changed_fields).uniq,
              before_values: merged_before,
              after_values: latest.after_values.to_h.merge(after_values),
              metadata: latest.metadata.to_h.merge(metadata)
            )
            PortalNotifications.employee_verification_queued!(latest)
            latest
          else
            replacement = create_item!(
              changed_fields: (Array(latest.changed_fields) + changed_fields).uniq,
              before_values: merged_before,
              after_values: latest.after_values.to_h.merge(after_values),
              metadata: latest.metadata.to_h.merge(metadata).merge("prior_unverified_item_id" => latest.id)
            )
            latest.update!(status: "superseded", superseded_by: replacement)
            replacement
          end
        end
      end
    end

    private

    attr_reader :employee, :actor, :event_kind, :changed_fields, :before_values, :after_values,
                :effective_on, :source_record, :metadata, :affects_pay

    def create_item!(changed_fields:, before_values:, after_values:, metadata:)
      item = EmployeeVerificationItem.create!(
        company_id: employee.company_id,
        employee: employee,
        event_kind: event_kind,
        status: "pending_verification",
        affects_pay: affects_pay,
        effective_on: effective_on,
        source_actor: actor,
        source_record: source_record,
        changed_fields: changed_fields,
        before_values: before_values,
        after_values: after_values,
        metadata: metadata
      )
      PortalNotifications.employee_verification_queued!(item)
      item
    end
  end
end
