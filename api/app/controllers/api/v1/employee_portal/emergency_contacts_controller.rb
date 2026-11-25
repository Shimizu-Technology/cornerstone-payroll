# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class EmergencyContactsController < ProfileBaseController
        def create
          @audit_record = profile.contacts.create!(contact_params)
          record_contact_change!({}, emergency_contacts: [ @audit_record.as_profile_json ])
          render_profile(status: :created)
        end

        def update
          @audit_record = contact = profile.contacts.find(resource_id)
          before = { emergency_contacts: [ contact.as_profile_json ] }
          contact.update!(contact_params)
          record_contact_change!(before, emergency_contacts: [ contact.as_profile_json ])
          render_profile
        end

        def destroy
          @audit_record = contact = profile.contacts.find(resource_id)
          before = { emergency_contacts: [ contact.as_profile_json ] }
          contact.destroy!
          record_contact_change!(before, emergency_contacts: [])
          render_profile
        end

        private

        def contact_params
          params.permit(*EmployeeEmergencyContact::FIELDS).to_h.transform_values { |value| value.to_s.strip.presence }
        end
      end
    end
  end
end
