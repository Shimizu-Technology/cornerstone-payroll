# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "employees contractor EIN tasks" do
  let(:company) { create(:company) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("employees:encrypt_contractor_eins")
    Rake::Task["employees:encrypt_contractor_eins"].reenable
    Rake::Task["employees:decrypt_contractor_eins"].reenable
  end

  def raw_ein(employee)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql([ "SELECT contractor_ein FROM employees WHERE id = ?", employee.id ])
    )
  end

  it "decrypts for rollback and encrypts again, reporting what remains" do
    employee = create(:employee, :business_contractor, company: company, contractor_ein: "98-1212121")

    expect { Rake::Task["employees:decrypt_contractor_eins"].invoke }
      .to output(%({"decrypted":1,"ciphertext_remaining":0}\n)).to_stdout
    expect(raw_ein(employee)).to eq("98-1212121")

    expect { Rake::Task["employees:encrypt_contractor_eins"].invoke }
      .to output(%({"encrypted":1,"plaintext_remaining":0}\n)).to_stdout
    expect(raw_ein(employee)).not_to include("1212121")
    expect(EncryptedDataReadiness.verify!).to be(true)
  end
end
