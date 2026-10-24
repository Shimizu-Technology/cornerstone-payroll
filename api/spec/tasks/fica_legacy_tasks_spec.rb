# frozen_string_literal: true

require "rails_helper"
require "rake"
require Rails.root.join("lib/fica_legacy_rake_options")

RSpec.describe "Legacy FICA release tasks" do
  it "defaults recovery to a real dry-run, accepts explicit apply and rejects contradictory flags" do
    arguments = [ "payroll:fica_legacy:recover" ]
    FicaLegacyRakeOptions.configure!(arguments)
    expect(arguments).to eq([ "payroll:fica_legacy:recover[dry-run]" ])
    arguments = [ "payroll:fica_legacy:recover", "--apply" ]
    FicaLegacyRakeOptions.configure!(arguments)
    expect(arguments).to eq([ "payroll:fica_legacy:recover[apply]" ])
    arguments = [ "payroll:fica_legacy:recover", "--dry-run" ]
    FicaLegacyRakeOptions.configure!(arguments)
    expect(arguments).to eq([ "payroll:fica_legacy:recover[dry-run]" ])
    expect { FicaLegacyRakeOptions.configure!([ "payroll:fica_legacy:recover", "--apply", "--dry-run" ]) }.to raise_error(ArgumentError)
  end

  it "keeps ordinary rake arguments unchanged" do
    arguments = [ "db:integrity", "--dry-run" ]
    FicaLegacyRakeOptions.configure!(arguments)
    expect(arguments).to eq([ "db:integrity", "--dry-run" ])
  end

  it "runs inventory and default recovery without financial or proof writes" do
    load Rails.root.join("lib/tasks/fica_legacy.rake")
    Rake::Task.define_task(:environment)
    item = create(:payroll_item, pay_period: create(:pay_period, :committed), gross_pay: 1000, social_security_tax: 62)
    before = item.reload.attributes
    %w[payroll:fica_legacy:inventory payroll:fica_legacy:recover].each do |name|
      expect { expect { Rake::Task[name].invoke }.to output(/company_years/).to_stdout }.not_to change(PayrollItemFicaBasisProof, :count)
      expect(item.reload.attributes).to eq(before)
      Rake::Task[name].reenable
    end
  end
end
