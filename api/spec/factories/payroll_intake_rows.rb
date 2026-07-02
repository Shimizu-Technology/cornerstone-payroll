# frozen_string_literal: true

FactoryBot.define do
  factory :payroll_intake_row do
    payroll_intake_session
    employee { association(:employee, company: payroll_intake_session.company) }
    position { 0 }
    status { "ready" }
    source_employee_name { employee&.full_name || "Spike Employee" }
    match_method { "exact" }
    match_confidence { 1.0 }
    confidence { 0.95 }
    week1_hours { 30 }
    week2_hours { 32 }
    regular_hours { 62 }
    overtime_hours { 0 }
    week1_tips { 50.00 }
    week2_tips { 60.00 }
    reported_tips { 110.00 }
    tips_paid_out { 110.00 }
    loan_deduction { 0 }
    warnings { [] }
    validation_errors { [] }
    source_payload { {} }
    staff_overrides { {} }
  end
end
