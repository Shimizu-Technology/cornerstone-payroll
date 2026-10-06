# frozen_string_literal: true

# Setup copies retain evidence history. Promotion appends only each year's
# approved latest evidence, leaving the live audit trail intact. Neither path
# adds the historical rows together: payroll selects one latest record per year.
class EmployeeRetirementYearInputCopier
  MODES = %i[history latest_per_year].freeze

  def self.call(source:, target:, actor:, mode:)
    raise ArgumentError, "Unsupported retirement evidence copy mode" unless MODES.include?(mode)
    unless source.company.organization_id == target.company.organization_id
      raise ArgumentError, "Retirement evidence copies must stay within the same organization"
    end
    unless actor && (actor.super_admin? || actor.organization_id == target.company.organization_id)
      raise ArgumentError, "Retirement evidence copy actor must belong to the target organization"
    end

    entries = source.employee_retirement_year_inputs.order(:created_at, :id).to_a
    unless entries.all? { |input| input.company_id == source.company_id && input.employee_id == source.id }
      raise ArgumentError, "Retirement evidence belongs to a different source company; review the employee transfer before copying"
    end
    entries = entries.group_by(&:tax_year).values.map(&:last) if mode == :latest_per_year
    entries.each do |input|
      attributes = input.attributes.symbolize_keys.slice(*EmployeeRetirementYearInput::SNAPSHOT_ATTRIBUTES)
      if mode == :history
        existing = target.employee_retirement_year_inputs.where(attributes.merge(created_at: input.created_at)).exists?
      else
        latest = target.employee_retirement_year_inputs.where(tax_year: input.tax_year).recent_first.first
        existing = latest && latest.attributes.symbolize_keys.slice(*EmployeeRetirementYearInput::SNAPSHOT_ATTRIBUTES) == attributes
      end
      next if existing

      values = attributes.merge(company: target.company, created_by: actor)
      values[:created_at] = if mode == :history
        input.created_at
      else
        # Retain latest semantics even if a copied record's timestamp is ahead
        # of this server's clock. A tie is resolved by the new record's ID.
        [ Time.current, latest&.created_at ].compact.max
      end
      copy = target.employee_retirement_year_inputs.build(values)
      copy.valid?
      if source.contractor? && target.contractor?
        # Evidence validly recorded while this person was a W-2 employee still
        # belongs in their history after a later classification change.
        copy.errors.delete(:employee, "must be a W-2 employee")
      end
      raise ActiveRecord::RecordInvalid, copy if copy.errors.any?

      copy.save!(validate: false)
    end
  end
end
