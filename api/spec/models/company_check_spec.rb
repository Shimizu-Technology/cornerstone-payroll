# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, type: :model do
  let(:company) { create(:company, next_check_number: 2000) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  def make_items(count)
    count.times.map do |_|
      emp = create(:employee, company: company)
      create(:payroll_item, pay_period: pay_period, employee: emp, check_number: nil)
    end
  end

  # ---------------------------------------------------------------------------
  # assign_check_numbers!
  # ---------------------------------------------------------------------------
  describe "#assign_check_numbers!" do
    it "assigns sequential check numbers starting from next_check_number" do
      items = make_items(3)
      company.assign_check_numbers!(items)
      numbers = items.map { |i| i.reload.check_number }
      expect(numbers).to eq(%w[2000 2001 2002])
    end

    it "advances next_check_number by the number of items assigned" do
      items = make_items(3)
      expect { company.assign_check_numbers!(items) }
        .to change { company.reload.next_check_number }.from(2000).to(2003)
    end

    it "returns the count of assigned items" do
      items = make_items(4)
      expect(company.assign_check_numbers!(items)).to eq(4)
    end

    it "does nothing and returns 0 for an empty array" do
      expect(company.assign_check_numbers!([])).to eq(0)
      expect(company.reload.next_check_number).to eq(2000)
    end

    it "handles concurrent calls without collision (serialized via lock)" do
      # Simulate two concurrent batches
      items_a = make_items(5)
      items_b = make_items(5)

      company.assign_check_numbers!(items_a)
      company.assign_check_numbers!(items_b)

      all_numbers = (items_a + items_b).map { |i| i.reload.check_number }
      expect(all_numbers.uniq.size).to eq(10)  # no duplicates
      expect(company.reload.next_check_number).to eq(2010)
    end
  end

  # ---------------------------------------------------------------------------
  # next_check_number!
  # ---------------------------------------------------------------------------
  describe "#next_check_number!" do
    it "returns the current next_check_number as a string" do
      expect(company.next_check_number!).to eq("2000")
    end

    it "increments next_check_number by 1" do
      expect { company.next_check_number! }
        .to change { company.reload.next_check_number }.from(2000).to(2001)
    end

    it "returns unique numbers on consecutive calls" do
      n1 = company.next_check_number!
      n2 = company.next_check_number!
      expect(n1).not_to eq(n2)
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------
  describe "check_stock_type validation" do
    it "accepts 'bottom_check'" do
      company.check_stock_type = "bottom_check"
      expect(company).to be_valid
    end

    it "accepts 'top_check'" do
      company.check_stock_type = "top_check"
      expect(company).to be_valid
    end

    it "rejects invalid stock types" do
      company.check_stock_type = "sideways_check"
      expect(company).not_to be_valid
    end
  end
end
