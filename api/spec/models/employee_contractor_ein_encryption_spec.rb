# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee contractor EIN encryption" do
  let(:company) { create(:company) }

  def raw_ein(employee)
    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql([ "SELECT contractor_ein FROM employees WHERE id = ?", employee.id ])
    )
  end

  def store_plaintext(employee, value)
    ActiveRecord::Encryption.without_encryption { employee.update_column(:contractor_ein, value) }
  end

  # Bypasses normalization, which would otherwise turn a blank into NULL.
  def store_raw(employee, value)
    ActiveRecord::Base.connection.exec_update(
      ActiveRecord::Base.sanitize_sql([ "UPDATE employees SET contractor_ein = ? WHERE id = ?", value, employee.id ])
    )
    expect(raw_ein(employee)).to eq(value)
  end

  it "stores new EINs encrypted and reads them back" do
    employee = create(:employee, :business_contractor, company: company, contractor_ein: "98-7654321")

    expect(raw_ein(employee)).not_to include("7654321")
    expect(employee.encrypted_attribute?(:contractor_ein)).to be(true)
    expect(Employee.find(employee.id).contractor_ein).to eq("98-7654321")
    expect(Employee.find_by(contractor_ein: "98-7654321")).to eq(employee)
  end

  it "stores a blank EIN as nil so missing-EIN checks still work" do
    employee = create(:employee, :business_contractor, company: company)
    employee.update_column(:contractor_ein, " ")

    expect(raw_ein(employee)).to be_nil
  end

  it "keeps reading legacy plaintext EINs during rollout" do
    employee = create(:employee, :business_contractor, company: company)
    store_plaintext(employee, "98-1111111")

    expect(Employee.find(employee.id).contractor_ein).to eq("98-1111111")
  end

  it "has no migration that rewrites EINs while old processes may still be serving" do
    expect(Dir[Rails.root.join("db/migrate/*contractor_ein*")]).to be_empty
  end

  it "encrypts legacy rows, leaves encrypted rows alone, and round-trips through decrypt idempotently" do
    legacy = create(:employee, :business_contractor, company: company)
    store_plaintext(legacy, "98-2222222")
    current = create(:employee, :business_contractor, company: company, contractor_ein: "98-3333333")
    current_ciphertext = raw_ein(current)
    individual = create(:employee, :contractor, company: company, contractor_ein: nil)

    expect(ContractorEinEncryption.backfill!).to eq(1)
    expect(ContractorEinEncryption.backfill!).to eq(0)
    expect(raw_ein(legacy)).not_to include("2222222")
    expect(Employee.find(legacy.id).contractor_ein).to eq("98-2222222")
    expect(raw_ein(current)).to eq(current_ciphertext)
    expect(raw_ein(individual)).to be_nil
    expect(ContractorEinEncryption.plaintext_ids).to be_empty

    expect(ContractorEinEncryption.restore_plaintext!).to eq(2)
    expect(ContractorEinEncryption.restore_plaintext!).to eq(0)
    expect(raw_ein(legacy)).to eq("98-2222222")
    expect(raw_ein(current)).to eq("98-3333333")
    expect(raw_ein(individual)).to be_nil
    expect(ContractorEinEncryption.encrypted_ids).to be_empty
    expect(Employee.find(current.id).contractor_ein).to eq("98-3333333")

    expect(ContractorEinEncryption.backfill!).to eq(2)
    expect(raw_ein(current)).to eq(current_ciphertext)
    expect(Employee.find(legacy.id).contractor_ein).to eq("98-2222222")
  end

  it "sweeps plaintext left by an old process with the rerunnable backfill" do
    straggler = create(:employee, :business_contractor, company: company)
    store_plaintext(straggler, "98-4444444")

    expect(ContractorEinEncryption.plaintext_ids).to eq([ straggler.id ])
    expect(ContractorEinEncryption.backfill!).to eq(1)
    expect(ContractorEinEncryption.backfill!).to eq(0)
    expect(raw_ein(straggler)).not_to include("4444444")
    expect(Employee.find(straggler.id).contractor_ein).to eq("98-4444444")
  end

  it "turns stored blank EINs into NULL so the business contractor still shows as incomplete intake" do
    blank = create(:employee, :business_contractor, company: company)
    blank.update_columns(intake_exception: { "deferred_fields" => [ "contractor_ein" ] })
    store_raw(blank, "")
    padded = create(:employee, :business_contractor, company: company)
    store_raw(padded, " \t")

    expect(ContractorEinEncryption.backfill!).to eq(2)

    expect(raw_ein(blank)).to be_nil
    expect(raw_ein(padded)).to be_nil
    expect(Employee.intake_incomplete).to include(blank)
    expect(ContractorEinEncryption.plaintext_ids).to be_empty
  end

  it "keeps blank EINs NULL through decrypt" do
    blank = create(:employee, :business_contractor, company: company)
    store_raw(blank, "  ")
    present = create(:employee, :business_contractor, company: company, contractor_ein: "98-1313131")

    expect(ContractorEinEncryption.restore_plaintext!).to eq(2)
    expect(raw_ein(blank)).to be_nil
    expect(raw_ein(present)).to eq("98-1313131")
    expect(ContractorEinEncryption.backfill!).to eq(1)
    expect(raw_ein(blank)).to be_nil
  end

  it "does not overwrite an EIN that changed after the backfill read it" do
    employee = create(:employee, :business_contractor, company: company)
    store_plaintext(employee, "98-8888888")
    allow(ContractorEinEncryption).to receive(:stored_eins).and_wrap_original do |original|
      stale = original.call.to_a
      Employee.find(employee.id).update_column(:contractor_ein, "98-9999999")
      stale.each
    end

    expect(ContractorEinEncryption.backfill!).to eq(0)
    expect(Employee.find(employee.id).contractor_ein).to eq("98-9999999")
  end

  it "does not let decrypt overwrite an EIN that changed after it was read" do
    employee = create(:employee, :business_contractor, company: company, contractor_ein: "98-8888888")
    allow(ContractorEinEncryption).to receive(:stored_eins).and_wrap_original do |original|
      stale = original.call.to_a
      Employee.find(employee.id).update!(contractor_ein: "98-9999999")
      stale.each
    end

    expect(ContractorEinEncryption.restore_plaintext!).to eq(0)
    expect(Employee.find(employee.id).contractor_ein).to eq("98-9999999")
    expect(raw_ein(employee)).not_to include("9999999")
  end

  it "fails the encrypted-data readiness gate until no plaintext EIN remains" do
    employee = create(:employee, :business_contractor, company: company)
    store_plaintext(employee, "98-5555555")

    expect { EncryptedDataReadiness.verify! }
      .to raise_error(EncryptedDataReadiness::PlaintextValue, /1 contractor EIN/)

    ContractorEinEncryption.backfill!
    expect(EncryptedDataReadiness.verify!).to be(true)
  end

  it "still flags business contractors with no EIN as incomplete intake" do
    missing = create(:employee, :business_contractor, company: company)
    missing.update_columns(contractor_ein: nil, intake_exception: { "deferred_fields" => [ "contractor_ein" ] })
    present = create(:employee, :business_contractor, company: company, contractor_ein: "98-6666666")
    present.update_columns(intake_exception: { "deferred_fields" => [ "contractor_ein" ] })

    expect(Employee.intake_incomplete).to include(missing)
    expect(Employee.intake_incomplete).not_to include(present)
  end

  it "keeps the full EIN available to staff 1099 preparation" do
    employee = create(:employee, :business_contractor, company: company, contractor_ein: "98-7777777")

    expect(employee.reload.tax_identification_number).to eq("98-7777777")
  end
end
