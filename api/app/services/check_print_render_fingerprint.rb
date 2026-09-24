# frozen_string_literal: true

require "digest"

class CheckPrintRenderFingerprint
  def self.for_payload(payload)
    Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload)))
  end

  def self.for_record(record, company:, check_stock_type:)
    payload = if check_stock_type == "first_hawaiian_4up"
      generator = if record.is_a?(PayrollItem)
        FirstHawaiianFourUpCheckGenerator.new(company: company, payroll_items: [ record ])
      else
        FirstHawaiianFourUpCheckGenerator.new(company: company, non_employee_checks: [ record ])
      end
      key = record.is_a?(PayrollItem) ? "payroll_item:#{record.id}" : "non_employee_check:#{record.id}"
      generator.render_input_payloads.fetch(key)
    elsif record.is_a?(PayrollItem)
      CheckGenerator.new(record, company: company).render_input_payload
    else
      NonEmployeeCheckGenerator.new(record, company: company).render_input_payload
    end

    for_payload(payload)
  end

  def self.deep_sort(value)
    case value
    when Hash
      value.keys.sort_by(&:to_s).each_with_object({}) do |key, result|
        result[key.to_s] = deep_sort(value.fetch(key))
      end
    when Array
      value.map { |entry| deep_sort(entry) }
    when BigDecimal
      value.to_s("F")
    when Date, Time, DateTime, ActiveSupport::TimeWithZone
      value.iso8601
    when Symbol
      value.to_s
    else
      value
    end
  end
  private_class_method :deep_sort
end
