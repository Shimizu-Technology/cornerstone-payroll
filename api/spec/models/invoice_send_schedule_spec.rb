# frozen_string_literal: true

require "rails_helper"

RSpec.describe InvoiceSendSchedule do
  self.use_transactional_tests = false

  it "prevents stale recovery while another database session sends an invoice" do
    lock_id = 987_654_321
    acquired = Queue.new
    release = Queue.new
    sender = Thread.new do
      described_class.with_active_send_lock(lock_id) do
        acquired << true
        release.pop
      end
    end

    acquired.pop
    expect(described_class.transaction { described_class.recovery_lock_available?(lock_id) }).to be(false)

    release << true
    sender.join
    expect(described_class.transaction { described_class.recovery_lock_available?(lock_id) }).to be(true)
  ensure
    release << true if sender&.alive?
    sender&.join
  end
end
