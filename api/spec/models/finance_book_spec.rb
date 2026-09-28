# frozen_string_literal: true

require "rails_helper"

RSpec.describe FinanceBook, type: :model do
  it "creates one organization book with a new organization" do
    organization = create(:organization, name: "Shimizu Technology LLC")

    expect(organization.finance_books.count).to eq(1)
    expect(organization.finance_books.first).to have_attributes(
      name: "Shimizu Technology LLC", legal_name: "Shimizu Technology LLC",
      kind: "organization", is_default: true
    )
  end

  it "requires a client book's payroll company to belong to the same organization" do
    organization = create(:organization)
    other_company = create(:company)

    book = organization.finance_books.new(name: "Client books", legal_name: "Client books",
                                          kind: "client", company: other_company)
    expect(book).not_to be_valid
    expect(book.errors[:company]).to include("must belong to the book's organization")
  end
end
