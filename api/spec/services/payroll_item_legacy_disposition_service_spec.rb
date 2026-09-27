# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollItemLegacyDispositionService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:employee) { create(:employee, company: company) }
  let!(:item) do
    create(:payroll_item, company: company, pay_period: period, employee: employee, hours_worked: 0)
  end

  def reviewed_entry
    described_class.preview(company_id: company.id).find { |row| row[:payroll_item_id] == item.id }
      .slice(:payroll_item_id, :evidence_digest)
  end

  it "dispositions a verified empty committed item without changing its payroll record" do
    before_attributes = item.attributes
    disposition = described_class.apply!(company_id: company.id, actor: actor, entries: [ reviewed_entry ]).sole

    expect(disposition.reason).to eq(PayrollItemLegacyDisposition::REASON)
    expect(item.reload.attributes).to eq(before_attributes)
    expect(PayrollItem.reportable).not_to include(item)
    expect(PayrollItem.find(item.id)).to eq(item)
    expect(described_class.apply!(company_id: company.id, actor: actor, entries: [ reviewed_entry ]).sole.id).to eq(disposition.id)
  end

  it "rejects a stale reviewed manifest" do
    manifest = [ reviewed_entry ]
    item.update!(gross_pay: 10)
    expect { described_class.apply!(company_id: company.id, actor: actor, entries: manifest) }
      .to raise_error(described_class::Error, /changed after preview/)
  end

  it "does not disposition a zero-net item with earned wages" do
    item.update!(gross_pay: 100, total_deductions: 100, net_pay: 0)
    expect { described_class.apply!(company_id: company.id, actor: actor, entries: [ reviewed_entry ]) }
      .to raise_error(described_class::Error, /not a committed verified-empty row/)
  end

  it "does not disposition a draft item" do
    manifest = [ reviewed_entry ]
    period.update!(status: "draft", committed_at: nil)
    expect { described_class.apply!(company_id: company.id, actor: actor, entries: manifest) }
      .to raise_error(described_class::Error, /changed after preview|not a committed verified-empty row/)
  end
end
