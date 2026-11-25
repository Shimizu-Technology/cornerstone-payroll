# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class EmergencyContactsController < ProfileBaseController
        MAX_CONTACTS = 5

        def create
          if profile.contacts.count >= MAX_CONTACTS
            return render json: { error: "You can save up to five emergency contacts.", code: "emergency_contact_limit" },
              status: :unprocessable_entity
          end

          @audit_record = profile.contacts.create!(contact_params)
          record_emergency_change!([], [ @audit_record.as_profile_json ])
          render_profile(status: :created)
        end

        def update
          @audit_record = contact = profile.contacts.find(resource_id)
          before = [ contact.as_profile_json ]
          contact.update!(contact_params)
          record_emergency_change!(before, [ contact.as_profile_json ])
          render_profile
        end

        def destroy
          @audit_record = contact = profile.contacts.find(resource_id)
          before = [ contact.as_profile_json ]
          contact.destroy!
          record_emergency_change!(before, [])
          render_profile
        end

        private

        def record_emergency_change!(before, after)
          EmployeeContactChangeToConfirm.record!(
            employee: @employee, actor: current_user,
            before_values: { emergency_contacts: before }, after_values: { emergency_contacts: after }
          )
        end

        def contact_params
          params.permit(*EmployeeEmergencyContact::FIELDS).to_h.transform_values { |value| value.to_s.strip.presence }
        end
      end
    end
  end
end
