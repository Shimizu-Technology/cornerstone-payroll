# frozen_string_literal: true

module MigrationPromotion
  class PreparePaymentIssuance
    ACKNOWLEDGEMENT = "PREPARE PROMOTED PAYROLL FOR PAYMENT"

    def initialize(pay_period:, actor:, acknowledgement: nil, starting_check_number: nil, check_date: nil, ip_address: nil)
      @pay_period = pay_period
      @company = pay_period.company
      @actor = actor
      @acknowledgement = acknowledgement
      @starting_check_number = starting_check_number
      @check_date = check_date
      @ip_address = ip_address
    end

    def preview
      authorize!
      build_summary(blockers: blockers, starting_number: company.next_check_number)
    end

    def call
      authorize!
      raise ArgumentError, "Confirm that this promoted payroll is unpaid" unless acknowledgement == ACKNOWLEDGEMENT

      parsed_check_date = parse_check_date!
      parsed_starting_number = parse_starting_check_number!
      result = nil

      ApplicationRecord.transaction do
        Company.lock.find(company.id)
        pay_period.lock!
        company.reload
        pay_period.reload

        if already_prepared?
          result = build_summary(
            blockers: [],
            starting_number: company.next_check_number,
            reload_items: true
          ).merge(already_prepared: true)
          next
        end

        current_blockers = blockers
        raise ArgumentError, current_blockers.join("; ") if current_blockers.any?

        company.update!(next_check_number: parsed_starting_number)
        payable_items.each { |item| item.update!(check_date: parsed_check_date) }
        company.assign_check_numbers!(payable_items)
        record_assignment_events!

        pay_period.update!(
          promotion_payment_disposition: "process_in_cornerstone",
          promoted_payment_prepared_at: Time.current,
          promoted_payment_prepared_by: actor
        )
        audit_prepared!(parsed_check_date, parsed_starting_number)
        result = build_summary(
          blockers: [],
          starting_number: parsed_starting_number,
          reload_items: true
        ).merge(already_prepared: false)
      end

      result
    end

    private

    attr_reader :pay_period, :company, :actor, :acknowledgement, :starting_check_number, :check_date, :ip_address

    def authorize!
      allowed = actor&.organization_admin? && actor.can_access_company?(company.id) &&
        StaffRolePolicy.allowed?(actor, :manage_organization)
      raise ArgumentError, "An organization administrator with access to this client is required" unless allowed
    end

    def blockers
      issues = []
      issues << "Only a promoted payroll can be prepared this way" if pay_period.promotion_source_pay_period_id.blank?
      issues << "The promoted payroll must be committed" unless pay_period.committed?
      issues << "This promoted payroll is not a record-only payroll" unless pay_period.promotion_payment_disposition == "record_only"
      issues << "This payroll has already been prepared for payment" if pay_period.promoted_payment_prepared_at.present?
      issues << "A voided or correction payroll cannot use this recovery action" if pay_period.voided_at.present? || pay_period.correction_status.present?
      issues << "This payroll already has numbered checks" if pay_period.payroll_items.with_check_number.exists?
      issues << "This payroll already has check activity" if CheckEvent.where(payroll_item_id: pay_period.payroll_item_ids).exists?
      issues << "This payroll already has print activity" if pay_period.payroll_items.where.not(check_printed_at: nil).exists? ||
        pay_period.payroll_items.where("check_print_count > 0").exists?
      issues << "This payroll contains voided checks" if pay_period.payroll_items.where(voided: true).exists?
      issues << "Resolve positive-net direct deposits before preparing paper checks" if direct_deposit_items.any?
      issues << "No positive-net paper checks are available" if payable_items.empty?
      issues.uniq
    end

    def payroll_items
      @payroll_items ||= pay_period.payroll_items.includes(:employee).not_voided.order(:employee_id, :id).to_a
    end

    def payable_items
      @payable_items ||= payroll_items.select do |item|
        item.effective_payment_delivery_method == "paper_check" && item.net_pay.to_d.positive?
      end
    end

    def direct_deposit_items
      @direct_deposit_items ||= payroll_items.select do |item|
        item.effective_payment_delivery_method == "direct_deposit" && item.net_pay.to_d.positive?
      end
    end

    def already_prepared?
      pay_period.promotion_payment_disposition == "process_in_cornerstone" &&
        pay_period.promoted_payment_prepared_at.present? &&
        payable_items.any? && payable_items.all? { |item| item.reload.check_number.present? }
    end

    def parse_check_date!
      value = Date.iso8601(check_date.to_s)
      raise ArgumentError, "Check date cannot be before the payroll period ends" if value < pay_period.end_date

      value
    rescue Date::Error
      raise ArgumentError, "Choose the date that should appear on these checks"
    end

    def parse_starting_check_number!
      value = begin
        Integer(starting_check_number.to_s.strip, 10)
      rescue ArgumentError, TypeError
        raise ArgumentError, "Enter the first physical check number"
      end
      raise ArgumentError, "Starting check number must be greater than 0" if value < 1
      raise ArgumentError, "Starting check number cannot exceed 9,999,999" if value > 9_999_999

      value
    end

    def record_assignment_events!
      assignments = PayrollItem.where(id: payable_items.map(&:id)).where.not(check_number: nil).pluck(:id, :check_number)
      now = Time.current
      CheckEvent.insert_all!(assignments.map do |item_id, number|
        {
          payroll_item_id: item_id,
          user_id: actor.id,
          event_type: "assigned",
          check_number: number,
          reason: "Assigned when an unpaid promoted payroll was prepared for payment",
          ip_address: ip_address,
          effective_on: PayrollBusinessClock.today,
          details: { promotion_recovery: true },
          created_at: now,
          updated_at: now
        }
      end)
    end

    def build_summary(blockers:, starting_number:, reload_items: false)
      assigned_numbers = payable_items.filter_map do |item|
        item.reload if reload_items
        item.check_number.presence
      end
      preview_numbers = assigned_numbers.presence || available_numbers(starting_number, payable_items.length)
      {
        eligible: blockers.empty?,
        blockers: blockers,
        pay_period_id: pay_period.id,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        pay_date: pay_period.pay_date,
        paper_check_count: payable_items.length,
        paper_check_total: payable_items.sum { |item| item.net_pay.to_d },
        direct_deposit_count: direct_deposit_items.length,
        current_next_check_number: company.next_check_number,
        suggested_first_check_number: preview_numbers.first,
        suggested_last_check_number: preview_numbers.last,
        prepared_at: pay_period.promoted_payment_prepared_at,
        prepared_by_name: pay_period.promoted_payment_prepared_by&.name
      }
    end

    def available_numbers(starting_number, count)
      return [] if count.zero?

      candidate = starting_number.to_i
      used = PayrollItem.where(company_id: company.id).where.not(check_number: nil).pluck(:check_number).to_set
      used.merge(NonEmployeeCheck.where(company_id: company.id).where.not(check_number: nil).pluck(:check_number))
      Array.new(count) do
        candidate += 1 while used.include?(candidate.to_s)
        number = candidate.to_s
        used.add(number)
        candidate += 1
        number
      end
    end

    def audit_prepared!(chosen_check_date, requested_starting_number)
      assigned_numbers = PayrollItem.where(id: payable_items.map(&:id)).order(:employee_id, :id).pluck(:check_number)
      AuditLog.record!(
        user: actor,
        organization_id: company.organization_id,
        company_id: company.id,
        action: "migration_promotion#payment_prepared",
        record_type: "pay_periods",
        record_id: pay_period.id,
        subject_name: "#{pay_period.start_date}–#{pay_period.end_date}",
        metadata: {
          promotion_source_pay_period_id: pay_period.promotion_source_pay_period_id,
          check_date: chosen_check_date,
          requested_starting_check_number: requested_starting_number,
          assigned_check_count: assigned_numbers.length,
          assigned_first_check_number: assigned_numbers.first,
          assigned_last_check_number: assigned_numbers.last,
          net_pay: payable_items.sum { |item| item.net_pay.to_d }
        }
      )
    end
  end
end
