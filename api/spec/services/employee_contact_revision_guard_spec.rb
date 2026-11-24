# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactRevisionGuard do
  let(:employee) { create(:employee, job_title: "Cook", phone: "+16715550101") }

  def stale_conflict(submitted_attrs, baseline_values)
    stale_revision = employee.contact_revision
    yield
    described_class.check!(employee: employee.reload, row_revision: stale_revision,
      submitted_attrs: submitted_attrs, baseline_values: baseline_values)
    nil
  rescue described_class::ConflictError => e
    e
  end

  it "includes a conflicting profile field in current_values alongside the contact values" do
    error = stale_conflict({ job_title: "Server" }, { job_title: "Cook" }) do
      employee.update!(job_title: "Shift lead", updated_at: employee.updated_at + 5.seconds)
    end

    expect(error.conflicting_fields).to eq([ "job_title" ])
    expect(error.current_values).to include("job_title" => "Shift lead", "phone" => "+16715550101")
  end

  it "never puts a protected field in current_values, even when it conflicts" do
    error = stale_conflict({ ssn_encrypted: "123-45-6789" }, { ssn_encrypted: employee.ssn_encrypted }) do
      employee.update!(ssn_encrypted: "987-65-4321", updated_at: employee.updated_at + 5.seconds)
    end

    expect(error.conflicting_fields).to eq([ "ssn_encrypted" ])
    expect(error.current_values).not_to have_key("ssn_encrypted")
    expect(error.current_values.values).not_to include("987-65-4321")
  end
end
