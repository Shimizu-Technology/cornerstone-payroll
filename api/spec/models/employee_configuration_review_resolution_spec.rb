# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeConfigurationReviewResolution, type: :model do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company:) }
  let(:reviewer) { create(:user, company:, organization: company.organization, role: "accountant") }
  let(:attributes) do
    {
      company:,
      employee:,
      item_code: "verify_hire_date",
      item_message: "Confirm the effective hire date.",
      item_fields: [ "hire_date" ],
      resolution_note: "Confirmed against the signed personnel record.",
      reviewed_by: reviewer,
      reviewed_by_name: reviewer.name,
      reviewed_by_email: reviewer.email,
      reviewed_by_role: reviewer.role,
      reviewed_at: Time.current
    }
  end

  it "requires the employee to belong to the recorded company" do
    other_company = create(:company)
    resolution = described_class.new(attributes.merge(company: other_company))

    expect(resolution).not_to be_valid
    expect(resolution.errors[:employee]).to include("must belong to the reviewed company")
  end

  it "requires durable review metadata" do
    resolution = described_class.new(attributes.merge(reviewed_by_name: nil, resolution_note: nil))

    expect(resolution).not_to be_valid
    expect(resolution.errors[:reviewed_by_name]).to include("can't be blank")
    expect(resolution.errors[:resolution_note]).to include("can't be blank")
  end

  it "does not allow the same employee item to be resolved twice" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:item_code]).to include("has already been taken")
  end

  it "cannot be destroyed after it is recorded" do
    resolution = described_class.create!(attributes)

    expect { resolution.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(resolution.errors[:base]).to include("Employee setup review resolutions are permanent")
  end
end
