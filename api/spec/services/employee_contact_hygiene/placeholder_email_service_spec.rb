# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactHygiene::PlaceholderEmailService do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:actor) { create(:user, company: company, organization: organization, role: "org_admin") }

  def service(email: "shared-inbox@example.com", reason: "Old shared inbox")
    described_class.new(organization: organization, email: email, actor: actor, reason: reason, company: company)
  end

  # Simulates a concurrent request that committed its mark after this
  # request's locked lookup found nothing.
  def miss_locked_lookup
    allow(EmployeePlaceholderEmail).to receive(:lock).and_return(EmployeePlaceholderEmail.none)
  end

  it "returns the existing mark when a concurrent mark wins the uniqueness validation" do
    winner = EmployeePlaceholderEmail.create!(organization: organization, email: "shared-inbox@example.com", reason: "First", marked_by: actor)
    miss_locked_lookup

    result = nil
    expect { result = service.mark! }.not_to change(AuditLog, :count)

    expect(result).to have_attributes(marked: true, changed: false, record: winner, reason: "First")
    expect(EmployeePlaceholderEmail.where(organization: organization).count).to eq(1)
  end

  it "returns the existing mark when a concurrent mark wins at the database constraint" do
    winner = EmployeePlaceholderEmail.create!(organization: organization, email: "shared-inbox@example.com", marked_by: actor)
    miss_locked_lookup
    allow(EmployeePlaceholderEmail).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    expect(service.mark!).to have_attributes(marked: true, changed: false, record: winner)
  end

  it "still raises other validation failures" do
    miss_locked_lookup
    invalid = EmployeePlaceholderEmail.new(organization: organization, email: "shared-inbox@example.com")
    invalid.errors.add(:organization, :blank)
    allow(EmployeePlaceholderEmail).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

    expect { service.mark! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects an oversized reason as a domain error before writing" do
    expect { service(reason: "x" * 501).mark! }.to raise_error(described_class::Error, /500 characters or fewer/)
    expect(EmployeePlaceholderEmail.count).to eq(0)
  end

  it "keeps the mark and unmark history in the audit log after the mark is removed" do
    service.mark!
    service.unmark!

    expect(EmployeePlaceholderEmail.count).to eq(0)
    events = AuditLog.where(organization_id: organization.id, record_type: "employee_placeholder_emails").order(:id)
    expect(events.map(&:action)).to eq(%w[employee_contact_hygiene#mark_placeholder_email employee_contact_hygiene#unmark_placeholder_email])
    expect(events.first.metadata).to include("email" => "shared-inbox@example.com", "reason" => "Old shared inbox")
    expect(events.map(&:user_id).uniq).to eq([ actor.id ])
  end
end
