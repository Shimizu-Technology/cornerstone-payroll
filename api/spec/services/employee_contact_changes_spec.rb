# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeContactChanges do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, email: "ana@example.com", phone: "+16715550101", city: "Hagatna") }

  def apply(attributes, creation: false, target: employee)
    described_class.new(employee: target, attributes: attributes, company: company, actor: nil, source: "staff", creation: creation).apply!
  end

  it "drops a reformatted but unchanged email and phone on an update and leaves the source alone" do
    attributes = { email: " ANA@example.com ", phone: "671-555-0101" }
    contact = apply(attributes)

    expect(attributes).to eq({})
    expect(contact.validation).to be_nil
    expect(contact.contact_source).to be_nil
  end

  it "validates and normalizes a changed phone and sets the source" do
    attributes = { phone: "555-0199" }
    contact = apply(attributes)

    expect(attributes).to eq(phone: "+16715550199")
    expect(contact.validation).to be_valid
    expect(contact.contact_source).to eq("staff")
  end

  it "sets the source for an address change without running the validator" do
    attributes = { city: "Tamuning" }
    contact = apply(attributes)

    expect(contact.validation).to be_nil
    expect(contact.contact_source).to eq("staff")
  end

  it "saves a cleared email as nil" do
    attributes = { email: "  " }
    apply(attributes)

    expect(attributes).to eq(email: nil)
  end

  it "raises with the errors on the record when a value is invalid" do
    expect { apply({ phone: "123" }) }.to raise_error(EmployeeContactValidator::ValidationError)
    expect(employee.errors[:phone]).to be_present
  end

  it "keeps every given field on a create and sets the source only when one is filled in" do
    blank = Employee.new(company: company)
    expect(apply({ email: "" }, creation: true, target: blank).contact_source).to be_nil
    expect(apply({ email: "new.hire@example.com" }, creation: true, target: blank).contact_source).to eq("staff")
  end
end
