# frozen_string_literal: true

module TestWorkspace
  module PayrollCopyVerification
    def self.call(source, target)
      financial_fields = PayrollItem.columns.select { |column| column.type == :decimal }.map(&:name)
      unless source.attributes.slice(*financial_fields) == target.attributes.slice(*financial_fields)
        raise "Test workspace payroll financial verification failed for source item #{source.id}"
      end
    end
  end
end
