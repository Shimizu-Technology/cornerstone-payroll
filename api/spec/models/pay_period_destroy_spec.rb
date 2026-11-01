# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriod, "deletion", type: :model do
  it "cleans up all revisions of an unapproved source package without allowing direct evidence deletion" do
    period = create(:pay_period, status: "calculated")
    first = create(:payroll_intake_session, pay_period: period, company: period.company, package_revision: 1)
    first.mark_superseded!
    second = create(:payroll_intake_session, pay_period: period, company: period.company, status: "draft", supersedes: first,
      package_revision: 2, supersession_reason: "Corrected synthetic hours")
    document = second.documents.create!(document_type: "pasted_text", text_content: "Synthetic hours")

    expect(document.destroy).to be(false)
    expect(second.destroy).to be(false)
    expect(period.destroy).to be_truthy
    expect(PayrollIntakeSession.where(id: [ first.id, second.id ])).to be_empty
    expect(PayrollIntakeDocument.exists?(document.id)).to be(false)
  end

  it "does not delete a run that was previously committed even if it is labelled draft" do
    period = create(:pay_period)
    period.update_column(:committed_at, Time.current)
    expect(period.destroy).to be(false)
    expect(period.errors.full_messages.to_sentence).to include("never been committed")
  end
end
