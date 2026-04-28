# frozen_string_literal: true

require "rails_helper"

RSpec.describe "historical actor references" do
  describe ClientDocument do
    it "requires an uploader when a new document is created" do
      document = build(:client_document, uploaded_by: nil)

      expect(document).not_to be_valid
      expect(document.errors[:uploaded_by]).to include("can't be blank")
    end

    it "allows existing documents to keep history after the uploader is nullified" do
      document = create(:client_document)

      document.uploaded_by = nil

      expect(document).to be_valid
    end
  end

  describe EmployeeChangeRequest do
    it "requires a requester when a new change request is created" do
      request = build(:employee_change_request, requested_by: nil)

      expect(request).not_to be_valid
      expect(request.errors[:requested_by]).to include("can't be blank")
    end

    it "allows existing change requests to keep history after the requester is nullified" do
      request = create(:employee_change_request)

      request.requested_by = nil

      expect(request).to be_valid
    end
  end

  describe UserInvitation do
    let(:company) { create(:company) }
    let(:inviter) { create(:user, company: company) }

    def invitation_attrs(overrides = {})
      {
        company: company,
        invited_by: inviter,
        email: "new.user@example.com",
        role: :employee,
        token: SecureRandom.hex(16),
        invited_at: Time.current,
        expires_at: 7.days.from_now
      }.merge(overrides)
    end

    it "requires an inviter when a new invitation is created" do
      invitation = described_class.new(invitation_attrs(invited_by: nil))

      expect(invitation).not_to be_valid
      expect(invitation.errors[:invited_by]).to include("can't be blank")
    end

    it "allows existing invitations to keep history after the inviter is nullified" do
      invitation = described_class.create!(invitation_attrs)

      invitation.invited_by = nil

      expect(invitation).to be_valid
    end
  end
end
