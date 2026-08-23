# frozen_string_literal: true

require "rails_helper"

RSpec.describe EncryptedDataReadiness do
  it "reads every supported persisted encrypted value" do
    employee = create(
      :employee,
      ssn_encrypted: "123-45-6789",
      bank_routing_number_encrypted: "123456789",
      bank_account_number_encrypted: "987654321"
    )
    source = TimeTrackingSource.create!(
      company: employee.company,
      name: "AIRE",
      source_type: "aire_services",
      base_url: "https://time.example.com",
      shared_secret: "shared-secret",
      active: false
    )
    request = create(:employee_change_request, employee: employee, company: employee.company)
    request.update!(sensitive_payload_encrypted: JSON.generate(proposed: { ssn_encrypted: "123-45-6789" }))
    session = UserSession.create!(
      user: create(:user),
      jti: SecureRandom.uuid,
      workos_access_token: "workos-access-token",
      expires_at: 1.hour.from_now
    )

    expect(described_class.verify!).to be(true)
    expect(source.reload.shared_secret).to eq("shared-secret")
    expect(session.reload.workos_access_token).to eq("workos-access-token")
  end

  it "fails when a persisted encrypted value cannot be decrypted" do
    employee = create(:employee, ssn_encrypted: "123-45-6789")
    ActiveRecord::Encryption.without_encryption do
      employee.update_column(:ssn_encrypted, "not-valid-active-record-ciphertext")
    end

    expect { described_class.verify! }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
  end
end
