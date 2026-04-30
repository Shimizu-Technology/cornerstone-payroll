# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientPortalThread, type: :model do
  describe "#mark_read_for!" do
    it "skips the write when the thread is already read for that side" do
      company = create(:company)
      staff = create(:user, company: company, role: "accountant")
      timestamp = 2.minutes.ago
      thread = create(:client_portal_thread,
        company: company,
        last_message_at: timestamp,
        staff_last_read_at: timestamp)

      expect(thread).not_to receive(:update!)

      thread.mark_read_for!(staff)
    end

    it "marks unread client threads as read" do
      company = create(:company)
      client = create(:user, company: company, role: "client")
      thread = create(:client_portal_thread,
        company: company,
        last_message_at: 1.minute.ago,
        client_last_read_at: nil)

      thread.mark_read_for!(client)

      expect(thread.client_last_read_at).to be_present
      expect(thread.unread_for?(client)).to be(false)
    end
  end
end
