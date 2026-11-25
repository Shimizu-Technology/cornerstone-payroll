# frozen_string_literal: true

module EmployeeProfiles
  class Profile
    def initialize(link, employee)
      @link = link
      @employee = employee
    end

    def as_json
      pending = requests.pending.recent_first.first
      own_pending = pending if pending&.requested_by_link_id == @link.id && pending.profile_address?
      last_decision = own_requests.where(status: %i[approved rejected]).order(reviewed_at: :desc, id: :desc).first unless own_pending
      {
        legal_name: @employee.full_name,
        email: @employee.email, email_verified: @employee.email_verified_at?,
        phone: @employee.phone, phone_confirmed: @employee.phone_confirmed_by_employee_at?,
        address: @employee.slice(*EmployeeChangeRequest::ADDRESS_FIELDS), payment_method: @employee.payment_delivery_method,
        emergency_contacts: contacts.order(:id).map(&:as_profile_json),
        address_request: serialize_request(own_pending || last_decision),
        other_request_pending: pending.present? && own_pending.nil?
      }
    end

    def contacts
      EmployeeEmergencyContact.active.where(company_id: @link.company_id, employee_id: @link.employee_id)
    end

    def requests
      EmployeeChangeRequest.for_company(@link.company_id).where(employee_id: @link.employee_id)
    end

    def own_requests
      requests.profile_addresses.where(requested_by_link_id: @link.id)
    end

    private

    def serialize_request(record)
      return unless record

      {
        id: record.id.to_s, status: record.status, requested: record.original_values
          .slice(*EmployeeChangeRequest::ADDRESS_FIELDS).merge(record.proposed_changes),
        submitted_at: record.created_at, decided_at: record.reviewed_at, decision_note: record.review_notes
      }
    end
  end
end
