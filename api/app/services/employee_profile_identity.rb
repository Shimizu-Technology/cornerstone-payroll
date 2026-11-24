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

  class LinkCheckUnavailable < StandardError; end
end
