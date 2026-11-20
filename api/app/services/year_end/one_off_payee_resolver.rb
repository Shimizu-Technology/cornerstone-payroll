# frozen_string_literal: true

module YearEnd
  # Resolves a one-off 1099 payee by linking its checks to a contractor
  # record: an existing contractor, or a new one made from the payee's W-9.
  # Linked checks count toward that contractor's single 1099-NEC, so one
  # payee never gets two 1099s from one payer for a year. (The other way to
  # resolve a payee, "no 1099 is due", is an acknowledgement:
  # AcknowledgementRecorder.)
  #
  # Every change runs under the company lock, which "mark 1099s ready" also
  # takes, and is refused when the payee's checks changed since the reviewer
  # saw them (the digest). Each linked or unlinked check gets an edit-history
  # row and the whole change one audit entry. No TIN is ever written to the
  # audit log: only its type and last four digits.
  class OneOffPayeeResolver
    class StalePayee < StandardError; end
    class Refused < StandardError; end

    CONTRACTOR_FIELDS = %i[contractor_type first_name middle_name last_name name_suffix business_name tin
                           address_line1 address_line2 city state zip w9_on_file].freeze

    def initialize(company:, actor:, tax_year:)
      @company = company
      @actor = actor
      @tax_year = Integer(tax_year)
    end

    # Links the payee's checks to an existing contractor of this client.
    def link!(payee_code:, payee_digest:, employee_id:)
      within_lock do
        payee = current_payee!(payee_code, payee_digest)
        employee = company.employees.contractor.find_by(id: employee_id)
        raise Refused, "Choose a contractor of #{company.name}." unless employee

        checks = link_checks!(payee, employee)
        audit!("year_end_one_off_payees#linked", employee, payee, checks, created: false)
        { employee: employee, checks: checks }
      end
    end

    # Makes a contractor record from the payee's W-9 and links the checks to
    # it. The record is inactive, so it never joins a payroll run; it holds
    # the TIN and address the 1099 prints.
    def create_contractor!(payee_code:, payee_digest:, attributes:)
      within_lock do
        payee = current_payee!(payee_code, payee_digest)
        employee = build_contractor(payee, attributes.to_h.symbolize_keys.slice(*CONTRACTOR_FIELDS))
        duplicate = duplicate_tin_contractor(employee)
        if duplicate
          raise Refused, "#{duplicate.full_name} already has this TIN. Link the checks to #{duplicate.full_name} instead, so they get one 1099."
        end

        employee.save!
        checks = link_checks!(payee, employee)
        audit!("year_end_one_off_payees#contractor_created", employee, payee, checks, created: true)
        { employee: employee, checks: checks }
      end
    end

    # Undoes links made by mistake. The checks become a one-off payee again.
    # employee_id is the contractor the reviewer saw them linked to: if any
    # check is no longer linked to that contractor (unlinked, or relinked to
    # someone else since), nothing is cleared.
    def unlink!(check_ids:, employee_id:)
      within_lock do
        ids = Array(check_ids).map { |id| Integer(id, exception: false) }
        raise Refused, "Choose the checks to unlink." if ids.empty? || ids.any?(&:nil?)

        expected = Integer(employee_id.to_s, exception: false)
        raise Refused, "Choose the contractor the checks are linked to." unless expected

        checks = NonEmployeeCheck.lock.where(company_id: company.id, id: ids).order(:id).to_a
        unless checks.length == ids.uniq.length && checks.all? { |check| check.payee_employee_id == expected }
          raise StalePayee, "These checks are no longer linked to that contractor. Reload the checklist."
        end

        previous = checks.to_h { |check| [ check.id, check.payee_employee_id ] }
        employees = company.employees.where(id: previous.values).index_by(&:id)
        checks.each { |check| set_link!(check, nil) }
        AuditLog.record!(
          user: actor, organization_id: company.organization_id, company_id: company.id,
          action: "year_end_one_off_payees#unlinked", record_type: "non_employee_checks", record_id: checks.first.id,
          subject_name: "#{company.name} #{tax_year} 1099: unlinked #{checks.length} one-off check#{'s' unless checks.one?}",
          metadata: {
            tax_year: tax_year,
            checks: checks.map do |check|
              check_summary(check).merge(previous_employee_id: previous[check.id], previous_employee_name: employees[previous[check.id]]&.full_name)
            end
          }
        )
        { checks: checks }
      end
    end

    private

    attr_reader :company, :actor, :tax_year

    def within_lock
      PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
      NonEmployeeCheck.transaction do
        company.lock!
        @actor = User.lock.find_by(id: actor&.id)
        PayrollFilingResponsibilityPolicy.authorize_record!(actor: actor, company: company)
        yield
      end
    end

    # The payee as the checklist shows it now. Its digest binds the decision
    # to the exact checks and amounts the reviewer saw. Any unlinked payee can
    # be resolved, below the threshold too: the threshold applies to the
    # contractor's total after the checks are linked.
    def current_payee!(code, digest)
      raise Refused, "Unknown payee" unless OneOffPayees.code?(code)

      report = Form1099NecAggregator.new(company, tax_year).generate
      rows = Array(report[:all_contractors]).select { |row| row[:employee_id].nil? && row[:payee_key].present? }
      row = rows.find { |candidate| OneOffPayees.code_for(candidate[:payee_key]) == code.to_s }
      raise StalePayee, "This payee is no longer on the list. Reload the checklist." unless row

      checks = NonEmployeeCheck.lock.where(company_id: company.id, id: row[:non_employee_check_ids]).includes(:pay_period).order(:id).to_a
      current = OneOffPayees.digest_for(code, checks: checks, name: row[:name])
      raise StalePayee, "This payee's checks changed. Reload the checklist and check them again." unless current == digest.to_s

      { code: code.to_s, name: row[:name], checks: checks }
    end

    def link_checks!(payee, employee)
      payee[:checks].each do |check|
        raise StalePayee, "Check #{check.check_number || check.id} is already linked. Reload the checklist." if check.payee_employee_id

        set_link!(check, employee)
      end
      payee[:checks]
    end

    # Only the link changes, so validations unrelated to it never block a
    # check that was issued long ago; the link itself is checked here and by
    # the database's same-company key.
    def set_link!(check, employee)
      if employee
        raise Refused, "Only contractor checks can be linked." unless check.check_type == "contractor"
        raise Refused, "Choose a contractor of #{company.name}." unless employee.company_id == company.id && employee.contractor?
      end
      before = check.payee_employee_id
      check.update_columns(payee_employee_id: employee&.id, updated_at: Time.current)
      check.edits.create!(
        edited_by: actor,
        before: { "payee_employee_id" => before },
        after: { "payee_employee_id" => employee&.id },
        changed_fields: [ "payee_employee_id" ],
        reason: employee ? "Linked to #{employee.full_name} for the #{tax_year} 1099-NEC" : "Unlinked from the #{tax_year} 1099-NEC contractor"
      )
    end

    def build_contractor(payee, attributes)
      business = attributes[:contractor_type].to_s == "business"
      tin = attributes[:tin].to_s.gsub(/\D/, "")
      raise Refused, business ? "Enter the 9-digit EIN from the W-9." : "Enter the 9-digit SSN from the W-9." unless tin.length == 9

      first_paid = payee[:checks].filter_map(&:effective_payment_date).min || Date.new(tax_year, 1, 1)
      company.employees.new(
        employment_type: "contractor",
        contractor_type: business ? "business" : "individual",
        contractor_pay_type: "flat_fee",
        first_name: attributes[:first_name].to_s.strip,
        middle_name: attributes[:middle_name].to_s.strip.presence,
        last_name: attributes[:last_name].to_s.strip,
        name_suffix: attributes[:name_suffix].to_s.strip.presence,
        business_name: attributes[:business_name].to_s.strip.presence,
        ssn_encrypted: (business ? nil : "#{tin[0, 3]}-#{tin[3, 2]}-#{tin[5, 4]}"),
        contractor_ein: (business ? "#{tin[0, 2]}-#{tin[2, 7]}" : nil),
        address_line1: attributes[:address_line1].to_s.strip,
        address_line2: attributes[:address_line2].to_s.strip.presence,
        city: attributes[:city].to_s.strip,
        state: attributes[:state].to_s.strip.upcase,
        zip: attributes[:zip].to_s.strip,
        w9_on_file: ActiveModel::Type::Boolean.new.cast(attributes[:w9_on_file]) == true,
        pay_rate: 0,
        hire_date: first_paid,
        status: "inactive",
        created_by: actor
      )
    end

    # Another contractor record of this client with the same TIN would get
    # its own 1099. The SSN and EIN are compared as digits.
    def duplicate_tin_contractor(employee)
      tin = employee.form_1099_tin
      return unless tin

      company.employees.contractor.where.not(id: employee.id).find { |other| other.form_1099_tin == tin }
    end

    def audit!(action, employee, payee, checks, created:)
      tin = employee.form_1099_tin
      AuditLog.record!(
        user: actor, organization_id: company.organization_id, company_id: company.id,
        action: action, record_type: "employees", record_id: employee.id,
        subject_name: "#{company.name} #{tax_year} 1099: #{payee[:name]} → #{employee.full_name}",
        metadata: {
          tax_year: tax_year,
          payee_code: payee[:code],
          payee_name: payee[:name],
          employee_id: employee.id,
          employee_name: employee.full_name,
          contractor_created: created,
          tin_type: tin&.dig(:type),
          tin_last4: tin&.dig(:digits)&.last(4),
          checks: checks.map { |check| check_summary(check) },
          total: OneOffPayees.money(checks.sum(0.to_d) { |check| check.amount.to_d })
        }
      )
    end

    def check_summary(check)
      { id: check.id, check_number: check.check_number, payable_to: check.payable_to, amount: OneOffPayees.money(check.amount) }
    end
  end
end
