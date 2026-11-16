# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSubmissions::StandingChanges do
  let(:company) { create(:company) }
  let(:owner) { create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0) }
  let!(:default) { PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay", required: true) }

  it "shows only previous locked payroll as a hint and never an amount field" do
    previous = create(:pay_period, :committed, company: company, pay_date: "2026-10-22")
    create(:payroll_item, company: company, employee: owner, pay_period: previous, salary_override: 4500.00)
    newer = create(:pay_period, company: company, pay_date: "2026-11-02")
    create(:payroll_item, company: company, employee: owner, pay_period: newer, salary_override: 9999)
    row = described_class.new(company: company, before_pay_date: Date.new(2026, 11, 5)).rows.sole
    expect(row).to include(last_period_amount: "4500.00", standing_change_id: default.id, employee_id: owner.id)
    expect(row).not_to have_key(:amount)
    expect(described_class.new(company: company, before_pay_date: Date.new(2026, 10, 1)).rows.sole).not_to have_key(:last_period_amount)
  end

  it "validates every default is answered, stores skips, and rejects foreign references" do
    normalizer = PayrollSubmissions::ChangeRows
    expect { normalizer.normalize!([], company_id: company.id) }.to raise_error(normalizer::Invalid, /Every period defaults changed/)
    row = { kind: "owner_pay", standing_change_id: default.id, employee_id: owner.id, skipped: true }
    expect(normalizer.normalize!([ row ], company_id: company.id).sole).to include("skipped" => true, "standing_change_id" => default.id)
    expect { normalizer.normalize!([ row.merge(employee_id: create(:employee).id) ], company_id: company.id) }.to raise_error(normalizer::Invalid)
    expect { normalizer.normalize!([ row.merge(skipped: false, amount: "4500.001") ], company_id: company.id) }.to raise_error(normalizer::Invalid)
  end

  it "requires a per-person owner and one row per person, with exact decimal amounts" do
    row = { kind: "owner_pay", standing_change_id: default.id, employee_id: owner.id, amount: "4500.00" }
    expect(PayrollSubmissions::ChangeRows.normalize!([ row ], company_id: company.id).sole).to include("amount" => "4500.00")
    expect { PayrollSubmissions::ChangeRows.normalize!([ row, row ], company_id: company.id) }.to raise_error(PayrollSubmissions::ChangeRows::Invalid, /one owner-pay/)
    expect { PayrollSubmissions::ChangeRows.normalize!([ { kind: "owner_pay", amount: "100", basis: "each" } ], company_id: company.id) }.to raise_error(PayrollSubmissions::ChangeRows::Invalid)
  end

  it "explains inactive defaults and allows explicit skips without changing the defaults" do
    owner.update!(status: "inactive")
    row = { kind: "owner_pay", standing_change_id: default.id, employee_id: owner.id, amount: "1" }
    expect(described_class.new(company: company, before_pay_date: Date.current).rows.sole[:availability_error]).to include("inactive")
    expect { PayrollSubmissions::ChangeRows.normalize!([ row ], company_id: company.id) }.to raise_error(PayrollSubmissions::ChangeRows::Invalid)
    expect(PayrollSubmissions::ChangeRows.normalize!([ row.merge(skipped: true) ], company_id: company.id).sole["skipped"]).to be(true)
    expect(default.reload).to be_active
  end
end

RSpec.describe 'Configured portal entry answers' do
  let(:company) { create(:company) }
  let(:owner) { create(:employee, :salary, company: company, salary_type: 'variable', pay_rate: 0) }
  let!(:field) { PayrollStandingChange.create!(company: company, employee: owner, kind: 'owner_pay', label: 'Period pay', required: true, allow_none: false) }
  let(:row) { { kind: 'owner_pay', employee_id: owner.id, standing_change_id: field.id } }

  it 'requires values, rejects prohibited none, and snapshots the configured label' do
    expect { PayrollSubmissions::ChangeRows.normalize!([], company_id: company.id) }.to raise_error(PayrollSubmissions::ChangeRows::Invalid)
    expect { PayrollSubmissions::ChangeRows.normalize!([ row.merge(skipped: true) ], company_id: company.id) }.to raise_error(PayrollSubmissions::ChangeRows::Invalid, /not allowed/)
    expect(PayrollSubmissions::ChangeRows.normalize!([ row.merge(amount: '1200') ], company_id: company.id).sole).to include('label' => 'Period pay', 'amount' => '1200.00')
  end

  it 'does not block sending when a required mapped employee is unavailable' do
    owner.update!(status: 'inactive')
    expect(PayrollSubmissions::ChangeRows.normalize!([], company_id: company.id)).to eq([])
  end
end
