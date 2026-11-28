# frozen_string_literal: true

module EmployeeProfileIdentity
  def self.own_record?(employee, user)
    decision = EmployeeAccountLink.contact_email_link_decision(
      user_id: user.id, company_id: employee.company_id, allowed_employee_ids: [ employee.id ]
    )

    return true if decision == :allowed

    # The function reports a conflict for multiple links and ignores revoked
    # links. A link to this record still identifies the person in both cases.
    return true if EmployeeAccountLink.exists?(company_id: employee.company_id, employee_id: employee.id, user_id: user.id)
    raise LinkCheckUnavailable, "We couldn’t verify who can make this address change. Please try again." if decision == :unknown

    AuditLog.where(
      company_id: employee.company_id, record_type: "employees", record_id: employee.id,
      action: "employees#confirm_same_person_email"
    ).where("metadata ->> 'confirmed_login_user_id' = ?", user.id.to_s).exists?
  end

  def self.own_record_for_client_managed?(employee, user)
    return false unless employee && user
    return true if own_record?(employee, user)
    return true if normalized_email_match?(employee.email, user.email)
    return true if normalized_full_name_match?(employee.first_name, employee.last_name, user.name)

    sticky_own_record?(employee, user)
  end

  def self.possible_self_created_hire?(employee, user, same_person_confirmed: false)
    return true if same_person_confirmed
    return false unless employee && user
    return true if normalized_email_match?(employee.email, user.email)

    normalized_full_name_match?(employee.first_name, employee.last_name, user.name)
  end

  def self.normalized_email_match?(left, right)
    left_email = EmployeeContactValidator.normalize_email(left)
    right_email = EmployeeContactValidator.normalize_email(right)
    left_email.present? && right_email.present? && left_email == right_email
  end

  def self.normalize_full_name(value)
    value.to_s.downcase.gsub(/[^\p{Alnum}\s]/, " ").squish.presence
  end

  def self.name_tokens(value)
    normalize_full_name(value).to_s.split
  end

  # Token-set matching on first + last name so middle names, middle initials,
  # suffixes, or "Last, First" order (e.g. "Sloane M. Owner" vs "Sloane Owner")
  # cannot bypass self-record detection. Common names (including common Guam
  # names) may produce intentional fail-safe false positives: those edits are
  # never blocked, they are routed to Cornerstone staff for independent review.
  def self.normalized_full_name_match?(first_name, last_name, user_name)
    first_tokens = name_tokens(first_name)
    last_tokens = name_tokens(last_name)
    actor_tokens = name_tokens(user_name)
    return false if first_tokens.empty? || last_tokens.empty? || actor_tokens.length < 2

    employee_tokens = (first_tokens + last_tokens).uniq
    return true if employee_tokens.all? { |token| actor_tokens.include?(token) }

    actor_tokens.all? { |token| employee_tokens.include?(token) } &&
      (actor_tokens & first_tokens).any? &&
      (actor_tokens & last_tokens).any?
  end

  # Once an employee record has been identified as belonging to a client actor
  # (via a prior own-record change request, an own-record / possible-self-hire
  # verification item, or a prior recorded identity snapshot), keep treating it
  # as that actor's own record even if the record is later renamed or re-emailed.
  def self.sticky_own_record?(employee, user)
    return false unless employee&.persisted? && user&.persisted?

    if EmployeeChangeRequest.for_company(employee.company_id)
        .where(employee_id: employee.id, own_record: true, requested_by_id: user.id)
        .exists?
      return true
    end

    EmployeeVerificationItem.where(company_id: employee.company_id, employee_id: employee.id)
      .select(:id, :source_actor_id, :before_values, :after_values, :metadata)
      .any? do |item|
        meta = item.metadata.to_h
        next true if meta["own_record_actor_id"].to_i == user.id
        next true if meta["possible_self_created_hire"] == true && item.source_actor_id == user.id

        historical_values_match_user?(item.before_values, employee, user) ||
          historical_values_match_user?(item.after_values, employee, user)
      end
  end

  def self.historical_values_match_user?(values, employee, user)
    return false unless values.is_a?(Hash) && values.present?

    snapshot = values.stringify_keys
    return true if snapshot["email"].present? && normalized_email_match?(snapshot["email"], user.email)

    if snapshot["first_name"].present? || snapshot["last_name"].present?
      first = snapshot["first_name"].presence || employee.first_name
      last = snapshot["last_name"].presence || employee.last_name
      return true if normalized_full_name_match?(first, last, user.name)
    end

    false
  end
  private_class_method :historical_values_match_user?

  class LinkCheckUnavailable < StandardError; end
end
