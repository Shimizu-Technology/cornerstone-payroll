# frozen_string_literal: true

class EncryptedDataReadiness
  TARGETS = {
    Employee => %i[ssn_encrypted bank_routing_number_encrypted bank_account_number_encrypted],
    TimeTrackingSource => %i[shared_secret],
    EmployeeChangeRequest => %i[sensitive_payload_encrypted]
  }.freeze

  def self.verify!
    TARGETS.each do |model, attributes|
      model.unscoped.select(model.primary_key, *attributes).find_each(batch_size: 100) do |record|
        attributes.each { |attribute| record.public_send(attribute) }
      end
    end

    UserSession.active.select(UserSession.primary_key, :workos_access_token).find_each(batch_size: 100) do |session|
      session.workos_access_token
    end

    true
  end
end
