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
  describe "source-completeness batches" do
    let(:company) { create(:company) }
    let(:employees) { create_list(:employee, 2, company: company) }
    let(:actor) { create(:user, company: company, role: "admin") }
    let(:options) do
      { company_id: company.id, employee_ids: employees.map(&:id), actor: actor, tax_year: 2026,
        through_pay_date: Date.new(2026, 12, 31), external_ss_wage_bound: 0,
        external_medicare_wage_bound: 0, review_reference: "Accountant reviewed all outside wages" }
    end

    it "records every selected employee with the shared reviewed bounds" do
      expect { EmployeeYearFicaSourceReview.record_batch!(**options) }.to change(EmployeeYearFicaSourceReview, :count).by(2)
      expect(EmployeeYearFicaSourceReview.where(company: company).pluck(:employee_id)).to match_array(employees.map(&:id))
    end

    it "writes nothing when one selected employee is outside the company" do
      other = create(:employee)
      expect do
        expect { EmployeeYearFicaSourceReview.record_batch!(**options.merge(employee_ids: [ employees.first.id, other.id ])) }
          .to raise_error(ActiveRecord::RecordNotFound)
      end.not_to change(EmployeeYearFicaSourceReview, :count)
    end

    it "rejects an unauthorized administrator" do
      stranger = create(:user, company: create(:company), role: "admin")
      expect do
        expect { EmployeeYearFicaSourceReview.record_batch!(**options.merge(actor: stranger)) }.to raise_error(ArgumentError, /authorized/)
      end.not_to change(EmployeeYearFicaSourceReview, :count)
    end

    it "reloads authorization after acquiring the company lock" do
      employee = employees.first
      allow(Company).to receive(:lock).and_wrap_original do |method, *args|
        actor.update_column(:active, false)
        method.call(*args)
      end
      expect do
        expect { EmployeeYearFicaSourceReview.record!(employee: employee, actor: actor, **options.except(:company_id, :employee_ids, :actor)) }
          .to raise_error(ArgumentError, /authorized/)
      end.not_to change(EmployeeYearFicaSourceReview, :count)
    end

    it "protects saved evidence from callback-bypassing update, delete and truncate" do
      review = EmployeeYearFicaSourceReview.record_batch!(**options).first
      [ -> { review.update_columns(review_reference: "tampered evidence") },
        -> { review.delete },
        -> { ApplicationRecord.connection.execute("TRUNCATE employee_year_fica_source_reviews") } ].each do |mutation|
        expect do
          EmployeeYearFicaSourceReview.transaction(requires_new: true) { mutation.call }
        end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      end
      expect(review.reload.review_reference).to eq(options[:review_reference])
    end

    it "previews both employees by default and with DRY_RUN=1, and applies only explicitly" do
      Rake::Task["payroll:fica_legacy:review_sources"].clear if Rake::Task.task_defined?("payroll:fica_legacy:review_sources")
      load Rails.root.join("lib/tasks/fica_legacy.rake")
      Rake::Task.define_task(:environment)
      values = { "COMPANY_ID" => company.id.to_s, "EMPLOYEE_IDS" => employees.map(&:id).join(","),
        "ACTOR_ID" => actor.id.to_s, "TAX_YEAR" => "2026", "THROUGH_PAY_DATE" => "2026-12-31",
        "EXTERNAL_SS_WAGE_BOUND" => "1234.50", "EXTERNAL_MEDICARE_WAGE_BOUND" => "5678.25",
        "REVIEW_REFERENCE" => options[:review_reference] }
      keys = values.keys + %w[EMPLOYEE_ID APPLY DRY_RUN]
      original = ENV.to_h.slice(*keys)
      keys.each { |key| ENV.delete(key) }
      ENV.update(values)
      task = Rake::Task["payroll:fica_legacy:review_sources"]
      [ nil, "1" ].each do |flag|
        ENV["DRY_RUN"] = flag
        task.reenable
        expect { expect { task.invoke }.to output(/dry-run.*employee_id.*inventory/m).to_stdout }
          .not_to change(EmployeeYearFicaSourceReview, :count)
      end
      ENV.delete("DRY_RUN")
      ENV["APPLY"] = "1"
      task.reenable
      expect { expect { task.invoke }.to output(/apply/).to_stdout }.to change(EmployeeYearFicaSourceReview, :count).by(2)
      saved = EmployeeYearFicaSourceReview.where(company: company).pluck(:external_ss_wage_bound, :external_medicare_wage_bound)
      expect(saved).to all(eq([ BigDecimal("1234.50"), BigDecimal("5678.25") ]))
    ensure
      keys&.each { |key| ENV.delete(key) }
      ENV.update(original || {})
      task&.reenable
    end
  end
end
