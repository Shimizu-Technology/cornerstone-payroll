# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"
require "set"

module TimeTracking
  # Extends the privately reviewed AIRE rollout manifest with later, already
  # delivered payrolls. The caller supplies a read-only production export; this
  # class only builds a new manifest and never changes payroll or AIRE records.
  class VerifiedHistoryManifestExtension
    class Error < StandardError; end

    def initialize(manifest:, extension:)
      @manifest = JSON.parse(JSON.generate(manifest))
      @extension = extension
    end

    def call
      validate_structure!
      periods.each { |period| add_period!(period) }
      validate_global_uniqueness!
      manifest
    rescue KeyError, Date::Error, ArgumentError => e
      raise Error, "The AIRE rollout extension is incomplete: #{e.message}"
    end

    private

    attr_reader :manifest, :extension

    def periods
      extension.fetch("pay_periods")
    end

    def identities_by_uuid
      @identities_by_uuid ||= manifest.fetch("identity_links").each_with_object({}) do |row, index|
        index[normalize_uuid(row.fetch("source_user_uuid"))] = row
      end
    end

    def validate_structure!
      raise Error, "The AIRE rollout manifest version is unsupported" unless manifest["version"] == 1
      raise Error, "The AIRE rollout extension version is unsupported" unless extension["version"] == 1
      raise Error, "The AIRE rollout extension must contain pay periods" unless periods.is_a?(Array) && periods.any?

      %w[identity_links delivered_checks issued_entries classification_cases finalized_batch_entries].each do |key|
        raise Error, "The AIRE rollout manifest is missing #{key}" unless manifest[key].is_a?(Array)
      end
    end

    def add_period!(period)
      start_date = Date.iso8601(period.fetch("start_date"))
      end_date = Date.iso8601(period.fetch("end_date"))
      raise Error, "AIRE rollout period dates are reversed" if end_date < start_date

      delivery_date = Date.iso8601(period.fetch("delivered_on"))
      raise Error, "AIRE rollout delivery date precedes the pay period end" if delivery_date < end_date

      checks = period.fetch("checks")
      employees = period.fetch("aire_employees")
      raise Error, "AIRE rollout checks must be a list" unless checks.is_a?(Array)
      raise Error, "AIRE rollout employees must be a list" unless employees.is_a?(Array)

      check_by_employee = checks.each_with_object({}) do |row, index|
        index[integer(row.fetch("employee_id"))] = row
      end
      unless check_by_employee.length == checks.length
        raise Error, "AIRE rollout period contains duplicate employee checks"
      end

      checks.each do |row|
        add_check!(row, period.fetch("pay_period_id"), delivery_date)
      end

      employees_with_entries = employees.each_with_object(Set.new) do |employee, employee_ids|
        employee_id = add_employee_entries!(employee, check_by_employee:, start_date:, end_date:)
        raise Error, "AIRE rollout period contains duplicate employees" if employee_ids.include?(employee_id)

        employee_ids << employee_id
      end

      checks.each do |check|
        next unless hours(check.fetch("regular_hours")).positive? || hours(check.fetch("overtime_hours")).positive?
        next if check["employment_type"] == "salary"
        next if employees_with_entries.include?(integer(check.fetch("employee_id")))

        raise Error, "Payroll check #{check.fetch('payroll_item_id')} has hours but no matching AIRE source entries"
      end
    end

    def add_check!(row, pay_period_id, delivery_date)
      raise Error, "AIRE rollout check is not a positive paper check" unless row.fetch("payment_delivery_method") == "paper_check" && money(row.fetch("net_pay")).positive?
      raise Error, "AIRE rollout check number is missing" if row.fetch("check_number").to_s.strip.empty?

      check = {
        "payroll_item_id" => integer(row.fetch("payroll_item_id")),
        "pay_period_id" => integer(pay_period_id),
        "employee_id" => integer(row.fetch("employee_id")),
        "check_number" => row.fetch("check_number").to_s,
        "net_pay" => money_string(row.fetch("net_pay")),
        "regular_hours" => hours_string(row.fetch("regular_hours")),
        "overtime_hours" => hours_string(row.fetch("overtime_hours")),
        "delivered_on" => delivery_date.iso8601
      }

      existing = manifest.fetch("delivered_checks").find do |candidate|
        integer(candidate.fetch("payroll_item_id")) == check.fetch("payroll_item_id")
      end
      raise Error, "AIRE rollout check #{check.fetch('payroll_item_id')} conflicts with existing evidence" if existing && normalized_check(existing) != check
      manifest.fetch("delivered_checks") << check unless existing
    end

    def add_employee_entries!(employee, check_by_employee:, start_date:, end_date:)
      uuid = normalize_uuid(employee.fetch("source_user_uuid"))
      identity = identities_by_uuid[uuid]
      raise Error, "AIRE employee #{employee.fetch('display_name')} has no verified Cornerstone identity" unless identity
      unless squish(identity.fetch("employee_name")) == squish(employee.fetch("display_name"))
        raise Error, "AIRE employee #{employee.fetch('display_name')} changed since identity verification"
      end

      employee_id = integer(identity.fetch("employee_id"))
      check = check_by_employee[employee_id]
      raise Error, "AIRE employee #{employee.fetch('display_name')} has approved hours but no delivered check" unless check

      adjustments = employee.fetch("adjustments").select do |adjustment|
        work_date = Date.iso8601(adjustment.fetch("original_work_date"))
        work_date.between?(start_date, end_date)
      end
      raise Error, "AIRE employee #{employee.fetch('display_name')} has no current-period source entries" if adjustments.empty?

      regular = adjustments.sum { |row| hours(row.fetch("regular_hours")) }
      overtime = adjustments.sum { |row| hours(row.fetch("overtime_hours")) }
      payroll_regular = hours(check.fetch("regular_hours"))
      payroll_overtime = hours(check.fetch("overtime_hours"))
      unless regular + overtime == payroll_regular + payroll_overtime
        raise Error,
          "AIRE hours for #{employee.fetch('display_name')} do not match payroll " \
          "(AIRE #{hours_string(regular)} regular / #{hours_string(overtime)} OT; " \
          "Payroll #{hours_string(check.fetch('regular_hours'))} regular / #{hours_string(check.fetch('overtime_hours'))} OT)"
      end

      if regular == payroll_regular && overtime == payroll_overtime
        adjustments.each do |adjustment|
          add_entry!(adjustment, payroll_item_id: check.fetch("payroll_item_id"), source_user_uuid: uuid)
        end
      else
        add_classification_case!(adjustments, payroll_item_id: check.fetch("payroll_item_id"), source_user_uuid: uuid)
      end

      employee_id
    end

    def add_classification_case!(adjustments, payroll_item_id:, source_user_uuid:)
      source_entries = adjustments.map do |adjustment|
        {
          "source_time_entry_id" => adjustment.fetch("source_time_entry_id").to_s,
          "original_work_date" => Date.iso8601(adjustment.fetch("original_work_date")).iso8601,
          "regular_hours" => hours_string(adjustment.fetch("regular_hours")),
          "overtime_hours" => hours_string(adjustment.fetch("overtime_hours")),
          "category_name" => adjustment.dig("category", "name")
        }
      end.sort_by { |row| integer(row.fetch("source_time_entry_id")) }
      classification_case = {
        "payroll_item_id" => integer(payroll_item_id),
        "source_user_uuid" => source_user_uuid,
        "source_time_entry_ids" => source_entries.map { |row| row.fetch("source_time_entry_id") },
        "source_entries" => source_entries
      }

      existing = manifest.fetch("classification_cases").find do |candidate|
        integer(candidate.fetch("payroll_item_id")) == classification_case.fetch("payroll_item_id")
      end
      if existing && existing != classification_case
        raise Error, "AIRE classification case #{classification_case.fetch('payroll_item_id')} conflicts with existing evidence"
      end
      manifest.fetch("classification_cases") << classification_case unless existing
    end

    def add_entry!(adjustment, payroll_item_id:, source_user_uuid:)
      entry = {
        "payroll_item_id" => integer(payroll_item_id),
        "source_time_entry_id" => adjustment.fetch("source_time_entry_id").to_s,
        "source_user_uuid" => source_user_uuid,
        "original_work_date" => Date.iso8601(adjustment.fetch("original_work_date")).iso8601,
        "regular_hours" => hours_string(adjustment.fetch("regular_hours")),
        "overtime_hours" => hours_string(adjustment.fetch("overtime_hours")),
        "category_name" => adjustment.dig("category", "name")
      }

      existing = manifest.fetch("issued_entries").find do |candidate|
        candidate.fetch("source_time_entry_id").to_s == entry.fetch("source_time_entry_id")
      end
      raise Error, "AIRE source entry #{entry.fetch('source_time_entry_id')} conflicts with existing evidence" if existing && normalized_entry(existing) != entry
      manifest.fetch("issued_entries") << entry unless existing
    end

    def validate_global_uniqueness!
      checks = manifest.fetch("delivered_checks")
      entries = manifest.fetch("issued_entries")
      classification_entry_ids = manifest.fetch("classification_cases").flat_map do |row|
        row.fetch("source_time_entry_ids").map(&:to_s)
      end
      raise Error, "AIRE rollout payroll items are duplicated" unless unique?(checks.map { |row| integer(row.fetch("payroll_item_id")) })
      raise Error, "AIRE rollout source entries are duplicated" unless unique?(entries.map { |row| row.fetch("source_time_entry_id").to_s })
      raise Error, "AIRE rollout classification entries are duplicated" unless unique?(classification_entry_ids)

      manual_entry_ids = entries.map { |row| row.fetch("source_time_entry_id").to_s }
      finalized_entry_ids = manifest.fetch("finalized_batch_entries").map do |row|
        row.fetch("source_time_entry_id").to_s
      end
      overlap = (manual_entry_ids.to_set & classification_entry_ids.to_set) |
        (manual_entry_ids.to_set & finalized_entry_ids.to_set) |
        (classification_entry_ids.to_set & finalized_entry_ids.to_set)
      raise Error, "AIRE rollout source entries belong to multiple payment paths" if overlap.any?
    end

    def normalized_check(row)
      {
        "payroll_item_id" => integer(row.fetch("payroll_item_id")),
        "pay_period_id" => integer(row.fetch("pay_period_id")),
        "employee_id" => integer(row.fetch("employee_id")),
        "check_number" => row.fetch("check_number").to_s,
        "net_pay" => money_string(row.fetch("net_pay")),
        "regular_hours" => hours_string(row.fetch("regular_hours")),
        "overtime_hours" => hours_string(row.fetch("overtime_hours")),
        "delivered_on" => Date.iso8601(row.fetch("delivered_on")).iso8601
      }
    end

    def normalized_entry(row)
      {
        "payroll_item_id" => integer(row.fetch("payroll_item_id")),
        "source_time_entry_id" => row.fetch("source_time_entry_id").to_s,
        "source_user_uuid" => normalize_uuid(row.fetch("source_user_uuid")),
        "original_work_date" => Date.iso8601(row.fetch("original_work_date")).iso8601,
        "regular_hours" => hours_string(row.fetch("regular_hours")),
        "overtime_hours" => hours_string(row.fetch("overtime_hours")),
        "category_name" => row["category_name"]
      }
    end

    def normalize_uuid(value)
      value.to_s.strip.downcase.tap do |uuid|
        raise Error, "AIRE rollout employee UUID is missing" if uuid.empty?
      end
    end

    def unique?(values)
      values.uniq.length == values.length
    end

    def squish(value)
      value.to_s.strip.gsub(/\s+/, " ")
    end

    def integer(value)
      Integer(value.to_s, 10)
    end

    def hours(value)
      BigDecimal(value.to_s).round(2)
    end

    def money(value)
      BigDecimal(value.to_s).round(2)
    end

    def hours_string(value)
      format("%.2f", hours(value))
    end

    def money_string(value)
      format("%.2f", money(value))
    end
  end
end
