# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe EmployeeYearFicaSourceReview do
  # Committed identity fixtures let a second connection contend on the real
  # actor row. The review itself remains inside the example's rollback.
  before(:context) do
    @organization = FactoryBot.create(:organization, name: "FICA source review lock #{SecureRandom.hex(6)}")
    @company = FactoryBot.create(:company, organization: @organization)
    @employee = FactoryBot.create(:employee, company: @company)
    @actor = FactoryBot.create(:user, company: @company, role: "admin")
  end

  after(:context) do
    @employee.destroy!
    @actor.destroy!
    @company.destroy!
    @organization.finance_books.each(&:destroy!)
    @organization.delete
  end

  it "keeps the actor locked between final authorization and review insertion" do
    outcomes = Queue.new
    allow(described_class).to receive(:new).and_wrap_original do |method, **attributes|
      config = ApplicationRecord.connection_db_config.configuration_hash
      worker = Thread.new do
        PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
          user: config[:username], password: config[:password]) do |connection|
          connection.exec_params("SELECT id FROM users WHERE id = $1 FOR UPDATE NOWAIT", [ @actor.id ])
          outcomes << :unlocked
        end
      rescue PG::LockNotAvailable => error
        outcomes << error.class
      end
      Timeout.timeout(10) { worker.join }
      expect(outcomes.pop).to eq(PG::LockNotAvailable)
      method.call(**attributes)
    end
    review = described_class.record!(employee: @employee, actor: @actor, tax_year: 2026,
      through_pay_date: Date.new(2026, 12, 31), external_ss_wage_bound: 0, external_medicare_wage_bound: 0,
      review_reference: "Synthetic review with concurrent actor revocation contention")
    expect(review).to be_persisted
  end
end
