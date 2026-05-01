# frozen_string_literal: true

module Api
  module V1
    module Admin
      class NonEmployeeChecksController < BaseController
        # Fields that are user-editable AND that we audit changes to. We
        # intentionally exclude things like printed_at / voided_at / print_count
        # which are managed by their own lifecycle methods.
        AUDITED_FIELDS = %w[
          payable_to amount check_type memo description
          reference_number check_number payment_period_type
          tax_year tax_quarter tax_month due_date payment_date
          confirmation_number line_items
        ].freeze

        before_action :set_check, only: [:show, :update, :destroy, :mark_printed, :void_check, :check_pdf, :voucher_pdf, :history]

        # GET /api/v1/admin/non_employee_checks
        def index
          # Don't include `:edits` here — the index payload only needs
          # the *count* of edits per check, not the rows themselves, and
          # eager-loading them would pull every audit JSONB row into
          # memory just to call `.size` on the array. Instead, fetch
          # only an `id → count` map in a single grouped query, then pass
          # those counts into `check_payload` via `edit_count:`.
          checks = NonEmployeeCheck.where(company_id: current_company_id)
            .includes(:pay_period, :created_by, :line_items)

          checks = checks.where(pay_period_id: params[:pay_period_id]) if params[:pay_period_id].present?
          checks = checks.standalone if params[:standalone] == "true"
          checks = checks.where(check_type: params[:check_type]) if params[:check_type].present?
          checks = checks.where(payment_period_type: params[:payment_period_type]) if params[:payment_period_type].present?
          checks = checks.where(tax_year: params[:tax_year]) if params[:tax_year].present?
          checks = checks.where(tax_quarter: params[:tax_quarter]) if params[:tax_quarter].present?
          checks = checks.where(tax_month: params[:tax_month]) if params[:tax_month].present?
          checks = checks.where("COALESCE(payment_date, DATE(created_at)) >= ?", filter_date_param(:from)) if params[:from].present?
          checks = checks.where("COALESCE(payment_date, DATE(created_at)) <= ?", filter_date_param(:to)) if params[:to].present?
          checks = checks.active if params[:active] == "true"

          checks = checks.order(Arel.sql("COALESCE(payment_date, DATE(created_at)) DESC"), created_at: :desc).to_a

          edit_counts = NonEmployeeCheckEdit
            .where(non_employee_check_id: checks.map(&:id))
            .group(:non_employee_check_id)
            .count

          render json: {
            non_employee_checks: checks.map { |c|
              check_payload(c, edit_count: edit_counts[c.id] || 0)
            }
          }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/non_employee_checks/:id
        def show
          render json: { non_employee_check: check_payload(@check) }
        end

        # POST /api/v1/admin/non_employee_checks
        def create
          attrs = check_params.to_h
          pay_period_id = attrs["pay_period_id"] || attrs[:pay_period_id]
          pay_period = resolve_pay_period(pay_period_id) if pay_period_id.present?
          return if pay_period_id.present? && pay_period.nil?

          check = NonEmployeeCheck.new(attrs.except("pay_period_id", :pay_period_id))
          check.company_id = current_company_id
          check.created_by = current_user
          if pay_period
            check.pay_period = pay_period
            check.payment_period_type = "pay_period"
          end

          created = false
          ActiveRecord::Base.transaction do
            check.company.lock!
            validate_check_number_assignment!(check_number_value(attrs), excluding_non_employee_check_id: nil)
            created = check.save
            advance_next_check_number!(check.company, check.check_number) if created
            raise ActiveRecord::Rollback unless created
          end

          if created
            render json: { non_employee_check: check_payload(check) }, status: :created
          else
            render json: { errors: check.errors.full_messages }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Check number is already in use for this company" }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/non_employee_checks/:id
        def update
          if @check.voided?
            return render json: { error: "Cannot update a voided check" }, status: :unprocessable_entity
          end

          attrs = check_params.to_h
          if attrs.key?("pay_period_id") || attrs.key?(:pay_period_id)
            pay_period_id = attrs["pay_period_id"] || attrs[:pay_period_id]
            pay_period = resolve_pay_period(pay_period_id) if pay_period_id.present?
            return if pay_period_id.present? && pay_period.nil?

            attrs["pay_period_id"] = pay_period&.id
            attrs["payment_period_type"] = if pay_period
              "pay_period"
            else
              attrs["payment_period_type"].presence || "none"
            end
          end

          # Snapshot the audited fields before we touch the record so the audit
          # log can capture an accurate before/after diff.
          before_snapshot = audit_snapshot(@check)
          reason = params[:reason].presence

          # Track success inside the transaction rather than `return`-ing out of
          # the block — non-local return inside ActiveRecord::Base.transaction
          # works but obscures the rollback semantics and trips up readers
          # (and static analysis). We do all the writes atomically and then
          # render based on the outcome once we're back at the controller scope.
          updated = false
          ActiveRecord::Base.transaction do
            if attrs.key?("check_number")
              @check.company.lock!
              @check.lock!
              validate_check_number_assignment!(
                check_number_value(attrs),
                excluding_non_employee_check_id: @check.id
              )
            end

            if @check.update(attrs)
              @check.line_items.reload if attrs.key?("line_items_attributes")
              after_snapshot = audit_snapshot(@check)
              changed = changed_fields(before_snapshot, after_snapshot)

              if changed.any?
                @check.edits.create!(
                  edited_by: current_user,
                  before: before_snapshot.slice(*changed),
                  after: after_snapshot.slice(*changed),
                  changed_fields: changed,
                  reason: reason
                )
              end

              if changed.include?("check_number")
                advance_next_check_number!(@check.company, @check.check_number)
                sync_transmittal_check_number!(@check)
              end

              updated = true
            else
              raise ActiveRecord::Rollback
            end
          end

          unless updated
            return render json: { errors: @check.errors.full_messages }, status: :unprocessable_entity
          end

          # Reset the edits association so the freshly-created edit (or no-op)
          # is reflected in `edit_count` without issuing a second COUNT query.
          @check.edits.reset
          render json: { non_employee_check: check_payload(@check) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Check number is already in use for this company" }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/non_employee_checks/:id/history
        def history
          edits = @check.edits.includes(:edited_by)
          render json: {
            history: edits.map { |edit| edit_payload(edit) }
          }
        end

        # DELETE /api/v1/admin/non_employee_checks/:id
        def destroy
          if @check.printed?
            return render json: { error: "Cannot delete a printed check; void it instead" }, status: :unprocessable_entity
          end

          @check.destroy!
          render json: { message: "Non-employee check deleted" }
        end

        # POST /api/v1/admin/non_employee_checks/:id/mark_printed
        def mark_printed
          @check.mark_printed!
          render json: { non_employee_check: check_payload(@check.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/non_employee_checks/:id/void_check
        def void_check
          reason = params[:reason]
          @check.void!(reason: reason)
          render json: { non_employee_check: check_payload(@check.reload) }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/non_employee_checks/:id/check_pdf
        def check_pdf
          if @check.company.first_hawaiian_4up_checks?
            generator = FirstHawaiianFourUpCheckGenerator.new(
              company: @check.company,
              non_employee_checks: [@check],
              starting_slot: params[:starting_slot]
            )
            pdf_data = generator.generate
            filename = "fhb_ne_check_#{@check.check_number || @check.id}.pdf"
          else
            generator = NonEmployeeCheckGenerator.new(@check)
            pdf_data  = @check.voided? ? generator.generate_voided : generator.generate
            filename = generator.filename
          end

          send_data pdf_data,
            type: "application/pdf",
            disposition: "inline",
            filename: filename
        end

        # GET /api/v1/admin/non_employee_checks/:id/voucher_pdf
        def voucher_pdf
          generator = NonEmployeeCheckVoucherGenerator.new(@check)
          send_data generator.generate,
            type: "application/pdf",
            disposition: "inline",
            filename: generator.filename
        end

        private

        def set_check
          # Preload :edits so check_payload's `edit_count: check.edits.size`
          # uses the loaded association instead of issuing a per-request COUNT.
          @check = NonEmployeeCheck
            .includes(:edits, :line_items, :pay_period)
            .find_by(id: params[:id], company_id: current_company_id)
          return if @check

          render json: { error: "Check not found" }, status: :not_found
        end

        def check_params
          permitted = params.require(:non_employee_check).permit(
            :pay_period_id, :payable_to, :amount, :check_type,
            :memo, :description, :reference_number, :check_number,
            :payment_period_type, :tax_year, :tax_quarter, :tax_month,
            :due_date, :payment_date, :confirmation_number,
            line_items_attributes: [
              :id, :description, :reference_number, :service_period,
              :amount, :position, :_destroy
            ]
          )

          # Coerce blank values to nil for all optional text fields. The Edit
          # modal always sends the full payload, so untouched-and-unset
          # fields arrive as "" rather than being omitted. Two reasons this
          # matters:
          #
          # 1. `check_number` — Postgres treats "" as NOT NULL, so the
          #    partial unique index `WHERE check_number IS NOT NULL` fires
          #    on the *second* check in the same company saved through the
          #    modal — even for an unrelated edit — raising
          #    `ActiveRecord::RecordNotUnique` → 500. Normalising to nil
          #    matches the partial index and the model-level `allow_nil`.
          #
          # 2. `memo` / `description` / `reference_number` — without
          #    coercion, a DB row with a true `nil` value gets overwritten
          #    with `""` on a no-op edit, causing `audit_snapshot` to
          #    diff `nil → ""` and create a spurious audit entry for a
          #    field the operator never touched.
          BLANKABLE_TEXT_FIELDS.each do |field|
            permitted[field] = nil if permitted.key?(field) && permitted[field].blank?
          end

          permitted
        end

        # Optional text fields whose blank ("" or whitespace-only) values
        # should be stored as NULL. Centralised so `check_params` and
        # `audit_snapshot` agree on the normalisation.
        BLANKABLE_TEXT_FIELDS = %i[
          check_number memo description reference_number confirmation_number
        ].freeze

        def filter_date_param(name)
          Date.iso8601(params[name])
        rescue ArgumentError
          raise ArgumentError, "#{name} must be an ISO-8601 date"
        end

        def resolve_pay_period(pay_period_id)
          pay_period = PayPeriod.find_by(id: pay_period_id, company_id: current_company_id)
          return pay_period if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
          nil
        end

        def check_payload(check, edit_count: nil)
          {
            id: check.id,
            pay_period_id: check.pay_period_id,
            company_id: check.company_id,
            check_number: check.check_number,
            payable_to: check.payable_to,
            amount: check.amount,
            check_type: check.check_type,
            auto_generated_type: check.auto_generated_type,
            memo: check.memo,
            description: check.description,
            reference_number: check.reference_number,
            payment_period_type: check.payment_period_type,
            tax_year: check.tax_year,
            tax_quarter: check.tax_quarter,
            tax_month: check.tax_month,
            due_date: check.due_date,
            payment_date: check.payment_date,
            confirmation_number: check.confirmation_number,
            line_items: check.line_items.map { |line_item| line_item_payload(line_item) },
            print_count: check.print_count,
            printed_at: check.printed_at,
            voided: check.voided,
            void_reason: check.void_reason,
            voided_at: check.voided_at,
            check_status: check.check_status,
            edit_count: edit_count_for(check, override: edit_count),
            created_by_id: check.created_by_id,
            created_at: check.created_at,
            updated_at: check.updated_at
          }
        end

        def check_number_value(attrs)
          attrs["check_number"] || attrs[:check_number]
        end

        def validate_check_number_assignment!(check_number, excluding_non_employee_check_id:)
          return if check_number.blank?

          normalized = check_number.to_s
          raise ArgumentError, "Check number must be numeric" unless normalized.match?(/\A\d+\z/)
          raise ArgumentError, "Check number must be greater than 0" if normalized.to_i < 1
          raise ArgumentError, "Check number cannot exceed 9,999,999" if normalized.to_i > 9_999_999

          if PayrollItem.where(company_id: current_company_id, check_number: normalized).exists?
            raise ArgumentError, "Check number #{normalized} is already used by a payroll check"
          end

          duplicate_scope = NonEmployeeCheck.where(company_id: current_company_id, check_number: normalized)
          duplicate_scope = duplicate_scope.where.not(id: excluding_non_employee_check_id) if excluding_non_employee_check_id
          return unless duplicate_scope.exists?

          raise ArgumentError, "Check number #{normalized} is already used by another non-employee check"
        end

        def advance_next_check_number!(company, check_number)
          return if check_number.blank?

          next_number = check_number.to_i + 1
          company.update!(next_check_number: next_number) if next_number > company.next_check_number
        end

        def sync_transmittal_check_number!(check)
          return unless check.pay_period

          transmittal = check.pay_period.transmittal
          return unless transmittal

          numbers = (transmittal.non_employee_check_numbers || {}).stringify_keys
          if check.check_number.present?
            numbers[check.id.to_s] = check.check_number
          else
            numbers.delete(check.id.to_s)
          end

          transmittal.update!(non_employee_check_numbers: numbers)
        end

        # Resolves `edit_count` without re-querying when callers can do
        # better. Three cases, in priority order:
        #
        # 1. `override`: caller supplied a pre-computed count (e.g. the
        #    `index` endpoint's bulk group-count map). Used as-is.
        # 2. `check.edits.loaded?`: the `:edits` association is already in
        #    memory (loaded by `set_check`). Use the in-memory size — no
        #    SQL fires.
        # 3. Fallback: issue a single SELECT COUNT. This covers
        #    post-mutation reload paths (`mark_printed`, `void_check`)
        #    where `@check.reload` evicts the preloaded association.
        #
        # Previously this just called `check.edits.size`, which on case
        # (3) issued a per-request COUNT — Greptile's flagged N+1.
        def edit_count_for(check, override: nil)
          return override if override
          return check.edits.size if check.edits.loaded?
          check.edits.count
        end

        def edit_payload(edit)
          {
            id: edit.id,
            edited_by_id: edit.edited_by_id,
            edited_by_name: edit.edited_by_name,
            before: edit.before,
            after: edit.after,
            changed_fields: edit.changed_fields,
            reason: edit.reason,
            created_at: edit.created_at
          }
        end

        def line_item_payload(line_item)
          {
            id: line_item.id,
            description: line_item.description,
            reference_number: line_item.reference_number,
            service_period: line_item.service_period,
            amount: line_item.amount,
            position: line_item.position
          }
        end

        # Builds a stable hash of the audited fields with normalized types so
        # the diff between before/after isn't muddied by formatting (e.g.
        # BigDecimal vs Float, nil vs "").
        def audit_snapshot(check)
          AUDITED_FIELDS.each_with_object({}) do |field, snapshot|
            value = if field == "line_items"
              check.line_items.map { |item|
                {
                  "description" => item.description,
                  "reference_number" => item.reference_number,
                  "service_period" => item.service_period,
                  "amount" => item.amount.to_d.to_s("F"),
                  "position" => item.position
                }
              }
            else
              check.public_send(field)
            end
            # `BigDecimal#to_s` defaults to engineering notation (e.g.
            # "0.12550e3" for 125.50) which is unreadable in audit JSONB
            # and hard to inspect in psql. `to_s("F")` forces fixed-point
            # decimal notation ("125.5"), which matches what the UI
            # renders. `Numeric#to_s` (Float/Integer) is left as-is —
            # those already produce human-readable output. Comparison
            # via `changed_fields` is unaffected: identical inputs still
            # produce identical strings.
            value = if value.is_a?(BigDecimal)
              value.to_s("F")
            elsif value.is_a?(Numeric)
              value.to_s
            else
              value
            end
            snapshot[field] = value
          end
        end

        def changed_fields(before, after)
          # Treat nil and "" as equivalent for the optional text fields so
          # we don't log a spurious `field: null → ""` change when the
          # operator never touched it. `check_params` now coerces blanks
          # to nil to keep stored data clean, but an internal-service or
          # console caller could still write "" — this comparison
          # normalisation makes the audit trail robust either way.
          # Snapshots themselves remain honest (nil stays nil) so the
          # audit log never claims a value was "" when the DB had nil.
          AUDITED_FIELDS.select do |field|
            normalize_for_diff(field, before[field]) != normalize_for_diff(field, after[field])
          end
        end

        def normalize_for_diff(field, value)
          return "" if value.nil? && BLANKABLE_TEXT_FIELDS.include?(field.to_sym)
          value
        end
      end
    end
  end
end
