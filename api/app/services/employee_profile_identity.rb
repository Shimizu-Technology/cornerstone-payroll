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

    normalized_full_name_match?(employee.first_name, employee.last_name, user.name)
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

  def self.normalized_full_name_match?(first_name, last_name, user_name)
    return false if first_name.blank? || last_name.blank? || user_name.blank?

    employee_name = normalize_full_name("#{first_name} #{last_name}")
    actor_name = normalize_full_name(user_name)
    employee_name.present? && actor_name.present? && employee_name == actor_name
  end

  class LinkCheckUnavailable < StandardError; end
end
