# frozen_string_literal: true

module PayrollImport
  # A retained source package freezes each preview row when it is created. Owner
  # pay and existing paycheck rows can change afterwards (staff enter a person's
  # pay while reviewing), and apply! reads the live values. This refreshes only
  # those fields so a reopened review matches what apply! will check.
  class LivePreviewRowState
    def initialize(pay_period)
      @pay_period = pay_period
    end

    def refresh(rows)
      rows = Array(rows)
      employee_ids = rows.filter_map { |row| row["employee_id"] }
      return rows if employee_ids.empty?

      items = @pay_period.payroll_items.where(employee_id: employee_ids).index_by(&:employee_id)
      rows.map { |row| refresh_row(row, items[row["employee_id"]]) }
    end

    private

    def refresh_row(row, item)
      row = row.merge("overwrite_required" => item.present? && item.import_source != "mosa_revel")
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

    # Pay entered by hand. Pay that an earlier workbook import wrote does not count.
    def manual_period_pay(item)
      return if item.blank? || item.salary_override.to_d <= 0

      evidence = item.custom_columns_data.to_h["period_pay_evidence"].to_h
      return if evidence["source_type"] == "mosa_change_workbook"

      item.salary_override.to_d
    end
  end
end
