# frozen_string_literal: true

require "digest"

# Immutable calibration inputs for one rendering operation. Company owns the
# client's stock choice and business copy; printer profiles own alignment.
class CheckRenderSettings
  MissingProfileError = Class.new(ArgumentError)
  IncompatibleProfileError = Class.new(ArgumentError)
  StaleProfileError = Class.new(ArgumentError)

  attr_reader :check_stock_type, :check_offset_x, :check_offset_y,
    :check_layout_config, :printer_profile

  def self.resolve(company:, actor:, printer_profile_id: nil, printer_profile_lock_version: nil,
                   require_profile: false, lock_profile: false)
    profile = requested_or_selected_profile(
      company: company,
      actor: actor,
      printer_profile_id: printer_profile_id,
      lock_profile: lock_profile
    )

    if profile
      validate_profile!(
        profile: profile,
        company: company,
        expected_lock_version: printer_profile_lock_version
      )
      return new(
        check_stock_type: company.check_stock_type,
        check_offset_x: profile.check_offset_x,
        check_offset_y: profile.check_offset_y,
        check_layout_config: profile.check_layout_config,
        printer_profile: profile
      )
    end

    if require_profile
      raise MissingProfileError,
        "Choose a printer profile for #{company.check_stock_type.humanize} before generating checks"
    end

    new(
      check_stock_type: company.check_stock_type,
      check_offset_x: company.check_offset_x,
      check_offset_y: company.check_offset_y,
      check_layout_config: company.check_layout_config,
      printer_profile: nil
    )
  end

  def self.requested_or_selected_profile(company:, actor:, printer_profile_id:, lock_profile:)
    relation = PrinterProfile.active.where(organization_id: company.organization_id)
    relation = relation.lock if lock_profile
    return relation.find_by(id: printer_profile_id) if printer_profile_id.present?

    selection = UserPrinterProfileSelection.find_by(
      user_id: actor.id,
      organization_id: company.organization_id,
      check_stock_type: company.check_stock_type
    )
    return unless selection

    relation.find_by(id: selection.printer_profile_id)
  end
  private_class_method :requested_or_selected_profile

  def self.validate_profile!(profile:, company:, expected_lock_version:)
    unless profile.organization_id == company.organization_id
      raise IncompatibleProfileError, "Printer profile is not available in this organization"
    end
    unless profile.check_stock_type == company.check_stock_type
      raise IncompatibleProfileError,
        "#{profile.name} is calibrated for #{profile.check_stock_type.humanize}, not #{company.check_stock_type.humanize}"
    end
    return if expected_lock_version.blank? || profile.lock_version == expected_lock_version.to_i

    raise StaleProfileError,
      "#{profile.name} changed after you opened the print screen. Review the updated calibration before generating checks."
  end
  private_class_method :validate_profile!

  def initialize(check_stock_type:, check_offset_x:, check_offset_y:, check_layout_config:, printer_profile:)
    @check_stock_type = check_stock_type
    @check_offset_x = check_offset_x.to_d
    @check_offset_y = check_offset_y.to_d
    @check_layout_config = JSON.parse((check_layout_config || {}).to_json).freeze
    @printer_profile = printer_profile
    freeze
  end

  def profile?
    printer_profile.present?
  end

  def apply_to(company)
    company.dup.tap do |render_company|
      render_company.id = company.id
      render_company.check_stock_type = check_stock_type
      render_company.check_offset_x = check_offset_x
      render_company.check_offset_y = check_offset_y
      render_company.check_layout_config = JSON.parse(check_layout_config.to_json)
    end
  end

  def snapshot
    {
      "source" => profile? ? "printer_profile" : "legacy_company_calibration",
      "printer_profile_id" => printer_profile&.id,
      "printer_profile_name" => printer_profile&.name,
      "printer_profile_lock_version" => printer_profile&.lock_version,
      "printer_profile_updated_at" => printer_profile&.updated_at&.iso8601(6),
      "check_stock_type" => check_stock_type,
      "check_offset_x" => check_offset_x.to_s("F"),
      "check_offset_y" => check_offset_y.to_s("F"),
      "check_layout_config" => JSON.parse(check_layout_config.to_json),
      "calibration_digest" => calibration_digest
    }.compact
  end

  def calibration_digest
    Digest::SHA256.hexdigest(
      JSON.generate(
        "check_stock_type" => check_stock_type,
        "check_offset_x" => check_offset_x.to_s("F"),
        "check_offset_y" => check_offset_y.to_s("F"),
        "check_layout_config" => deep_sort(check_layout_config)
      )
    )
  end

  private

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = deep_sort(value.fetch(key)) }
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end
end
