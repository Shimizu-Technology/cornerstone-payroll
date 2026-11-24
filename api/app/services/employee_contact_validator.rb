# frozen_string_literal: true

require "set"

class EmployeeContactValidator
  CONTACT_FIELDS = %i[email phone address_line1 address_line2 city state zip].freeze
  ADDRESS_REQUIRED_FIELDS = %i[address_line1 city state zip].freeze
  MAX_EMAIL_LENGTH = 254
  CLIENT_GENERIC_LOGIN_EMAIL_ERROR = "This email can't be used here. Ask Cornerstone to set it."
  LOGIN_NAME_MISMATCH_ERROR = "The name on this login doesn't match this employee"

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
    :login_email_rejected,
    :login_email_rejection_reason,
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

    def login_email_rejected?
      login_email_rejected == true
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

  # The characters String#strip removes, so SQL comparisons match
  # normalize_email. PostgreSQL TRIM removes spaces only.
  STRIP_CHARS = " \t\n\v\f\r"

  class << self
    def normalize_email(raw)
      raw.to_s.strip.downcase.presence
    end

    # LOWER(BTRIM(column, STRIP_CHARS)), the expression
    # index_employees_on_lower_email uses for employees.email. Built with Arel
    # so no SQL is assembled from strings.
    def normalized_email_node(attribute = Employee.arel_table[:email])
      Arel::Nodes::NamedFunction.new("LOWER", [ stripped_node(attribute) ])
    end

    # Whitespace-only counts as blank, as Ruby's strip does.
    def blank_node(attribute)
      Arel::Nodes::NamedFunction.new("COALESCE", [ stripped_node(attribute), Arel::Nodes.build_quoted("") ]).eq("")
    end

    def present_node(attribute)
      Arel::Nodes::NamedFunction.new("COALESCE", [ stripped_node(attribute), Arel::Nodes.build_quoted("") ]).not_eq("")
    end

    def stripped_node(attribute)
      Arel::Nodes::NamedFunction.new("BTRIM", [ attribute, Arel::Nodes.build_quoted(STRIP_CHARS) ])
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

      # North American area codes and exchanges never start with 0 or 1.
      normalized = nil if normalized&.match?(/\A\+1\d{10}\z/) && !normalized.match?(/\A\+1[2-9]\d{2}[2-9]/)
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

    # Blocking and bulk-clearing require an explicitly marked address (DB
    # employee_placeholder_emails) or configured address (EMPLOYEE_PLACEHOLDER_EMAILS).
    # Structural patterns alone only surface candidates and warn.
    def placeholder_email?(raw, organization_id: nil, marked_placeholders: nil)
      email = normalize_email(raw)
      return false if email.blank?
      return true if configured_placeholder_emails.include?(email)

      marked = marked_placeholders.nil? ? db_marked_placeholder_emails(organization_id) : marked_placeholders
      marked.include?(email)
    end

    # Email matchers (time tracking, cockpit, profitability) skip both explicitly
    # marked/configured placeholders and structural placeholder patterns.
    def unmatchable_placeholder_email?(raw, organization_id: nil, marked_placeholders: nil)
      email = normalize_email(raw)
      return false if email.blank?

      structural_placeholder_email?(email) ||
        placeholder_email?(email, organization_id: organization_id, marked_placeholders: marked_placeholders)
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
        .where(present_node(Employee.arel_table[:email]))
        .group(normalized_email_node)
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
      elsif structural_placeholder_email?(normalized_email)
        "placeholder_pattern"
      elsif shared_count >= 2
        "shared_with_coworker"
      end

      needs_contact = missing_fields.any? || email_issue == "placeholder" || email_issue == "placeholder_pattern"

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
      begin
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
    end

    # The same first-and-last-name rule a same-person email confirmation uses.
    def login_name_matches?(login_user, employee)
      new(employee: employee, company: employee.company).send(:login_name_matches_employee?, login_user)
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
    flagged_emails: nil,
    check_login_identity: true
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
    @check_login_identity = check_login_identity
  end

  def call
    errors = {}
    warnings = []
    same_person_confirmation_required = false
    same_person_confirmed = false
    confirmation_basis = nil
    matched_login_user = nil
    login_email_rejected = false
    login_email_rejection_reason = nil

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
        if self.class.structural_placeholder_email?(normalized_email)
          warnings << {
            code: "placeholder_email_pattern",
            field: "email",
            message: "This looks like a placeholder or generic email address. Enter the employee's own email if they have one."
          }
        end

        login_check = @check_login_identity ? check_login_email(normalized_email) : no_login_conflict
        matched_login_user = login_check[:user]
        same_person_confirmation_required = login_check[:confirmation_required]
        same_person_confirmed = login_check[:confirmed]
        confirmation_basis = login_check[:confirmation_basis]
        login_email_rejected = login_check[:rejected] == true
        login_email_rejection_reason = login_check[:rejection_reason]
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
      matched_login_user: matched_login_user,
      login_email_rejected: login_email_rejected,
      login_email_rejection_reason: login_email_rejection_reason
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
    login_user = User.where(self.class.normalized_email_node(User.arel_table[:email]).eq(normalized_email)).first
    return no_login_conflict unless login_user

    # Check conflicting links FIRST via a narrow tenant-safe decision lookup
    # that sees links in other companies without leaking records. A login with
    # an active/non-revoked link to any other employee always rejects, even if
    # an allowed link to this employee also exists.
    link_decision = EmployeeAccountLink.contact_email_link_decision(
      user_id: login_user.id,
      company_id: @company&.id,
      allowed_employee_ids: own_employee_ids
    )

    if link_decision == :conflict
      return rejected_login_conflict(
        login_user: login_user,
        staff_message: "belongs to a payroll login that is already linked to another employee",
        rejection_reason: "linked_to_other_employee"
      )
    end

    # Fail closed: links at other clients can't be checked from here.
    if link_decision == :unknown
      return rejected_login_conflict(
        login_user: login_user,
        staff_message: "belongs to a payroll login, and its links at other clients can't be checked here; ask Cornerstone to set it",
        rejection_reason: "link_check_unavailable"
      )
    end

    if link_decision == :allowed
      return no_login_conflict(user: login_user)
    end

    own_login = @actor.present? && login_user.id == @actor.id
    # A same-person confirmation needs the login's name to match this
    # employee's, so nobody can attach their login to someone else's record.
    if (own_login || staff_can_confirm_login_email?(login_user)) && !login_name_matches_employee?(login_user)
      return rejected_login_conflict(staff_message: LOGIN_NAME_MISMATCH_ERROR, rejection_reason: "login_name_mismatch", login_user: login_user)
    end

    # (b) The entered email is the signed-in user's own login email.
    if own_login
      if @confirm_same_person_email
        return {
          user: login_user,
          confirmation_required: false,
          confirmed: true,
          confirmation_basis: "self_confirmed",
          rejected: false,
          rejection_reason: nil,
          error: nil
        }
      end

      return {
        user: login_user,
        confirmation_required: true,
        confirmed: false,
        confirmation_basis: nil,
        rejected: false,
        rejection_reason: nil,
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
          rejected: false,
          rejection_reason: nil,
          error: nil
        }
      end

      return {
        user: login_user,
        confirmation_required: true,
        confirmed: false,
        confirmation_basis: nil,
        rejected: false,
        rejection_reason: nil,
        error: "belongs to an existing payroll login for #{login_user.name} (#{login_user.role}); confirm this is the same person to use it"
      }
    end

    rejected_login_conflict(
      login_user: login_user,
      staff_message: "belongs to another person's payroll login; ask a manager or admin with client configuration access to confirm it",
      rejection_reason: "other_user_login"
    )
  end

  def no_login_conflict(user: nil)
    {
      user: user,
      confirmation_required: false,
      confirmed: false,
      confirmation_basis: nil,
      rejected: false,
      rejection_reason: nil,
      error: nil
    }
  end

  # Only staff allowed to confirm this login's identity see why it was
  # refused. Everyone else, clients included, gets the generic message; the
  # reason is kept in the security audit (employees#login_email_rejected).
  def rejected_login_conflict(staff_message:, rejection_reason:, login_user:)
    detailed = @actor&.staff_member? && staff_can_confirm_login_email?(login_user)
    {
      user: nil,
      confirmation_required: false,
      confirmed: false,
      confirmation_basis: nil,
      rejected: true,
      rejection_reason: rejection_reason,
      error: detailed ? staff_message : CLIENT_GENERIC_LOGIN_EMAIL_ERROR
    }
  end

  def self.comparable_name(value)
    value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^\p{Alnum}]+/u, " ").squish
  end

  # First and last name, ignoring case, accents and spacing; a middle name on
  # the login is fine. Compared with the employee as stored, so renaming the
  # employee in the same save can't create a match.
  NAME_SUFFIXES = %w[jr sr ii iii iv].freeze

  # A recognized suffix at the end of the login name ("Jr.", "III") must match
  # the employee's stored suffix; a login that leaves the suffix off still
  # matches on first and last name.
  def login_name_matches_employee?(login_user)
    stored = ->(field) { @employee&.persisted? ? @employee.attribute_in_database(field) : @employee&.public_send(field) }
    first = self.class.comparable_name(stored.call("first_name"))
    last = self.class.comparable_name(stored.call("last_name"))
    suffix = self.class.comparable_name(stored.call("name_suffix"))
    login_name = self.class.comparable_name(login_user.name)
    return false if first.blank? || last.blank? || login_name.blank?

    words = login_name.split
    if words.length > 2 && NAME_SUFFIXES.include?(words.last)
      return false unless words.last == suffix

      login_name = words[0...-1].join(" ")
    end
    login_name == "#{first} #{last}" || (login_name.start_with?("#{first} ") && login_name.end_with?(" #{last}"))
  end

  def own_employee_ids
    ids = []
    ids << @employee.id if @employee&.persisted?
    ids << @employee.previous_employee_id if @employee&.previous_employee_id.present?
    ids.uniq
  end

  def staff_can_confirm_login_email?(login_user)
    return false unless @actor&.staff_member? && @company.present?
    return false unless @actor.can_access_company?(@company.id)
    return false unless StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @company)

    login_user.organization_id == @company.organization_id || login_user.super_admin?
  end

  def same_company_coworker_email_count(normalized_email)
    return 0 if @company.blank?

    scope = Employee.where(company_id: @company.id).where(self.class.normalized_email_node.eq(normalized_email))
    scope = scope.where.not(id: @exclude_employee_ids) if @exclude_employee_ids.any?
    scope.count
  end
end
