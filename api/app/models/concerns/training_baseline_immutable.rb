# frozen_string_literal: true

module TrainingBaselineImmutable
  extend ActiveSupport::Concern

  included do
    before_create :prevent_ready_training_baseline_mutation
    before_update :prevent_training_baseline_mutation
    before_destroy :prevent_training_baseline_mutation
  end

  private

  def training_baseline_pay_period
    respond_to?(:pay_period) ? pay_period : payroll_item&.pay_period
  end

  def prevent_ready_training_baseline_mutation
    return unless training_baseline_pay_period&.training_baseline?
    return unless training_baseline_pay_period.company.test_workspace_ready?

    reject_training_baseline_mutation
  end

  def prevent_training_baseline_mutation
    return unless training_baseline_pay_period&.training_baseline?

    reject_training_baseline_mutation
  end

  def reject_training_baseline_mutation
    errors.add(:base, "Copied payroll history is locked reference evidence")
    throw :abort
  end
end
