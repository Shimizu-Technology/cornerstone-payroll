# frozen_string_literal: true

require "digest"

module Api
  module V1
    module Admin
      class PayrollFilingRecordsController < BaseController
        def index
          identity = filing_identity
          return if performed?

          record = PayrollFilingRecord.includes(events: [ :recorded_by, :evidence_document ]).find_by(identity)
          render json: { filing: record ? serialize_record(record) : nil }
        end

        def create_event
          identity = filing_identity
          return if performed?
          return render json: { error: "Choose the agency receipt or response file" }, status: :unprocessable_entity unless params[:file].present?
          return render json: { error: "Idempotency key is required" }, status: :unprocessable_entity if params[:idempotency_key].blank?

          existing_event = PayrollFilingEvent.includes(:evidence_document).find_by(
            company_id: current_company_id,
            idempotency_key: params[:idempotency_key]
          )
          return render_idempotent_event(existing_event, identity) if existing_event

          upload_result = upload_evidence(identity)
          document = upload_result.documents.fetch(0)
          event = PayrollFilingRecord.transaction do
            recorded_event = PayrollFilingEvidenceRecorder.new(
              company: current_company,
              actor: current_user,
              attributes: identity.merge(event_params.to_h),
              evidence_document: document
            ).call

            AuditLog.record!(
              user: current_user,
              company_id: current_company_id,
              action: "payroll_filing_records##{recorded_event.event_type}",
              record_type: "payroll_filing_records",
              record_id: recorded_event.payroll_filing_record_id,
              subject_name: recorded_event.payroll_filing_record.display_name,
              metadata: {
                event_id: recorded_event.id,
                filing_type: recorded_event.payroll_filing_record.filing_type,
                tax_year: recorded_event.payroll_filing_record.tax_year,
                quarter: recorded_event.payroll_filing_record.quarter,
                reference_number: recorded_event.reference_number,
                evidence_document_id: document.id,
                source_fingerprint: recorded_event.source_fingerprint
              },
              ip_address: request.remote_ip,
              user_agent: request.user_agent
            )
            recorded_event
          end

          record = PayrollFilingRecord.includes(events: [ :recorded_by, :evidence_document ]).find(event.payroll_filing_record_id)
          render json: { filing: serialize_record(record) }, status: :created
        rescue PayrollFilingEvidenceRecorder::Error => e
          cleanup_upload(upload_result)
          existing_event = find_idempotent_event
          return render_idempotent_event(existing_event, identity) if existing_event

          render json: { error: e.message }, status: :unprocessable_entity
        rescue ArgumentError => e
          cleanup_upload(upload_result)
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          cleanup_upload(upload_result)
          existing_event = PayrollFilingEvent.includes(:evidence_document).find_by(
            company_id: current_company_id,
            idempotency_key: params[:idempotency_key]
          )
          return render_idempotent_event(existing_event, identity) if existing_event

          render json: { error: "The filing changed while this evidence was being saved. Refresh and try again." }, status: :conflict
        rescue ActiveRecord::RecordNotFound
          cleanup_upload(upload_result)
          render json: { error: "Company or filing record not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          cleanup_upload(upload_result)
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          cleanup_upload(upload_result)
          render json: { error: e.message }, status: :unprocessable_entity
        rescue StandardError
          cleanup_upload(upload_result)
          raise
        end

        private

        def filing_identity
          filing_type = params[:filing_type].to_s
          unless filing_type.in?(PayrollFilingRecord::FILING_TYPES)
            render json: { error: "Unsupported filing type" }, status: :unprocessable_entity
            return {}
          end

          tax_year = Integer(params[:tax_year], exception: false)
          unless tax_year&.in?(2000..2200)
            render json: { error: "tax_year must be a valid tax year" }, status: :unprocessable_entity
            return {}
          end

          annual = filing_type.in?(PayrollFilingRecord::ANNUAL_TYPES)
          quarter = annual ? nil : Integer(params[:quarter], exception: false)
          if !annual && !quarter&.in?(1..4)
            render json: { error: "quarter must be 1, 2, 3, or 4" }, status: :unprocessable_entity
            return {}
          end

          { company_id: current_company_id, filing_type: filing_type, tax_year: tax_year, quarter: quarter }
        end

        def event_params
          params.permit(
            :event_type,
            :occurred_at,
            :reference_number,
            :preparer_name,
            :signer_name,
            :signer_title,
            :notes,
            :idempotency_key
          )
        end

        def upload_evidence(identity)
          label = PayrollFilingRecord.new(identity.except(:company_id).merge(
            status: "submitted",
            submitted_at: Time.current,
            confirmation_number: "pending",
            source_fingerprint: "0" * 64
          )).display_name
          upload_params = ActionController::Parameters.new(
            file: params[:file],
            title: "#{label} #{params[:event_type].to_s.humanize} evidence",
            category: "filing_evidence",
            notes: params[:notes],
            visible_to_client: false
          )
          ClientDocumentUploadService.new(
            company_id: current_company_id,
            current_user: current_user,
            params: upload_params
          ).upload!
        end

        def cleanup_upload(upload_result)
          return unless upload_result

          upload_result.documents.each(&:destroy!)
          storage = R2StorageService.new
          upload_result.uploaded_keys.each { |key| storage.delete(key) }
        rescue StandardError => e
          Rails.logger.error("Unable to clean failed filing-evidence upload: #{e.class}: #{e.message}")
        end

        def render_idempotent_event(event, identity)
          unless same_event_request?(event, identity)
            return render json: {
              error: "This idempotency key was already used for different filing evidence"
            }, status: :conflict
          end

          record = PayrollFilingRecord.includes(events: [ :recorded_by, :evidence_document ])
            .find(event.payroll_filing_record_id)
          render json: { filing: serialize_record(record) }, status: :ok
        end

        def find_idempotent_event
          PayrollFilingEvent.includes(:evidence_document).find_by(
            company_id: current_company_id,
            idempotency_key: params[:idempotency_key]
          )
        end

        def same_event_request?(event, identity)
          record = event.payroll_filing_record
          event.event_type == params[:event_type].to_s &&
            event.reference_number == params[:reference_number].to_s.strip &&
            event.preparer_name == params[:preparer_name].to_s.strip &&
            event.signer_name.to_s == params[:signer_name].to_s.strip &&
            event.signer_title.to_s == params[:signer_title].to_s.strip &&
            event.notes.to_s == params[:notes].to_s &&
            same_occurred_at?(event) &&
            record.attributes.slice("company_id", "filing_type", "tax_year", "quarter") == identity.stringify_keys &&
            evidence_digest(event.evidence_document) == uploaded_file_digest
        end

        def same_occurred_at?(event)
          return true if params[:occurred_at].blank?

          event.occurred_at == Time.zone.parse(params[:occurred_at].to_s)
        rescue ArgumentError
          false
        end

        def evidence_digest(document)
          data = R2StorageService.new.download(document.file_key)
          data && Digest::SHA256.hexdigest(data)
        end

        def uploaded_file_digest
          file = params[:file]
          io = file.respond_to?(:tempfile) ? file.tempfile : file
          io.rewind if io.respond_to?(:rewind)
          digest = Digest::SHA256.hexdigest(io.read)
          io.rewind if io.respond_to?(:rewind)
          digest
        end

        def serialize_record(record)
          current_source = PayrollFilingSourceSnapshot.new(
            company: record.company,
            tax_year: record.tax_year,
            quarter: record.quarter
          ).call
          {
            id: record.id,
            filing_type: record.filing_type,
            display_name: record.display_name,
            tax_year: record.tax_year,
            quarter: record.quarter,
            status: record.status,
            submitted_at: record.submitted_at&.iso8601,
            resolved_at: record.resolved_at&.iso8601,
            confirmation_number: record.confirmation_number,
            source_fingerprint: record.source_fingerprint,
            current_source_fingerprint: current_source.fingerprint,
            source_changed: record.source_fingerprint != current_source.fingerprint,
            events: record.events.map { |event| serialize_event(event) }
          }
        end

        def serialize_event(event)
          {
            id: event.id,
            event_type: event.event_type,
            from_status: event.from_status,
            to_status: event.to_status,
            occurred_at: event.occurred_at.iso8601,
            reference_number: event.reference_number,
            preparer_name: event.preparer_name,
            signer_name: event.signer_name,
            signer_title: event.signer_title,
            notes: event.notes,
            source_fingerprint: event.source_fingerprint,
            recorded_by: event.recorded_by.name,
            evidence_document: {
              id: event.evidence_document.id,
              file_name: event.evidence_document.file_name,
              content_type: event.evidence_document.content_type,
              preview_available: event.evidence_document.preview_available?
            }
          }
        end
      end
    end
  end
end
