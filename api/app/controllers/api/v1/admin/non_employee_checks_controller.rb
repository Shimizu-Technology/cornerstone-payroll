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
          reference_number check_number
        ].freeze

        before_action :set_check, only: [:show, :update, :destroy, :mark_printed, :void_check, :check_pdf, :history]

        # GET /api/v1/admin/non_employee_checks
        def index
          checks = NonEmployeeCheck.where(company_id: current_company_id)
            .includes(:pay_period, :created_by, :edits)

          checks = checks.where(pay_period_id: params[:pay_period_id]) if params[:pay_period_id].present?
          checks = checks.where(check_type: params[:check_type]) if params[:check_type].present?
          checks = checks.active if params[:active] == "true"

          checks = checks.order(created_at: :desc)

          render json: { non_employee_checks: checks.map { |c| check_payload(c) } }
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
          check.pay_period = pay_period if pay_period

          if check.save
            render json: { non_employee_check: check_payload(check) }, status: :created
          else
            render json: { errors: check.errors.full_messages }, status: :unprocessable_entity
          end
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
            if @check.update(attrs)
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
          generator = NonEmployeeCheckGenerator.new(@check)
          pdf_data  = @check.voided? ? generator.generate_voided : generator.generate

          send_data pdf_data,
            type: "application/pdf",
            disposition: "inline",
            filename: generator.filename
        end

        private

        def set_check
          # Preload :edits so check_payload's `edit_count: check.edits.size`
          # uses the loaded association instead of issuing a per-request COUNT.
          @check = NonEmployeeCheck
            .includes(:edits)
            .find_by(id: params[:id], company_id: current_company_id)
          return if @check

          render json: { error: "Check not found" }, status: :not_found
        end

        def check_params
          permitted = params.require(:non_employee_check).permit(
            :pay_period_id, :payable_to, :amount, :check_type,
            :memo, :description, :reference_number, :check_number
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
        BLANKABLE_TEXT_FIELDS = %i[check_number memo description reference_number].freeze

        def resolve_pay_period(pay_period_id)
          pay_period = PayPeriod.find_by(id: pay_period_id, company_id: current_company_id)
          return pay_period if pay_period

          render json: { error: "Pay period not found" }, status: :not_found
          nil
        end

        def check_payload(check)
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
            print_count: check.print_count,
            printed_at: check.printed_at,
            voided: check.voided,
            void_reason: check.void_reason,
            voided_at: check.voided_at,
            check_status: check.check_status,
            edit_count: check.edits.size,
            created_by_id: check.created_by_id,
            created_at: check.created_at,
            updated_at: check.updated_at
          }
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

        # Builds a stable hash of the audited fields with normalized types so
        # the diff between before/after isn't muddied by formatting (e.g.
        # BigDecimal vs Float, nil vs "").
        def audit_snapshot(check)
          AUDITED_FIELDS.each_with_object({}) do |field, snapshot|
            value = check.public_send(field)
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
