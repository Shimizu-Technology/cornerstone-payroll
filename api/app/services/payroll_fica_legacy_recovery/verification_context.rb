# frozen_string_literal: true

class PayrollFicaLegacyRecovery
  # Recovery verifies saved history more exhaustively than the live allocation
  # needs to. Every prefix belongs to the same immutable ledger and rules.
  class VerificationContext < EmployeeYearFicaContext
    def initialize(replay_memo: {}, **inputs)
      super(**inputs)
      @replay_memo = replay_memo
    end

    def verified_basis?(row, rules)
      return false unless row[:recorded_annual_fica_context].is_a?(Hash)
      return false if row.additional_medicare_taxable_wages.nil? && row.additional_medicare_tax.nil?

      FicaBasisEvidence.matches_recorded?(row, recovered_bases(row, rules))
    rescue UnreconciledLedgerError
      false
    end

    def verify_recorded_history!(rules:)
      rows.each do |row|
        # Only missing bases call into ordinary replay and its fingerprint check.
        components = if FicaBasisEvidence::BASE_FIELDS.any? { |field| field != "medicare_taxable_wages" && row.public_send(field).nil? }
          recovered_bases(row, rules)
        else
          bases = FicaBasisEvidence::BASE_FIELDS.to_h { |field| [ field.to_sym, row.public_send(field) ] }
          bases[:medicare_taxable_wages] ||= row.gross_pay
          FicaBasisEvidence.components(bases, rules)
        end
        unless FicaBasisEvidence.matches_recorded?(row, components)
          raise UnreconciledLedgerError, "Payroll item ##{row.id}: recorded FICA bases and taxes do not reconcile."
        end
      end
    end

    private

    def prior_context(prior_rows)
      self.class.new(employee: employee, company: company, year: year, rows: prior_rows,
        opening_balance: opening_balance, replay_memo: @replay_memo)
    end

    def recovered_bases(row, rules)
      result = @replay_memo.fetch(row.id) do
        @replay_memo[row.id] = begin
          super
        rescue UnreconciledLedgerError => error
          error
        end
      end
      raise result if result.is_a?(UnreconciledLedgerError)

      result
    end
  end
end
