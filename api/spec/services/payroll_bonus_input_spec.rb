require "rails_helper"

RSpec.describe PayrollBonusInput do
  it "preserves manual zero and the source amount across reimports" do
    item = build(:payroll_item)
    described_class.import!(item, "150.25")
    expect(item.bonus).to eq(150.25)
    described_class.manual!(item, 0)
    described_class.import!(item, 250)
    expect(item.bonus).to eq(0)
    expect(item.imported_bonus).to eq(250)
    expect(item.bonus_source).to eq("manual")
  end

  it "distinguishes absent, changed and explicitly cleared source amounts" do
    item = build(:payroll_item)
    described_class.import!(item, 100)
    described_class.import!(item, nil)
    expect(item.bonus).to eq(100)
    described_class.import!(item, 125)
    expect(item.bonus).to eq(125)
    described_class.import!(item, 0)
    expect(item.bonus).to eq(0)
    expect(item.bonus_source).to eq("mosa_revel")
  end

  it "keeps source control when older clients resubmit an unchanged imported amount" do
    item = build(:payroll_item)
    described_class.import!(item, 150)
    described_class.manual!(item, 150)
    expect(item.bonus_source).to eq("mosa_revel")
    described_class.import!(item, 275)
    expect(item.bonus).to eq(275)
  end

  it "protects a legacy entered bonus without source metadata" do
    item = build(:payroll_item, bonus: 75)
    described_class.import!(item, 125)
    expect(item.bonus).to eq(75)
    expect(item.imported_bonus).to eq(125)
  end

  it "rejects invalid money instead of silently clearing it" do
    [ nil, "", "abc", -1, "NaN", "Infinity", "100000000" ].each do |invalid|
      expect { described_class.manual!(build(:payroll_item), invalid) }.to raise_error(ArgumentError)
    end
  end
end
