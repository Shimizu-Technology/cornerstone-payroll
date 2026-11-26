# frozen_string_literal: true

module PayrollImport
  # A retained source package freezes each preview row when it is created. Owner
  # pay and existing paycheck rows can change afterwards (staff enter a person's
  # pay while reviewing), and apply! reads the live values. This refreshes only
  # those fields so a reopened review matches what apply! will check.
  #
  # It also flags Revel hours that would replace hours staff changed by hand
  # after an earlier import, so the review can show old -> new and ask first.
  class LivePreviewRowState
    def initialize(pay_period)
      @pay_period = pay_period
    end

    def refresh(rows)
      rows = Array(rows)
      employee_ids = rows.filter_map { |row| row["employee_id"] }
      return rows if employee_ids.empty?

      items = @pay_period.payroll_items.where(employee_id: employee_ids).index_by(&:employee_id)
      applied_hours = self.class.applied_hours_by_employee(@pay_period)
      rows.map { |row| refresh_row(row, items[row["employee_id"]], applied_hours) }
    end

    private

    def refresh_row(row, item, applied_hours)
      row = row.merge(
        "overwrite_required" => ImportService.overwrite_required?(item, source_period_pay: row["period_pay"]),
        "hand_edited_hours" => self.class.hand_edited_hours(row, item, applied_hours: applied_hours)
      )
      return row unless row["period_pay_required"]

      source = positive_amount(row["period_pay"])
      manual = manual_period_pay(item)
      row.merge(
        "current_period_pay" => (source || manual)&.to_s("F"),
        "period_pay_source" => source ? "change_workbook" : (manual ? "payroll_worksheet" : nil),
        "period_pay_missing" => source.nil? && manual.nil?
      )
    end

    def positive_amount(value)
      amount = BigDecimal(value.to_s, exception: false)
      amount if amount&.positive?
    end

    def manual_period_pay(item)
      self.class.manual_period_pay(item)
    end

    # Saved hours that differ from what the last import left on the row, when
    # this import would replace them with different Revel hours.
    def self.hand_edited_hours(row, item, applied_hours: {})
      row = row.to_h.stringify_keys
      return if item.blank? || !item.intake_imported? || row["workbook_only"]

      imported = item.imported_hours_snapshot
      imported = applied_hours[item.employee_id] unless imported.is_a?(Hash)
      return unless imported.is_a?(Hash)

      saved = { "regular_hours" => item.hours_worked.to_d, "overtime_hours" => item.overtime_hours.to_d }
      edited = saved.any? { |key, value| value != imported[key].to_d }
      incoming = { "regular_hours" => row["regular_hours"].to_d, "overtime_hours" => row["overtime_hours"].to_d }
      return unless edited && incoming != saved

      {
        "employee_id" => item.employee_id,
        "employee_name" => row["employee_name"],
        "saved_regular_hours" => saved["regular_hours"].to_s("F"),
        "saved_overtime_hours" => saved["overtime_hours"].to_s("F"),
        "source_regular_hours" => incoming["regular_hours"].to_s("F"),
        "source_overtime_hours" => incoming["overtime_hours"].to_s("F")
      }
    end

    # Rows imported before the import recorded its hours fall back to the
    # Revel hours in the last applied import. A workbook-only row wrote no
    # hours, so any hours on it were entered by hand.
    def self.applied_hours_by_employee(pay_period)
      record = PayrollImportRecord.where(pay_period: pay_period, status: "applied").order(id: :desc).first
      Array(record&.matched_data).each_with_object({}) do |source, hours|
        source = source.to_h.stringify_keys
        next if source["employee_id"].blank?

        imported = source["workbook_only"] ? {} : source
        hours[source["employee_id"].to_i] = {
          "regular_hours" => imported["regular_hours"].to_d.to_s("F"),
          "overtime_hours" => imported["overtime_hours"].to_d.to_s("F")
        }
      end
    end

    # Pay entered by hand. Pay that an earlier workbook import wrote does not count.
    def self.manual_period_pay(item)
      return if item.blank? || item.salary_override.to_d <= 0

      evidence = item.custom_columns_data.to_h["period_pay_evidence"].to_h
      return if %w[mosa_change_workbook client_submission].include?(evidence["source_type"])

      item.salary_override.to_d
    end
  end
end
