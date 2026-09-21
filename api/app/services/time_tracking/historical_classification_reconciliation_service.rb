# frozen_string_literal: true

module TimeTracking
  # A one-time path for an already delivered historical check whose total paid
  # hours equal AIRE's exact source entries, but whose regular/OT split differs.
  # It never changes the check or creates a second payment. The wage difference
  # is retained for later review, not silently treated as a new payroll run.
  class HistoricalClassificationReconciliationService
    class Error < StandardError; end

    def initialize(pay_period:, source:, actor:)
      @pay_period = pay_period
      @source = source
      @actor = actor
    end

    def call(payroll_item_id:, source_user_uuid:)
      raise Error, "Commit the payroll before reconciling issued AIRE hours" unless pay_period.committed? && !pay_period.voided?
      raise Error, "Connect an active AIRE source first" unless source&.active? && source.company_id == pay_period.company_id

      item = pay_period.payroll_items.includes(:check_events).find(payroll_item_id)
      uuid = TimeTrackingEmployeeMapping.normalize_uuid(source_user_uuid)
      mapping = source.time_tracking_employee_mappings.find_by(source_user_uuid: uuid, employee_id: item.employee_id)
      raise Error, "Map this AIRE person to the payroll employee first" unless mapping

      reconciliation = TimeTrackingClassificationReconciliation.find_by(payroll_item: item)
      reconciliation ||= prepare!(item: item, uuid: uuid)
      validate_saved!(reconciliation, item: item, uuid: uuid)
      if reconciliation.status == "complete"
        verify_issued_coverage!(reconciliation)
        return reconciliation
      end

      allocation_service = TimeTracking::ManualAllocationService.new(pay_period: pay_period, source: source, actor: actor)
      Array(reconciliation.source_entries).each do |entry|
        existing = item.time_tracking_manual_allocations.find_by(
          time_tracking_source: source, source_time_entry_id: entry.fetch("source_time_entry_id")
        )
        if existing
          unless existing.classification_reconciliation_id == reconciliation.id &&
                 existing.regular_hours.to_d == decimal!(entry.fetch("regular_hours")) &&
                 existing.overtime_hours.to_d == decimal!(entry.fetch("overtime_hours")) &&
                 existing.status != "voided"
            raise Error, "A saved AIRE entry no longer matches this historical classification review"
          end
          allocation_service.sync!(existing, raise_on_failure: true)
          raise Error, "AIRE entry is not issued against the historical check" unless existing.reload.status == "issued"
          next
        end

        allocation = allocation_service.create!(
          payroll_item_id: item.id,
          source_time_entry_id: entry.fetch("source_time_entry_id"),
          source_time_entry_version: entry.fetch("source_time_entry_version"),
          source_user_uuid: uuid,
          regular_hours: entry.fetch("regular_hours"),
          overtime_hours: entry.fetch("overtime_hours"),
          original_work_date: entry.fetch("original_work_date"),
          note: reconciliation.note,
          classification_reconciliation: reconciliation
        )
        raise Error, "AIRE entry is not issued against the historical check; retry this reconciliation" unless allocation.status == "issued"
      end

      reconciliation.with_lock do
        verify_issued_coverage!(reconciliation)
        reconciliation.update!(status: "complete")
      end
      reconciliation
    rescue ActiveRecord::RecordNotFound
      raise Error, "Payroll item was not found in this pay period"
    end

    private

    attr_reader :pay_period, :source, :actor

    def verify_issued_coverage!(reconciliation)
      allocations = reconciliation.time_tracking_manual_allocations.where.not(status: "voided").to_a
      expected_ids = reconciliation.source_entries.map { |entry| entry.fetch("source_time_entry_id").to_s }.sort
      unless allocations.map(&:source_time_entry_id).sort == expected_ids && allocations.all? { |row| row.status == "issued" } &&
             allocations.sum(&:regular_hours).to_d == reconciliation.source_regular_hours &&
             allocations.sum(&:overtime_hours).to_d == reconciliation.source_overtime_hours
        raise Error, "Not every reviewed AIRE source entry has an issued allocation"
      end
    end

    def prepare!(item:, uuid:)
      raise Error, "A voided paycheck cannot establish paid AIRE hours" if item.voided?
      raise Error, "This paycheck already has exact AIRE allocations" if item.time_tracking_entry_allocations.exists? ||
                                                                item.time_tracking_manual_allocations.where.not(status: "voided").exists?
      raise Error, "Use a delivered paper check for historical classification reconciliation" unless
        item.effective_payment_delivery_method == "paper_check" && item.check_number.present? && item.net_pay.to_d.positive?
      delivery = item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
      raise Error, "Record the actual check-delivery evidence before marking AIRE hours paid" unless delivery&.effective_on

      review = TimeTracking::Client.for_payroll_actor(source, actor: actor).payroll_cockpit_manual_review(
        start_date: pay_period.start_date.iso8601,
        end_date: pay_period.end_date.iso8601,
        external_pay_period_id: pay_period.id
      )
      candidates = Array(review["employees"]).select do |row|
        TimeTrackingEmployeeMapping.normalize_uuid(row["source_user_uuid"]) == uuid
      end
      raise Error, "AIRE person is missing or duplicated in the manual hours review" unless candidates.one?
      entries = Array(candidates.first["adjustments"]).select do |entry|
        entry["source_kind"] == "current" && Date.iso8601(entry.fetch("original_work_date")).between?(pay_period.start_date, pay_period.end_date)
      end
      raise Error, "No current-period AIRE source entries were found for this check" if entries.empty?
      snapshots = entries.map { |entry| source_entry_snapshot!(entry) }.sort_by { |entry| entry.fetch("source_time_entry_id").to_i }
      raise Error, "AIRE returned duplicate source entries" unless snapshots.map { |entry| entry.fetch("source_time_entry_id") }.uniq.length == snapshots.length

      source_regular = snapshots.sum { |entry| decimal!(entry.fetch("regular_hours")) }
      source_overtime = snapshots.sum { |entry| decimal!(entry.fetch("overtime_hours")) }
      payroll_regular = item.hours_worked.to_d.round(2)
      payroll_overtime = item.overtime_hours.to_d.round(2)
      unless source_regular + source_overtime == payroll_regular + payroll_overtime &&
             (source_regular != payroll_regular || source_overtime != payroll_overtime)
        raise Error, "Only equal-total hours with a different regular/overtime split qualify for this historical path"
      end

      difference = wage_difference_for!(item, snapshots, source_regular, source_overtime,
                                        payroll_regular, payroll_overtime)
      note = "Historical AIRE/check classification difference for issued check #{item.check_number} delivered #{delivery.effective_on.iso8601}: " \
             "AIRE #{format('%.2f', source_regular)} regular / #{format('%.2f', source_overtime)} OT hours; " \
             "check #{format('%.2f', payroll_regular)} regular / #{format('%.2f', payroll_overtime)} OT hours. " \
             "Total hours match and are marked paid once; estimated gross wage difference #{format('%+.2f', difference)} is retained for later review, not automatically paid or deducted."
      TimeTrackingClassificationReconciliation.create!(
        company: pay_period.company, time_tracking_source: source, pay_period: pay_period,
        payroll_item: item, employee: item.employee, created_by: actor,
        source_user_uuid: uuid, source_entries: snapshots,
        source_regular_hours: source_regular, source_overtime_hours: source_overtime,
        payroll_regular_hours: payroll_regular, payroll_overtime_hours: payroll_overtime,
        gross_wage_difference: difference, check_number: item.check_number,
        payment_effective_on: delivery.effective_on, note: note
      )
    end

    def source_entry_snapshot!(entry)
      entry_id = entry.fetch("source_time_entry_id").to_s
      version = Integer(entry.fetch("source_time_entry_version").to_s, 10)
      work_date = Date.iso8601(entry.fetch("original_work_date"))
      regular = decimal!(entry.fetch("regular_hours"))
      overtime = decimal!(entry.fetch("overtime_hours"))
      total = decimal!(entry.fetch("total_hours"))
      unless entry_id.match?(/\A[1-9]\d*\z/) && version >= 0 &&
             work_date.between?(pay_period.start_date, pay_period.end_date) &&
             total.positive? && regular + overtime == total
        raise Error, "AIRE returned an invalid historical source entry"
      end
      {
        "source_time_entry_id" => entry_id,
        "source_time_entry_version" => version,
        "original_work_date" => work_date.iso8601,
        "regular_hours" => regular.to_s("F"),
        "overtime_hours" => overtime.to_s("F"),
        "category_name" => entry.dig("category", "name")
      }
    rescue ArgumentError, KeyError
      raise Error, "AIRE returned an invalid historical source entry"
    end

    def validate_saved!(reconciliation, item:, uuid:)
      delivery = item.check_events.deliveries.where(check_number: item.check_number).order(:id).last
      unless reconciliation.time_tracking_source_id == source.id && reconciliation.pay_period_id == pay_period.id &&
             reconciliation.employee_id == item.employee_id && reconciliation.source_user_uuid == uuid &&
             reconciliation.check_number == item.check_number && delivery&.effective_on == reconciliation.payment_effective_on &&
             item.hours_worked.to_d.round(2) == reconciliation.payroll_regular_hours &&
             item.overtime_hours.to_d.round(2) == reconciliation.payroll_overtime_hours && !item.voided?
        raise Error, "Saved historical classification evidence no longer matches the issued check"
      end
    end

    def wage_difference_for!(item, snapshots, source_regular, source_overtime, payroll_regular, payroll_overtime)
      lines = Array(item.wage_rate_hours).select do |line|
        decimal!(line.fetch("regular_hours")) + decimal!(line.fetch("overtime_hours")) > 0
      end
      if lines.empty?
        raise Error, "Review historical wage categories separately" unless item.employee.active_wage_rates.one?

        rate = item.pay_rate.to_d
        raise Error, "Review the saved check rate before historical reconciliation" unless rate.positive?
        check_wages = wage_amount(payroll_regular, payroll_overtime, rate)
        aire_wages = wage_amount(source_regular, source_overtime, rate)
      else
        check_by_label = lines.to_h { |line| [ normalized_wage_label(line.fetch("label")), line ] }
        raise Error, "Issued check has duplicate wage categories" unless check_by_label.length == lines.length
        source_by_label = Hash.new { |hash, key| hash[key] = [ 0.to_d, 0.to_d ] }
        uncategorized = []
        snapshots.each do |entry|
          label = normalized_wage_label(entry["category_name"])
          label = "flight hours" if label == "solo"
          label = "ground instruction hours" if label == "ground instruction"
          label = "maintenance" if label == "aircraft maintenance"
          if label.blank?
            uncategorized << entry
            next
          end
          raise Error, "AIRE wage category does not match this issued check" unless check_by_label.key?(label)

          source_by_label[label][0] += decimal!(entry.fetch("regular_hours"))
          source_by_label[label][1] += decimal!(entry.fetch("overtime_hours"))
        end
        residual = lines.to_h do |line|
          label = normalized_wage_label(line.fetch("label"))
          check_total = decimal!(line.fetch("regular_hours")) + decimal!(line.fetch("overtime_hours"))
          [ label, check_total - source_by_label[label].sum ]
        end
        raise Error, "AIRE wage category exceeds this issued check" if residual.values.any?(&:negative?)
        unknown_total = uncategorized.sum do |entry|
          decimal!(entry.fetch("regular_hours")) + decimal!(entry.fetch("overtime_hours"))
        end
        raise Error, "Uncategorized AIRE hours do not match the check's remaining wage hours" unless residual.values.sum == unknown_total

        uncategorized_wages = 0.to_d
        if uncategorized.any?
          remaining_labels = residual.select { |_label, hours| hours.positive? }.keys
          rates = remaining_labels.map { |label| BigDecimal(check_by_label.fetch(label).fetch("rate").to_s) }.uniq
          unless remaining_labels.one? || rates.one?
            raise Error, "Uncategorized AIRE hours span different check rates; review the wage category first"
          end
          rate = rates.sole
          uncategorized_wages = wage_amount(
            uncategorized.sum { |entry| decimal!(entry.fetch("regular_hours")) },
            uncategorized.sum { |entry| decimal!(entry.fetch("overtime_hours")) },
            rate
          )
        end
        lines.each do |line|
          label = normalized_wage_label(line.fetch("label"))
          if uncategorized.empty? && source_by_label[label].sum !=
             decimal!(line.fetch("regular_hours")) + decimal!(line.fetch("overtime_hours"))
            raise Error, "AIRE wage-category total hours do not match this issued check"
          end
        end
        check_wages = lines.sum do |line|
          wage_amount(decimal!(line.fetch("regular_hours")), decimal!(line.fetch("overtime_hours")),
                      BigDecimal(line.fetch("rate").to_s))
        end.round(2)
        aire_wages = lines.sum do |line|
          label = normalized_wage_label(line.fetch("label"))
          wage_amount(*source_by_label[label], BigDecimal(line.fetch("rate").to_s))
        end.round(2) + uncategorized_wages
      end

      gross = item.gross_pay.to_d.round(2)
      wage_net_of_additions = (gross - item.total_additions.to_d).round(2)
      unless check_wages == gross || check_wages == wage_net_of_additions
        raise Error, "The issued check has other wage differences; review it separately"
      end

      aire_wages - check_wages
    rescue ArgumentError, KeyError
      raise Error, "Historical wage-category details are invalid"
    end

    def normalized_wage_label(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def wage_amount(regular, overtime, rate)
      (regular * rate + overtime * rate * BigDecimal("1.5")).round(2)
    end

    def decimal!(value)
      hours = BigDecimal(value.to_s)
      raise Error, "AIRE returned invalid hours" if hours.negative? || hours.round(2) != hours

      hours
    rescue ArgumentError
      raise Error, "AIRE returned invalid hours"
    end
  end
end
