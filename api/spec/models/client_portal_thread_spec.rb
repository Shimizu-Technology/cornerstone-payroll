# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientPortalThread, type: :model do
  let(:company) { create(:company) }
  let(:thread) { create(:client_portal_thread, company: company) }

  it "keeps two staff and two clients independent regardless of legacy timestamps" do
    users = %w[accountant manager client client].map { |role| create(:user, company: company, role: role) }
    message = create(:client_portal_message, company: company, client_portal_thread: thread, author: users.first)
    users.each { |user| expect(thread.unread_for?(user)).to be(true) }
    [ users.first, users.third ].each do |user|
      thread.mark_read_for!(user, last_displayed_message_id: message.id)
      expect(thread.unread_for?(user)).to be(false)
    end
    expect(thread.unread_for?(users.second)).to be(true)
    expect(thread.unread_for?(users.fourth)).to be(true)
    expect(thread.reload.staff_last_read_at).to be_present
    expect(thread.client_last_read_at).to be_present
  end

  it "starts pre-migration history read without hiding new messages" do
    user = create(:user, company: company, role: "client")
    old = create(:client_portal_message, company: company, client_portal_thread: thread)
    thread.update!(read_baseline_message_id: old.id)
    expect(thread.unread_for?(user)).to be(false)
    create(:client_portal_message, company: company, client_portal_thread: thread)
    expect(thread.unread_for?(user)).to be(true)
  end

  it "never moves a cursor backwards and rejects another conversation's message" do
    user = create(:user, company: company)
    first = create(:client_portal_message, company: company, client_portal_thread: thread)
    last = create(:client_portal_message, company: company, client_portal_thread: thread)
    thread.mark_read_for!(user, last_displayed_message_id: last.id)
    expect(thread.mark_read_for!(user, last_displayed_message_id: first.id)).to be(false)
    expect(thread.read_cursor_for(user)).to eq(last.id)
    other = create(:client_portal_message)
    expect { thread.mark_read_for!(user, last_displayed_message_id: other.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
