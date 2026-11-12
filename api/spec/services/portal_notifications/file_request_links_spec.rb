# frozen_string_literal: true

require "rails_helper"

RSpec.describe PortalNotifications::Email do
  def event(event_type)
    PortalNotificationEvent.new(event_type: event_type, category: PortalNotifications::EVENT_TYPES.fetch(event_type).fetch(:category))
  end

  around do |example|
    previous = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://payroll.example.test"
    example.run
  ensure
    ENV["FRONTEND_URL"] = previous
  end

  it "links file-request alerts to where the request is handled, keyed on the event" do
    expect(described_class.new(audience: "client", delivery_mode: "immediate", events: [ event("file_requested") ]).link)
      .to eq("https://payroll.example.test/messages")
    expect(described_class.new(audience: "client", delivery_mode: "immediate", events: [ event("file_request_reviewed") ]).link)
      .to eq("https://payroll.example.test/messages")
    expect(described_class.new(audience: "staff", delivery_mode: "immediate", events: [ event("file_request_responded") ]).link)
      .to eq("https://payroll.example.test/app/client-inbox")
    # Other events in the same categories keep their pages.
    expect(described_class.new(audience: "client", delivery_mode: "immediate", events: [ event("staff_reply") ]).link)
      .to eq("https://payroll.example.test/documents")
    expect(described_class.new(audience: "staff", delivery_mode: "immediate", events: [ event("client_message") ]).link)
      .to eq("https://payroll.example.test/settings/client-documents")
    expect(described_class.destination_group(event("file_requested"))).not_to eq(described_class.destination_group(event("staff_reply")))
  end
end
