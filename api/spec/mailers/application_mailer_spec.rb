# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationMailer do
  before do
    stub_const("ViewAsProbeMailer", Class.new(described_class) do
      def probe
        mail(to: "fixture@example.com", subject: "Delivery probe", body: "Fixture")
      end
    end)
  end

  it "blocks synchronous and queued mail while viewing" do
    Current.set(view_as_grant: ViewAsGrant.new) do
      expect { ViewAsProbeMailer.probe.deliver_now }.to raise_error(ActiveRecord::ReadOnlyError)
      expect { ViewAsProbeMailer.probe.deliver_later }.to raise_error(ActiveRecord::ReadOnlyError)
      expect { ViewAsProbeMailer.with(fixture: true).probe.deliver_later! }.to raise_error(ActiveRecord::ReadOnlyError)
    end

    expect(ApplicationMailDeliveryJob).not_to have_been_enqueued
  end

  it "still queues mail outside view-as" do
    expect { ViewAsProbeMailer.probe.deliver_later }.to have_enqueued_job(ApplicationMailDeliveryJob)
  end
end
