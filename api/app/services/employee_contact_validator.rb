# frozen_string_literal: true

require "set"

class EmployeeContactValidator
  CONTACT_FIELDS = %i[email phone address_line1 address_line2 city state zip].freeze
  ADDRESS_REQUIRED_FIELDS = %i[address_line1 city state zip].freeze
  MAX_EMAIL_LENGTH = 254
  CLIENT_GENERIC_LOGIN_EMAIL_ERROR = "This email can't be used here. Ask Cornerstone to set it."

  # Structural placeholder local parts and domains (never put real addresses here).
  PLACEHOLDER_LOCAL_PARTS = %w[
    noemail no-email no_email none na n/a noreply no-reply no_reply
    donotreply do-not-reply do_not_reply unknown placeholder missing tbd blank dummy
  ].to_set.freeze

  PLACEHOLDER_DOMAINS = %w[
    none.com noemail.com invalid localhost placeholder.local example.invalid
  ].to_set.freeze

  EMAIL_FORMAT_PATTERN = /\A[^@\s]+@[^@\s.]+\.[^@\s]{2,}\z/
  PHONE_ALLOWED_CHARS = /\A\+?[0-9\s\-().]+\z/

  Result = Struct.new(
    :errors,
    :warnings,
    :normalized_email,
    :normalized_phone,
    :same_person_confirmation_required,
    :same_person_confirmed,
    :confirmation_basis,
    :matched_login_user,
    keyword_init: true
  ) do
    def valid?
      errors.empty?
    end

    def same_person_confirmation_required?
      same_person_confirmation_required == true
    end

    def same_person_confirmed?
      same_person_confirmed == true
    end

    def apply_errors_to(record)
      errors.each do |attribute, messages|
        messages.each { |message| record.errors.add(attribute, message) }
      end
    end

    def contact_validation_payload
      {
        same_person_confirmation_required: same_person_confirmation_required?,
        warnings: warnings
      }
    end
  end

  class ValidationError < StandardError
    attr_reader :result, :record

    def initialize(result:, record: nil)
      @result = result
      @record = record
      super("Validation failed")
    end
  end

  class << self
    def normalize_email(raw)
      raw.to_s.strip.downcase.presence
    end

    def normalize_phone(raw)
      return [ nil, nil ] if raw.blank?

      text = raw.to_s.strip
      unless text.match?(PHONE_ALLOWED_CHARS)
        return [ nil, "must be a valid phone number (7-digit Guam numbers default to +1 671)" ]
      end

      has_plus = text.start_with?("+")
      digits = text.gsub(/\D/, "")
      return [ nil, "must be a valid phone number (7-digit Guam numbers default to +1 671)" ] if digits.blank? || digits.match?(/\A0+\z/)

      normalized = if has_plus
        if digits.start_with?("0")
          nil
        elsif digits.start_with?("1")
          digits.length == 11 ? "+#{digits}" : nil
        elsif digits.length.between?(8, 15)
          "+#{digits}"
        end
      elsif digits.length == 7
        "+1671#{digits}"
      elsif digits.length == 10
        "+1#{digits}"
      elsif digits.length == 11 && digits.start_with?("1")
        "+#{digits}"
      end

      return [ normalized, nil ] if normalized

      [ nil, "must be a valid phone number (7-digit Guam numbers default to +1 671)" ]
    end

    def configured_placeholder_emails
      raw_env = ENV["EMPLOYEE_PLACEHOLDER_EMAILS"].to_s
      raw_config = Rails.application.config.x.respond_to?(:employee_placeholder_emails) ?
        Rails.application.config.x.employee_placeholder_emails : nil

      entries = raw_env.split(/[\s,;]+/)
      entries.concat(Array(raw_config).flat_map { |item| item.to_s.split(/[\s,;]+/) })
      entries.filter_map { |entry| normalize_email(entry) }.to_set
    end

    def db_marked_placeholder_emails(organization_id)
      return Set.new if organization_id.blank?

      EmployeePlaceholderEmail.where(organization_id: organization_id).pluck(:email).filter_map { |entry| normalize_email(entry) }.to_set
    end

    def marked_placeholder_emails(organization_id:)
      configured_placeholder_emails | db_marked_placeholder_emails(organization_id)
    end

    def structural_placeholder_email?(raw)
      email = normalize_email(raw)
      return false if email.blank?

      local_part, domain = email.split("@", 2)
      return false if local_part.blank? || domain.blank?

      PLACEHOLDER_LOCAL_PARTS.include?(local_part) || PLACEHOLDER_DOMAINS.include?(domain)
    end

    def placeholder_email?(raw, organization_id: nil, marked_placeholders: nil)
      email = normalize_email(raw)
      return false if email.blank?
      return true if structural_placeholder_email?(email) || configured_placeholder_emails.include?(email)

      marked = marked_placeholders || db_marked_placeholder_emails(organization_id)
      marked.include?(email)
    end

    # Company-independent marked placeholder list for the organization.
    # Unmarked same-company duplicates are never auto-flagged here so family
    # members can share an address without being blocked or bulk-cleared.
    def flagged_emails_for_organization(organization_id:, company_id: nil)
      marked_placeholder_emails(organization_id: organization_id)
    end

    def contact_details_context(company:)
      flagged = marked_placeholder_emails(organization_id: company.organization_id)
      company_email_counts = Employee.where(company_id: company.id)
        .where("COALESCE(TRIM(email), '') <> ''")
        .group(Arel.sql("LOWER(TRIM(email))"))
        .count

      {
        flagged_emails: flagged,
        company_email_counts: company_email_counts
      }
    end

    def contact_details_status(employee, context: nil)
      ctx = context || contact_details_context(company: employee.company)
      normalized_email = normalize_email(employee.email)
      flagged_emails = ctx.fetch(:flagged_emails)
      company_email_counts = ctx.fetch(:company_email_counts)

      missing_fields = []
      missing_fields << "email" if normalized_email.blank?
      missing_fields << "phone" if employee.phone.blank?
      ADDRESS_REQUIRED_FIELDS.each do |field|
        missing_fields << field.to_s if employee.public_send(field).blank?
      end

      shared_count = normalized_email.present? ? company_email_counts.fetch(normalized_email, 0).to_i : 0
      email_issue = if normalized_email.blank?
        nil
      elsif placeholder_email?(normalized_email, organization_id: employee.company&.organization_id, marked_placeholders: flagged_emails)
        "placeholder"
      elsif shared_count >= 2
        "shared_with_coworker"
      end

      needs_contact = missing_fields.any? || email_issue == "placeholder"

      {
        "needs_contact_details" => needs_contact,
        "missing_fields" => missing_fields,
        "email_issue" => email_issue,
        "shared_email_count" => shared_count
      }
    end

    def call(**kwargs)
      new(**kwargs).call
    end

    def record_same_person_confirmation_audit!(employee:, result:, actor:, company:, ip_address: nil, user_agent: nil, request_id: nil)
      return unless result&.same_person_confirmed?

      previous_recorded = Current.domain_audit_recorded
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "employees#confirm_same_person_email",
        record_type: "employees",
        record_id: employee.id,
        subject_name: employee.display_name,
        metadata: {
          email: employee.email,
          same_person_email_confirmed: true,
          confirmed_login_user_id: result.matched_login_user&.id,
          confirmation_basis: result.confirmation_basis
        },
        ip_address: ip_address,
        user_agent: user_agent,
        request_id: request_id
      )
    ensure
      Current.domain_audit_recorded = previous_recorded
    end

    def validate_for_invite(employee, company: employee.company, allow_same_person_login: false, actor: nil)
      result = new(
        employee: employee,
        company: company,
        email: employee.email,
        phone: :unchanged,
        confirm_same_person_email: allow_same_person_login,
        actor: actor,
        source: "staff"
      ).call

      if result.normalized_email.blank?
        result.errors[:email] ||= []
        result.errors[:email] << "is required to send an email invite"
      end

      shared_warning = result.warnings.find { |warning| warning[:code] == "shared_company_email" }
      if shared_warning
        result.errors[:email] ||= []
        result.errors[:email] << "is used by another employee at this company and cannot be used for an email invite"
      end

      result
    end
  end

  def initialize(
    employee:,
    company:,
    email: :unchanged,
    phone: :unchanged,
    confirm_same_person_email: false,
    actor: nil,
    source: nil,
    exclude_employee_ids: [],
    flagged_emails: nil
  )
    @employee = employee
    @company = company
    @raw_email = email
    @raw_phone = phone
    @confirm_same_person_email = ActiveModel::Type::Boolean.new.cast(confirm_same_person_email) == true
    @actor = actor
    @source = source
    @exclude_employee_ids = Array(exclude_employee_ids).compact
    @exclude_employee_ids << employee.id if employee&.persisted?
    @exclude_employee_ids << employee.previous_employee_id if employee&.previous_employee_id.present?
    @exclude_employee_ids.uniq!
    @flagged_emails = flagged_emails
  end

  def call
    errors = {}
    warnings = []
    same_person_confirmation_required = false
    same_person_confirmed = false
    confirmation_basis = nil
    matched_login_user = nil

    normalized_email = @raw_email == :unchanged ? self.class.normalize_email(@employee&.email) : self.class.normalize_email(@raw_email)
    normalized_phone = @raw_phone == :unchanged ? @employee&.phone : nil

    if @raw_phone != :unchanged
      normalized_phone, phone_error = self.class.normalize_phone(@raw_phone)
      add_error(errors, :phone, phone_error) if phone_error.present?
    end

    if @raw_email != :unchanged && normalized_email.present?
      if !valid_email_format?(normalized_email)
        add_error(errors, :email, "must be a valid email address")
      elsif self.class.placeholder_email?(normalized_email, organization_id: @company&.organization_id, marked_placeholders: @flagged_emails)
        add_error(errors, :email, "cannot be a placeholder or generic inbox address; enter the employee's own email")
      else
        login_check = check_login_email(normalized_email)
        matched_login_user = login_check[:user]
        same_person_confirmation_required = login_check[:confirmation_required]
        same_person_confirmed = login_check[:confirmed]
        confirmation_basis = login_check[:confirmation_basis]
        add_error(errors, :email, login_check[:error]) if login_check[:error].present?

        if errors[:email].blank?
          coworker_count = same_company_coworker_email_count(normalized_email)
          if coworker_count >= 1
            warnings << {
              code: "shared_company_email",
              field: "email",
              message: "Another employee at this company already uses this email address. Family members may share one, but email invites require a unique address.",
              matching_employee_count: coworker_count
            }
          end
        end
      end
    end

    Result.new(
      errors: errors,
      warnings: warnings,
      normalized_email: normalized_email,
      normalized_phone: normalized_phone,
      same_person_confirmation_required: same_person_confirmation_required,
      same_person_confirmed: same_person_confirmed,
      confirmation_basis: confirmation_basis,
      matched_login_user: matched_login_user
    )
  end

  private

  def add_error(errors, field, message)
    errors[field] ||= []
    errors[field] << message
  end

  def valid_email_format?(email)
    return false if email.length > MAX_EMAIL_LENGTH
    return false if email.include?("..")

    email.match?(URI::MailTo::EMAIL_REGEXP) && email.match?(EMAIL_FORMAT_PATTERN)
  end

  def check_login_email(normalized_email)
    login_user = User.where("LOWER(TRIM(email)) = ?", normalized_email).first
    return no_login_conflict unless login_user

    # (a) Login is already linked to this employee (or predecessor in classification transition).
    if linked_to_this_employee?(login_user)
      return no_login_conflict(user: login_user)
    end

    # A login linked to a different employee always rejects.
    if linked_to_other_employee?(login_user)
      return rejected_login_conflict(
        staff_message: "belongs to a payroll login that is already linked to another employee"
      )
    end

    # (b) The entered email is the signed-in user's own login email.
    if @actor.present? && login_user.id == @actor.id
      if @confirm_same_person_email
        return {
          user: login_user,
          confirmation_required: false,
          confirmed: true,
          confirmation_basis: "self_confirmed",
          error: nil
        }
      end

      return {
        user: login_user,
        confirmation_required: true,
        confirmed: false,
        confirmation_basis: nil,
        error: @actor.client? ?
          "This is your own payroll login email. Confirm \"this is me\" to assign it to this employee." :
          "is your own payroll login email; confirm \"this is me\" to assign it to this employee"
      }
    end

    # (c) Cornerstone staff with manage_client_configuration confirm it on the admin side.
    if staff_can_confirm_login_email?(login_user)
      if @confirm_same_person_email
        return {
          user: login_user,
          confirmation_required: false,
          confirmed: true,
          confirmation_basis: "staff_confirmed",
          error: nil
        }
      end

      return {
        user: login_user,
        confirmation_required: true,
        confirmed: false,
        confirmation_basis: nil,
        error: "belongs to an existing payroll login for #{login_user.name} (#{login_user.role}); confirm this is the same person to use it"
      }
    end

    rejected_login_conflict(
      staff_message: "belongs to another person's payroll login; ask a manager or admin with client configuration access to confirm it"
    )
  end

  def no_login_conflict(user: nil)
    {
      user: user,
      confirmation_required: false,
      confirmed: false,
      confirmation_basis: nil,
      error: nil
    }
  end

  def rejected_login_conflict(staff_message:)
    {
      user: nil,
      confirmation_required: false,
      confirmed: false,
      confirmation_basis: nil,
      error: @actor&.client? ? CLIENT_GENERIC_LOGIN_EMAIL_ERROR : staff_message
    }
  end

  def own_employee_ids
    ids = []
    ids << @employee.id if @employee&.persisted?
    ids << @employee.previous_employee_id if @employee&.previous_employee_id.present?
    ids.uniq
  end

  def linked_to_this_employee?(login_user)
    candidate_ids = own_employee_ids
    return false if candidate_ids.empty? || @company.blank?

    EmployeeAccountLink
      .where(company_id: @company.id, employee_id: candidate_ids, user_id: login_user.id)
      .where.not(status: "revoked")
      .exists?
  end

  def linked_to_other_employee?(login_user)
    scope = EmployeeAccountLink.where(user_id: login_user.id).where.not(status: "revoked")
    scope = scope.where(company_id: @company.id) if TenantScope.current&.mode == "company" && @company.present?
    candidate_ids = own_employee_ids
    scope = scope.where.not(employee_id: candidate_ids) if candidate_ids.any?
    scope.exists?
  end

  def staff_can_confirm_login_email?(login_user)
    return false unless @actor&.staff_member? && @company.present?
    return false unless @actor.can_access_company?(@company.id)
    return false unless StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @company)

    login_user.organization_id == @company.organization_id || login_user.super_admin?
  end

  def same_company_coworker_email_count(normalized_email)
    return 0 if @company.blank?

    scope = Employee.where(company_id: @company.id).where("LOWER(TRIM(email)) = ?", normalized_email)
    scope = scope.where.not(id: @exclude_employee_ids) if @exclude_employee_ids.any?
    scope.count
  end
end
