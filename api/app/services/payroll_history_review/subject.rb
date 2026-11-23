# frozen_string_literal: true

module PayrollHistoryReview
  class Subject
    ID_COLUMNS = {
      "voided_pay_period" => :pay_period_id,
      "reversed_payroll_item" => :payroll_item_id,
      "legacy_disposition" => :payroll_item_id,
      "legacy_basis_gap" => :employee_id,
      "imported_history" => :historical_import_batch_id
    }.freeze
    PERIOD_FIELDS = %w[id start_date end_date pay_date status correction_status voided_at void_reason
      voided_by_id corrects_pay_period_id source_pay_period_id superseded_by_id].freeze
    ITEM_FIELDS = %w[id gross_pay social_security_tax employer_social_security_tax
      medicare_tax employer_medicare_tax additional_medicare_tax].freeze

    attr_reader :type, :id, :employee_id

    def initialize(type, id, rows, employee_id: nil, fica_ids: nil, w2_ids: nil)
      @type, @id, @rows, @employee_id = type, id, rows, employee_id
      @fica_ids, @w2_ids = fica_ids, w2_ids
    end

    def key
      [ type, id ]
    end

    def self.key_for(item)
      [ item.subject_type, item.public_send(ID_COLUMNS.fetch(item.subject_type)) ]
    end

    def identity
      { subject_type: type, ID_COLUMNS.fetch(type) => id }
    end

    def note_reasons
      case type
      when "voided_pay_period" then [ "voided pay period ##{id}" ]
      when "reversed_payroll_item" then [ "reversed paycheck ##{id}" ]
      when "legacy_disposition" then [ "unresolved legacy disposition for paycheck ##{id}" ]
      when "legacy_basis_gap" then @rows.filter_map { |row| "legacy paycheck ##{row.id} has no verified FICA bases" if @fica_ids.include?(row.id) }
      when "imported_history" then [ "imported paycheck history (batch ##{id})" ]
      end
    end

    def facts
      @facts ||= case type
      when "voided_pay_period" then void_facts(@rows.first)
      when "legacy_basis_gap"
        employee_facts.merge("paychecks" => @rows.map { |row| paycheck(row).merge(
          "missing_bases" => (YearEnd::W2PayrollItems::TAX_BASE_FIELDS + %w[additional_medicare_taxable_wages]).select { |field| row[field].nil? }) })
      when "imported_history"
        { "batch_id" => id, "paychecks" => @rows.map { |row| row.attributes.slice(*ITEM_FIELDS, "pay_date") } }
      else
        employee_facts.merge("paychecks" => [ paycheck(@rows.first) ],
          "reason" => type == "reversed_payroll_item" ? @rows.first.payroll_reversal_reason : @rows.first.legacy_disposition&.reason)
      end
    end

    def digest
      @digest ||= FicaBasisEvidence.digest([ key, employee_id, evidence ])
    end

    private

    def evidence
      case type
      when "voided_pay_period"
        period = @rows.first
        [ facts, period.payroll_items.map { |row| native_evidence(row) }.sort_by(&:first),
          period.payroll_items.sort_by(&:id).map { |row| payment_evidence(row) } ]
      when "legacy_basis_gap"
        @rows.map do |row|
          [ native_evidence(row), row.fit_taxable_wages, @fica_ids.include?(row.id),
            (W2GuTaxableWages.for_item(row) if @w2_ids.include?(row.id)) ]
        end
      when "imported_history"
        @rows.map { |row| [ ImportedPaycheckFicaEvidence.source(row), row.fica_basis_proof&.evidence ] }
      else
        @rows.map { |row| native_evidence(row) }
      end
    end

    def native_evidence(row)
      [ row.id, FicaBasisEvidence.row_digest(row), row.pay_period.attributes.slice(*PERIOD_FIELDS),
        row.attributes.slice("employment_type", "voided", "voided_at", "void_reason", "payroll_reversed_at",
          "payroll_reversed_by_id", "payroll_reversal_reason", "financial_correction_origin_item_id"),
        row.legacy_disposition&.attributes&.except("updated_at") ]
    end

    def employee_facts
      { "employee_id" => employee_id, "employee_name" => @rows.first.employee.full_name }
    end

    def paycheck(row)
      row.attributes.slice(*ITEM_FIELDS).merge("pay_date" => row.pay_period.pay_date)
    end

    def void_facts(period)
      items = period.payroll_items
      payments = items.map { |row| payment_evidence(row) }
      period_summary(period).merge(
        "checks_printed" => payments.count { |payment| payment.fetch(:printed_at) },
        "checks_delivered_or_cleared" => payments.count { |payment| payment.fetch(:check_events).any? || payment.fetch(:clearing_events).any? },
        "direct_deposits_confirmed" => payments.count { |payment| payment.fetch(:deposit) },
        "replacements" => replacements(period).map { |replacement| period_summary(replacement) })
    end

    def payment_evidence(row)
      { printed_at: row.check_printed_at, check_number: row.check_number, method: row.payment_delivery_method,
        check_events: row.check_events.select { |event| event.event_type == "delivered" }.sort_by(&:id).map(&:id),
        clearing_events: row.check_reconciliation_events.select { |event| event.event_type == "cleared" }.sort_by(&:id).map(&:id),
        deposit: row.direct_deposit_payment_confirmation&.attributes&.slice("id", "settled_on") }
    end

    def period_summary(period)
      period.attributes.slice(*PERIOD_FIELDS).merge("item_count" => period.payroll_items.size,
        "gross_pay" => period.payroll_items.sum { |row| row.gross_pay.to_d })
    end

    def replacements(period)
      runs = PayPeriod.where(company_id: period.company_id)
      linked = runs.where(corrects_pay_period_id: period.id).or(runs.where(source_pay_period_id: period.id))
        .or(runs.where(id: period.superseded_by_id))
      same_dates = runs.where(status: "committed", start_date: period.start_date, end_date: period.end_date, pay_date: period.pay_date)
      linked.or(same_dates).where.not(id: period.id).where("correction_status IS DISTINCT FROM 'voided'")
        .includes(:payroll_items).order(:id)
    end
  end
end
