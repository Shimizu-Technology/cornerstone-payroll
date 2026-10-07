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

  # Saved PDFs retain the issuer name that was printed. Only a trusted,
  # transactional name-only rename may explain that one input difference.
  # Every candidate must still reproduce the entire sealed render digest.
  def self.matches_saved_record?(record, run:, company:, stored_digest:)
    return false if stored_digest.blank?
    return true if for_record(record, company: company, check_stock_type: run.check_stock_type) == stored_digest

    historical_issuer_names(run, company).any? do |name|
      historical_company = company.dup
      historical_company.id = company.id
      historical_company.name = name
      for_record(record, company: historical_company, check_stock_type: run.check_stock_type) == stored_digest
    end
  end

  def self.historical_issuer_names(run, company)
    return [] unless run.generated_at && run.company_id == company.id

    cache_key = [ company.name, company.updated_at, run.generated_at ]
    cache = run.instance_variable_get(:@historical_issuer_name_cache)
    return cache.last if cache&.first == cache_key

    current_name = company.name
    names = []
    logs = AuditLog.where(record_type: %w[Company companies], record_id: company.id,
      action: [ "company#name_changed", "companies#update" ])
      .where("created_at >= ?", run.generated_at).order(created_at: :desc, id: :desc)
    logs.each do |log|
      data = log.metadata
      # A generic or mixed name update cannot prove historical issuer identity.
      if log.action != "company#name_changed"
        break unless data["actual_changes"] == true && !Array(data["changed_fields"]).include?("name")
        next
      end
      break unless log.company_id == company.id && log.organization_id == company.organization_id &&
        data["actual_changes"] == true && data["name_only"] == true &&
        data["changed_fields"] == [ "name" ] &&
        data.dig("after_values", "name") == current_name

      old_name = data.dig("before_values", "name")
      break unless old_name.is_a?(String) && old_name.present?

      names << old_name
      current_name = old_name
    end
    run.instance_variable_set(:@historical_issuer_name_cache, [ cache_key, names.uniq ])
    names.uniq
  end
  private_class_method :historical_issuer_names

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
