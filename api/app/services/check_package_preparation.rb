# frozen_string_literal: true

# Checks that the current check still matches at least one saved, prepared PDF.
# A source timestamp alone misses changes to employee or company details shown
# on the check, so issuance and payment also compare the rendered input digest.
class CheckPackagePreparation
  def self.current_for?(source)
    new(source).current?
  end

  def self.current_run?(run, current_records)
    return false unless run.pay_period.committed?

    run.manifest.all? do |entry|
      next false unless %w[payroll_item non_employee_check].include?(entry["source_type"])

      records = entry["source_type"] == "payroll_item" ? current_records.first : current_records.last
      source = records[entry["source_id"]]
      source && !source.voided? && source.company_id == run.company_id &&
        source.pay_period_id == run.pay_period_id &&
        new(source).matches?(run, entry, require_source_timestamp: false)
    end
  end

  def initialize(source)
    @source = source
  end

  def current?
    return false unless source.pay_period&.committed?

    key = source.is_a?(PayrollItem) ? "payroll_item:#{source.id}" : "non_employee_check:#{source.id}"
    runs = CheckPrintRun.where(pay_period_id: source.pay_period_id, company_id: source.company_id, status: "prepared")
      .order(generated_at: :desc, id: :desc)

    runs.any? do |run|
      entry = run.manifest.find { |candidate| candidate["key"] == key }
      entry && matches?(run, entry, require_source_timestamp: true)
    end
  rescue KeyError, ArgumentError
    false
  end

  def matches?(run, entry, require_source_timestamp:)
    return false unless entry["check_number"] == source.check_number.to_s
    return false if require_source_timestamp && entry["source_updated_at"] != source.updated_at.iso8601(6)
    return false if entry["amount"].blank? || entry["amount"].to_d != amount

    snapshot = run.calibration_snapshot
    render_company = CheckRenderSettings.new(
      check_stock_type: run.check_stock_type,
      check_offset_x: snapshot.fetch("check_offset_x"),
      check_offset_y: snapshot.fetch("check_offset_y"),
      check_layout_config: snapshot.fetch("check_layout_config"),
      printer_profile: nil
    ).apply_to(run.company)
    CheckPrintRenderFingerprint.for_record(
      source,
      company: render_company,
      check_stock_type: run.check_stock_type
    ) == entry["render_input_digest"]
  rescue KeyError, ArgumentError
    false
  end

  private

  attr_reader :source

  def amount
    source.is_a?(PayrollItem) ? source.net_pay.to_d : source.amount.to_d
  end
end
