# frozen_string_literal: true

module EmployeeContactHygiene
  class PlaceholderEmailService
    class Error < StandardError; end
    class Forbidden < Error; end

    Result = Struct.new(:email, :reason, :marked, :changed, :record, keyword_init: true)

    def initialize(organization:, email:, actor:, reason: nil, company: nil, ip_address: nil, user_agent: nil, request_id: nil)
      @organization = organization
      @raw_email = email
      @actor = actor
      @reason = reason.to_s.strip.presence
      @company = company
      @ip_address = ip_address
      @user_agent = user_agent
      @request_id = request_id
    end

    def mark!
      authorize!
      normalized_email = EmployeeContactValidator.normalize_email(@raw_email)
      raise Error, "Email address is required" if normalized_email.blank?
      unless normalized_email.match?(URI::MailTo::EMAIL_REGEXP) && normalized_email.match?(EmployeeContactValidator::EMAIL_FORMAT_PATTERN)
        raise Error, "Must be a valid email address"
      end
      if @reason && @reason.length > EmployeePlaceholderEmail::MAX_REASON_LENGTH
        raise Error, "Reason must be #{EmployeePlaceholderEmail::MAX_REASON_LENGTH} characters or fewer"
      end

      record = nil
      changed = false

      EmployeePlaceholderEmail.transaction(requires_new: true) do
        existing = EmployeePlaceholderEmail.lock.find_by(organization_id: @organization.id, email: normalized_email)
        if existing
          record = existing
        else
          record = EmployeePlaceholderEmail.create!(
            organization: @organization,
            email: normalized_email,
            reason: @reason,
            marked_by: @actor
          )
          changed = true

          AuditLog.record!(
            user: @actor,
            organization_id: @organization.id,
            company_id: nil,
            action: "employee_contact_hygiene#mark_placeholder_email",
            record_type: "employee_placeholder_emails",
            record_id: record.id,
            subject_name: normalized_email,
            metadata: {
              email: normalized_email,
              reason: @reason
            }.compact,
            ip_address: @ip_address,
            user_agent: @user_agent,
            request_id: @request_id
          )
        end
      end

      Result.new(email: normalized_email, reason: record.reason, marked: true, changed: changed, record: record)
    rescue ActiveRecord::RecordNotUnique
      already_marked(normalized_email)
    rescue ActiveRecord::RecordInvalid => e
      # A concurrent mark can commit between the lookup and the uniqueness check.
      raise unless e.record.is_a?(EmployeePlaceholderEmail) && e.record.errors.of_kind?(:email, :taken)

      already_marked(normalized_email)
    end

    def unmark!
      authorize!
      normalized_email = EmployeeContactValidator.normalize_email(@raw_email)
      raise Error, "Email address is required" if normalized_email.blank?

      changed = false
      EmployeePlaceholderEmail.transaction do
        existing = EmployeePlaceholderEmail.lock.find_by(organization_id: @organization.id, email: normalized_email)
        if existing
          record_id = existing.id
          existing.destroy!
          changed = true

          AuditLog.record!(
            user: @actor,
            organization_id: @organization.id,
            company_id: nil,
            action: "employee_contact_hygiene#unmark_placeholder_email",
            record_type: "employee_placeholder_emails",
            record_id: record_id,
            subject_name: normalized_email,
            metadata: { email: normalized_email },
            ip_address: @ip_address,
            user_agent: @user_agent,
            request_id: @request_id
          )
        end
      end

      Result.new(email: normalized_email, reason: nil, marked: false, changed: changed, record: nil)
    end

    private

    def already_marked(normalized_email)
      existing = EmployeePlaceholderEmail.find_by!(organization_id: @organization.id, email: normalized_email)
      Result.new(email: normalized_email, reason: existing.reason, marked: true, changed: false, record: existing)
    end

    def authorize!
      if @company&.test_workspace?
        raise Forbidden, "Placeholder email settings are organization-wide and cannot be changed from a test workspace."
      end

      allowed = @actor.present? &&
        @organization.present? &&
        @actor.staff_member? &&
        (@actor.super_admin? || @actor.organization_id == @organization.id) &&
        StaffRolePolicy.allowed?(@actor, :manage_organization)

      raise Forbidden, StaffRolePolicy.error_message(:manage_organization) unless allowed
    end
  end
end
