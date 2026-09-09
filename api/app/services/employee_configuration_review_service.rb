# frozen_string_literal: true

class EmployeeConfigurationReviewService
  class Error < StandardError; end
  class NotAuthorized < Error; end
  class InvalidResolution < Error; end

  ACKNOWLEDGEMENT = "MARK SETUP ITEM REVIEWED"
  SOURCE_REQUIRED_CODES = %w[
    verify_hire_date quickbooks_nevada_address_suppressed employee_address_missing
  ].freeze
  REVIEWABLE_EMPLOYEE_FIELDS = %w[
    hire_date address_line1 city state zip allowances w4_form_version
    employment_type salary_type pay_rate
  ].freeze

  def initialize(employee:, actor:)
    @employee = employee
    @actor = actor
  end

  def resolve!(code:, resolution_note:, acknowledgement:)
    authorize!
    raise InvalidResolution, "Type #{ACKNOWLEDGEMENT} to confirm" unless acknowledgement == ACKNOWLEDGEMENT

    note = resolution_note.to_s.squish
    raise InvalidResolution, "Document what was verified or corrected" if note.blank?
    raise InvalidResolution, "Resolution note is too long" if note.length > 1_000

    resolution = nil
    Employee.transaction do
      employee.lock!
      ensure_review_items_are_well_formed!
      item = current_items.find { |value| value.fetch("code") == code.to_s }
      existing = employee.employee_configuration_review_resolutions.find_by(item_code: code.to_s)
      return existing if item.nil? && existing
      raise InvalidResolution, "This setup review item is no longer open" unless item

      ensure_required_source_fields!(item)
      resolution = employee.employee_configuration_review_resolutions.create!(
        company: employee.company,
        item_code: item.fetch("code"),
        item_message: item.fetch("message"),
        item_fields: Array(item.fetch("fields")),
        resolution_note: note,
        reviewed_by: actor,
        reviewed_by_name: actor.name,
        reviewed_by_email: actor.email,
        reviewed_by_role: actor.role,
        reviewed_at: Time.current
      )
      remaining = current_items.reject { |value| value.fetch("code") == code.to_s }
      employee.update!(
        configuration_review_items: remaining,
        configuration_review_status: remaining.empty? ? "complete" : "needs_review"
      )
      audit!(resolution)
    end
    resolution
  end

  private

  attr_reader :employee, :actor

  def current_items
    Array(employee.configuration_review_items)
  end

  def ensure_review_items_are_well_formed!
    return if current_items.all? { |item| well_formed_review_item?(item) }

    raise InvalidResolution, "Employee setup review data is malformed; repair it before resolving items"
  end

  def well_formed_review_item?(item)
    item.is_a?(Hash) && item["code"].is_a?(String) && item["code"].present? &&
      item["message"].is_a?(String) && item["message"].present? &&
      item["fields"].is_a?(Array) && item["fields"].all? { |field| field.is_a?(String) }
  end

  def ensure_required_source_fields!(item)
    return unless SOURCE_REQUIRED_CODES.include?(item.fetch("code"))

    fields = Array(item.fetch("fields"))
    unsupported = fields - REVIEWABLE_EMPLOYEE_FIELDS
    if unsupported.any?
      raise InvalidResolution, "This setup review item contains unsupported employee fields"
    end

    missing = fields.reject { |field| employee.read_attribute(field).present? }
    return if missing.empty?

    raise InvalidResolution, "Enter the required employee values first: #{missing.map { |field| field.humanize }.join(', ')}"
  end

  def authorize!
    allowed = employee.configuration_source == "quickbooks_history" && actor&.payroll_access_allowed? &&
      actor.can_access_company?(employee.company_id) && StaffRolePolicy.allowed?(actor, :payroll_operations)
    raise NotAuthorized, "Cornerstone payroll access is required" unless allowed
  end

  def audit!(resolution)
    AuditLog.record!(
      user: actor,
      organization_id: employee.company.organization_id,
      company_id: employee.company_id,
      action: "employees#resolve_configuration_review",
      record_type: "employees",
      record_id: employee.id,
      subject_name: employee.full_name,
      metadata: {
        item_code: resolution.item_code,
        resolution_id: resolution.id,
        remaining_item_count: employee.configuration_review_items.size
      }
    )
  end
end
