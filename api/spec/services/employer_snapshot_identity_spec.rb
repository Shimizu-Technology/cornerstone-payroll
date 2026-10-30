# frozen_string_literal: true

require "rails_helper"
RSpec.describe 'R3 independent saved employer identity conservation' do
  let!(:tax_table) { create(:tax_table) }
  [ 'benefit', 'insurance' ].product([ false, true ]).each do |category, capped|
    it "keeps independent same-label same-value employer #{category} capped=#{capped}" do
      company=create(:company, auto_create_fit_check: false)
      employee=create(:employee, company: company, pay_rate: 15)
      actor=create(:user, company: company, role: 'admin')
      type=DeductionType.create!(company: company, name: 'Independent contribution identity', category: 'employer_contribution', sub_category: category)
      employee.employee_deductions.create!(deduction_type: type, amount: 5, is_percentage: true, active: true)
      definition=create(:payroll_field_definition, company: company, name: 'Independent employer health', kind: 'employer_contribution', tax_treatment: 'employer_contribution', category: category, amount_type: 'percentage', default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: definition)
      period=create(:pay_period, :committed, company: company, start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 1, 14), pay_date: Date.new(2024, 1, 19))
      original=period.payroll_items.build(employee: employee, company: company, employment_type: 'hourly', pay_rate: 15, hours_worked: 60, custom_deductions: capped ? [ { 'label'=>'Cap', 'amount'=>1000 } ] : [])
      PayrollCalculator.for(employee, original).calculate
      # Historical row labels are snapshots, distinct from current definition names.
      original.payroll_item_deductions.find { |r| r.deduction_type_id==type.id }.label='Independent employer health'
      context=original.calculation_context_snapshot.deep_dup
      context.fetch('employee_deductions').find { |r| r.dig('deduction_type', 'id')==type.id }.fetch('deduction_type')['name']='Independent employer health'
      original.calculation_context_snapshot=context
      original.save!
      employee.ytd_totals_for(2024).add_payroll_item!(original)
      CompanyYtdTotal.find_or_create_by!(company: company, year: 2024).add_payroll_item!(original)
      PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
      expected=original.payroll_item_deductions.find_by!(deduction_type: type).amount+original.payroll_item_field_entries.sole.amount
      rows=PayrollLiabilityEntry.where(payroll_item_id: original.id)
      posted=rows.where(category: %w[benefit_employer insurance_employer]).sum(:amount)
      report=QuickbooksPayrollReportData.new(period).employer_contribution_lines_for(original).sum(0.to_d) { |r| r.amount.to_d }
      if defined?(PayrollComponentMirrors)
        expect { PayrollLiabilityPostingService.verify_employer_contributions!(original) }.not_to raise_error
        correction=IssueCorrectivePaycheckService.issue!(original_pay_period: period, employee: employee, corrected_inputs: { hours_worked: 65 }, pay_date: Date.new(2024, 1, 26), reason: 'Review identity', actor: actor).last
        direct_delta=correction.payroll_item_deductions.find_by!(deduction_type: type).amount
        field_delta=correction.payroll_item_field_entries.sole.amount
        correction_posted=PayrollLiabilityEntry.where(payroll_item_id: correction.id, category: %w[benefit_employer insurance_employer]).sum(:amount)
        expect { PayrollLiabilityPostingService.verify_employer_contributions!(correction) }.not_to raise_error
        reversal=IssueCorrectivePaycheckService.issue!(original_pay_period: period, employee: employee, corrected_inputs: { hours_worked: 55 }, pay_date: Date.new(2024, 1, 26), reason: 'Review negative identity', actor: actor).last
        reversal_direct=reversal.payroll_item_deductions.find_by!(deduction_type: type).amount
        reversal_field=reversal.payroll_item_field_entries.sole.amount
        reversal_posted=PayrollLiabilityEntry.where(payroll_item_id: reversal.id, category: %w[benefit_employer insurance_employer]).sum(:amount)
        expect { PayrollLiabilityPostingService.verify_employer_contributions!(reversal) }.not_to raise_error
        expect(correction_posted).to eq(direct_delta+field_delta)
        expect(reversal_posted).to eq(reversal_direct+reversal_field)
        expect(posted+correction_posted+reversal_posted).to eq(expected+direct_delta+field_delta+reversal_direct+reversal_field)
      end
      expect(posted).to eq(expected)
      expect(report).to eq(expected)
    end
  end

  context "authoritative saved sources" do
    include_context "corrective payroll ledger fixtures"

    def identity_item!(category:, capped: false, ambiguous: false)
      type = add_deduction(category: "employer_contribution", sub_category: category)
      field = create(:payroll_field_definition, company: company, name: "Shared employer source", kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: category, amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      item = original!(post_liabilities: false, track_ytd: !ambiguous,
        custom_deductions: capped ? [ { "label" => "Cap", "amount" => 1000 } ] : []) do |built|
        built.payroll_item_deductions.find { |row| row.deduction_type_id == type.id }.label = field.name
        context = built.calculation_context_snapshot.deep_dup
        context.fetch("employee_deductions").find { |row| row.dig("deduction_type", "id") == type.id }.fetch("deduction_type")["name"] = field.name
        if ambiguous
          context["employee_deductions"] = []
          built.payroll_item_field_entries.each { |entry| entry.metadata = entry.metadata.except(PayrollComponentMirrors::IDENTITY_KEY) }
        end
        built.calculation_context_snapshot = context
      end
      [ item, type, field ]
    end

    def employer_postings(item)
      PayrollLiabilityEntry.where(payroll_item_id: item.id, category: %w[benefit_employer insurance_employer]).sum(:amount)
    end

    %w[benefit insurance].product([ false, true ]).each do |category, capped|
      it "holds unproved historical #{category} identity capped=#{capped}" do
        item, = identity_item!(category: category, capped: capped, ambiguous: true)
        frozen = freeze_history(item)
        expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
          .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /mirror identity.*review/)
        expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /mirror identity.*review/)
        expect { issue(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /mirror identity.*review/)
        expect(period.payroll_liability_postings).to be_empty
        expect(period.supplemental_pay_periods).to be_empty
        expect(freeze_history(item.reload)).to eq(frozen)
      end
    end

    it "holds a lone unproved employer source even when the frozen snapshot contains the field" do
      item, type, = identity_item!(category: "benefit", ambiguous: true)
      item.payroll_item_deductions.where.not(deduction_type: type).delete_all
      frozen = freeze_history(item.reload)
      expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
        .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /mirror identity.*review/)
      expect { preview(hours_worked: 65) }.to raise_error(IssueCorrectivePaycheckService::MissingHistoricalContextError, /mirror identity.*review/)
      expect(freeze_history(item.reload)).to eq(frozen)
    end

    it "derives conservation from saved sources independently of report suppression" do
      item, type, field = identity_item!(category: "benefit")
      allow(PayrollComponentMirrors).to receive(:field_for).and_call_original
      allow(PayrollComponentMirrors).to receive(:field_for).with(item, item.payroll_item_deductions.find_by!(deduction_type: type))
        .and_return(item.payroll_item_field_entries.find_by!(payroll_field_definition: field))
      # Inject the same incorrect suppression into the explicit report reader;
      # strict financial source resolution must still preserve both sources.
      report_mirrors = PayrollComponentMirrors.resolution(item, for_reporting: true)
        .merge(type.id => item.payroll_item_field_entries.find_by!(payroll_field_definition: field))
      allow(PayrollComponentMirrors).to receive(:resolution).and_call_original
      allow(PayrollComponentMirrors).to receive(:resolution).with(item, for_reporting: true).and_return(report_mirrors)
      expect(QuickbooksPayrollReportData.new(period).employer_contribution_total(item)).to eq(45)
      expect(PayrollEmployerContributions.total(item)).to eq(90)
      expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
        .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /employer contribution/)
      expect(period.payroll_liability_postings).to be_empty
    end

    it "rejects a posting assigned to the wrong source even when the aggregate agrees" do
      item, type, = identity_item!(category: "benefit")
      allow_any_instance_of(PayrollLiabilityPostingService).to receive(:itemized_liability_rows).and_wrap_original do |method, *args, **kwargs|
        method.call(*args, **kwargs).map do |row|
          row[:component_key] = "deduction_type:wrong-source" if row[:component_key].start_with?("deduction_type:#{type.id}:")
          row
        end
      end
      expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
        .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /employer contribution/)
      expect(employer_postings(item)).to eq(0)
    end

    %w[benefit insurance].product([ false, true ], [ :first, :second ]).each do |category, capped, voided|
      it "preserves each #{category} source through corrections, #{voided} void and retry capped=#{capped}" do
        original, type, field = identity_item!(category: category, capped: capped)
        frozen = freeze_history(original)
        PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
        first = issue(hours_worked: 65)
        second = issue(hours_worked: 55)
        [ [ first, 3.75 ], [ second, -7.50 ] ].each do |item, amount|
          direct = item.payroll_item_deductions.find_by!(deduction_type: type)
          entry = item.payroll_item_field_entries.find_by!(payroll_field_definition: field)
          expected = { "deduction_type:#{type.id}:#{direct.id}" => amount.to_d,
            "payroll_field:#{field.id}:#{entry.id}" => amount.to_d }
          expect(PayrollEmployerContributions.sources(item)).to eq(expected)
          actual = PayrollLiabilityEntry.where(payroll_item_id: item.id, category: %w[benefit_employer insurance_employer])
          expect(actual.to_h { |row| [ row.component_key, row.amount ] }).to eq(expected)
          expect { PayrollLiabilityPostingService.verify_employer_contributions!(item) }.not_to raise_error
        end
        expect([ original, first, second ].sum { |item| employer_postings(item) }).to eq(82.5)
        stale = preview(hours_worked: 60)
        PayPeriodCorrectionService.void!(pay_period: (voided == :first ? first : second).pay_period, actor: actor, reason: "Identity void order")
        expect { issue({ hours_worked: 60 }, digest: stale.dig(:meta, :review_digest)) }.to raise_error(IssueCorrectivePaycheckService::StalePreviewError)
        repair = issue(hours_worked: 60)
        active = [ original, first, second, repair ].select { |item| !item.pay_period.reload.voided? }
        expect(active.sum { |item| PayrollEmployerContributions.total(item.reload) }).to eq(90)
        expect([ original, first, second, repair ].sum { |item| employer_postings(item) }).to eq(90)
        expect(freeze_history(original.reload)).to eq(frozen)
      end
    end

    %w[benefit insurance].product([ false, true ]).each do |category, capped|
      it "keeps owner-scoped same-name employer #{category} fields distinct capped=#{capped}" do
        add_deduction(category: "employer_contribution", sub_category: category)
        [ nil, employee ].each do |owner|
          field = create(:payroll_field_definition, company: company, owner_employee: owner, name: "Scoped employer source",
            kind: "employer_contribution", tax_treatment: "employer_contribution", category: category,
            amount_type: "percentage", default_percentage: 5)
          employee.employee_payroll_fields.create!(payroll_field_definition: field)
        end
        original = original!(custom_deductions: capped ? [ { "label" => "Cap", "amount" => 1000 } ] : [])
        expect(original.payroll_item_deductions.map(&:deduction_type_id).uniq.size).to eq(3)
        expect(PayrollEmployerContributions.sources(original).values).to contain_exactly(45.to_d, 45.to_d, 45.to_d)
        first = issue(hours_worked: 65)
        second = issue(hours_worked: 55)
        expect(PayrollEmployerContributions.sources(first).values).to contain_exactly(3.75.to_d, 3.75.to_d, 3.75.to_d)
        expect(PayrollEmployerContributions.sources(second).values).to contain_exactly(-7.5.to_d, -7.5.to_d, -7.5.to_d)
        [ original, first, second ].each do |item|
          expect { PayrollLiabilityPostingService.verify_employer_contributions!(item) }.not_to raise_error
        end
        expect([ original, first, second ].sum { |item| employer_postings(item) }).to eq(123.75)
      end
    end

    it "holds an unknown same-value built-in match candidate instead of certifying its omission" do
      item = original!(post_liabilities: false, track_ytd: false)
      type = DeductionType.create!(company: company, name: "401(k) Employer Match", category: "employer_contribution",
        sub_category: "retirement", reporting_group: "401k_pre_tax")
      item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: type.category,
        reporting_group: type.reporting_group, amount: 45)
      item.update_columns(employer_retirement_match: 45)
      expect { PayrollEmployerContributions.total(item.reload) }
        .to raise_error(PayrollComponentMirrors::AmbiguousHistoryError, /built-in.*review/)
      expect { PayrollLiabilityPostingService.post!(pay_period: period, actor: actor) }
        .to raise_error(PayrollLiabilityPostingService::InvalidStateError, /built-in.*review/)
      expect(period.payroll_liability_postings).to be_empty
    end

    it "conserves distinct snapshot-only employer fields before they have database IDs" do
      item = original!(post_liabilities: false, track_ytd: false)
      [ [ "Snapshot one", 45 ], [ "Snapshot two", 30 ] ].each do |label, amount|
        item.payroll_item_field_entries.build(label: label, kind: "employer_contribution",
          tax_treatment: "employer_contribution", category: "benefit", amount: amount, source: "manual")
      end
      expect(PayrollEmployerContributions.sources(item).size).to eq(2)
      expect(PayrollEmployerContributions.total(item)).to eq(75)
      item.save!
      PayrollLiabilityPostingService.post!(pay_period: period, actor: actor)
      expect(employer_postings(item)).to eq(75)
      expect { PayrollLiabilityPostingService.verify_employer_contributions!(item) }.not_to raise_error
    end

    it "gives a newly generated field mirror a distinct type even when current names match" do
      type = add_deduction(category: "employer_contribution", sub_category: "benefit")
      type.update!(name: "Shared current name")
      field = create(:payroll_field_definition, company: company, name: type.name, kind: "employer_contribution",
        tax_treatment: "employer_contribution", category: "benefit", amount_type: "percentage", default_percentage: 5)
      employee.employee_payroll_fields.create!(payroll_field_definition: field)
      item = original!
      expect(item.payroll_item_deductions.map(&:deduction_type_id).uniq.size).to eq(2)
      expect(PayrollEmployerContributions.total(item)).to eq(90)
      expect(employer_postings(item)).to eq(90)
    end
  end
end
