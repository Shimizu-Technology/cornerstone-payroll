# frozen_string_literal: true

require "rails_helper"

RSpec.describe PortalNotifications::Recipients, :portal_notifications do
  include ActiveSupport::Testing::TimeHelpers

  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:other_company) { create(:company, organization: organization) }
  let(:client) { create(:user, company: company, role: "client") }
  let(:thread) { create(:client_portal_thread, company: company, created_by: client) }

  def client_message_event(actor: client)
    message = create(:client_portal_message, client_portal_thread: thread, company: company, author: actor)
    PortalNotificationEvent.new(organization: organization, company: company, actor: actor, event_type: "client_message",
      category: "client_messages", subject: thread, dedupe_key: "spec:#{message.id}", occurred_at: Time.current)
  end

  def resolved(event)
    targets, status = described_class.resolve(event)
    [ targets.map(&:key), status ]
  end

  describe "staff-side alerts use only the client's configured list" do
    it "includes listed active staff who can view the client and nobody unlisted" do
      admin = create(:user, company: other_company, role: "admin")
      manager = create(:user, company: other_company, role: "manager")
      create(:company_assignment, user: manager, company: company)
      create(:user, company: company, role: "admin") # can view, but not listed
      list_portal_recipient!(company, user: admin)
      list_portal_recipient!(company, user: manager)

      expect(resolved(client_message_event)).to eq([ [ "user:#{admin.id}", "user:#{manager.id}" ], "recipients" ])
    end

    it "excludes deactivated, expired, cross-organization and client users even when listed" do
      deactivated = create(:user, company: company, role: "admin", active: false)
      expired_manager = create(:user, company: other_company, role: "manager")
      create(:company_assignment, user: expired_manager, company: company, expires_at: 1.minute.from_now)
      create(:company_assignment, user: expired_manager, company: other_company)
      foreign = create(:user, role: "admin")
      list_portal_recipient!(company, user: deactivated)
      list_portal_recipient!(company, user: expired_manager)
      list_portal_recipient!(company, user: foreign)
      list_portal_recipient!(company, user: create(:user, company: company, role: "client"))

      travel 2.minutes do
        expect(resolved(client_message_event)).to eq([ [], "no_recipients" ])
      end
    end

    it "excludes everyone once the client is inactive" do
      list_portal_recipient!(company, user: create(:user, company: company, role: "admin"))
      event = client_message_event
      company.update_columns(active: false)
      expect(resolved(event)).to eq([ [], "no_recipients" ])
    end

    it "never alerts the actor" do
      admin = create(:user, company: company, role: "admin")
      list_portal_recipient!(company, user: admin)
      expect(resolved(client_message_event(actor: admin))).to eq([ [], "no_recipients" ])
    end

    it "adds normalized extra addresses, skipping one that matches a listed user" do
      admin = create(:user, company: company, role: "admin", email: "owner@example.test")
      list_portal_recipient!(company, user: admin)
      list_portal_recipient!(company, email: "  Bookkeeper@Example.TEST ")
      list_portal_recipient!(company, email: "OWNER@example.test")

      expect(resolved(client_message_event)).to eq([ [ "user:#{admin.id}", "email:bookkeeper@example.test" ], "recipients" ])
    end

    it "does not use another client's list" do
      list_portal_recipient!(other_company, user: create(:user, company: company, role: "admin"))
      list_portal_recipient!(other_company, email: "other@example.test")
      expect(resolved(client_message_event)).to eq([ [], "no_recipients" ])
    end

    it "requires reviewers who can act on employee change requests" do
      admin = create(:user, company: company, role: "admin")
      accountant = create(:user, company: other_company, role: "accountant")
      create(:company_assignment, user: accountant, company: company)
      list_portal_recipient!(company, user: admin)
      list_portal_recipient!(company, user: accountant)
      request = create(:employee_change_request, company: company, employee: create(:employee, company: company), requested_by: client)
      event = PortalNotificationEvent.new(organization: organization, company: company, actor: client,
        event_type: "employee_change_submitted", category: "employee_changes", subject: request, dedupe_key: "spec", occurred_at: Time.current)

      expect(resolved(event)).to eq([ [ "user:#{admin.id}" ], "recipients" ])
    end

    it "lists eligible staff for administrators to tick" do
      admin = create(:user, company: company, role: "admin", name: "Avery Admin")
      unassigned_manager = create(:user, company: other_company, role: "manager")
      create(:company_assignment, user: unassigned_manager, company: other_company)
      create(:user, company: company, role: "admin", active: false)
      create(:user, role: "admin")

      expect(described_class.eligible_staff_for(company)).to eq([ admin ])
    end
  end

  describe "client-side alerts" do
    let(:staff) { create(:user, company: company, role: "admin") }

    it "go to the client's active portal users, never other clients or deactivated users" do
      second = create(:user, company: other_company, role: "client")
      create(:company_assignment, user: second, company: company)
      create(:user, company: company, role: "client", active: false)
      create(:user, company: other_company, role: "client")
      message = create(:client_portal_message, client_portal_thread: thread, company: company, author: staff)
      event = PortalNotificationEvent.new(organization: organization, company: company, actor: staff, event_type: "staff_reply",
        category: "portal_replies", subject: thread, dedupe_key: "spec:#{message.id}", occurred_at: Time.current)

      expect(resolved(event)).to eq([ [ client, second ].sort_by(&:id).map { |user| "user:#{user.id}" }, "recipients" ])
    end

    it "send change request decisions only to the requester" do
      create(:user, company: company, role: "client")
      request = create(:employee_change_request, company: company, employee: create(:employee, company: company), requested_by: client)
      event = PortalNotificationEvent.new(organization: organization, company: company, actor: staff, event_type: "employee_change_decided",
        category: "employee_change_decisions", subject: request, dedupe_key: "spec", occurred_at: Time.current)

      expect(resolved(event)).to eq([ [ "user:#{client.id}" ], "recipients" ])
    end
  end
end
