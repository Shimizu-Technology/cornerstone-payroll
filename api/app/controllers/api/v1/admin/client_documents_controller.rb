# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ClientDocumentsController < BaseController
        include PortalDocumentTracking
        include ClientDocumentUploadRateLimit
        rescue_from ClientDocumentScanner::Blocked do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        before_action :private_document_response!, only: [ :download, :preview ]

        before_action :set_document, only: [ :download, :preview, :destroy, :unarchive, :opened, :activity ]

        def index
          documents = ClientDocument.where(company_id: current_company_id)
                                    .includes(:employee, :uploaded_by)
                                    .recent_first

          documents = documents.where(category: params[:category]) if params[:category].present?
          documents = documents.where(employee_id: params[:employee_id]) if params[:employee_id].present?
          documents = documents.where(uploaded_by_id: params[:uploaded_by_id]) if params[:uploaded_by_id].present?

          render json: {
            data: documents.map { |document| serialize_document(document) }
          }
        end

        def create
          result = AuditedClientDocumentUpload.call(
            company_id: current_company_id, current_user: current_user,
            params: params
          ) do |uploaded|
            uploaded.documents.each do |document|
              PortalActivity.record!(user: current_user, record: document, action: "admin_client_documents#create",
                metadata: PortalActivity.document_metadata(document),
                ip_address: request.remote_ip, user_agent: request.user_agent)
            end
            audit_requirement_received!(uploaded.document_requirement) if uploaded.document_requirement
          end
          documents = result.documents
          documents.each { |document| enqueue_preview_generation(document) }

          render json: {
            data: documents.map { |document| serialize_document(document) },
            message: documents.count == 1 ? "Document shared successfully" : "#{documents.count} documents shared successfully"
          }, status: :created
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Employee not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Please check the selected files", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def download
          @document.ensure_usable_for!(:download, staff_read: true)
          data = R2StorageService.new.download(@document.file_key)
          return render json: { error: "File not found" }, status: :not_found unless data

          audit_portal_document!("portal_documents#download")
          send_data data,
            filename: @document.download_filename,
            type: @document.content_type,
            disposition: "attachment"
        end

        def preview
          @document.ensure_usable_for!(:preview, staff_read: true)
          ensure_generated_preview!(@document)
          data, content_type, filename = preview_payload_for(@document)
          return render json: { error: @document.preview_error.presence || "Preview is unavailable for this file" }, status: :unprocessable_entity unless data

          audit_portal_document!("portal_documents#preview")
          send_data data,
            filename: filename,
            type: content_type,
            disposition: "inline"
        end

        def unarchive
          @document.with_lock do
            if @document.archived?
              PortalActivity.record!(user: current_user, record: @document, action: "admin_client_documents#unarchive",
                metadata: PortalActivity.document_metadata(@document).merge(archived_at: @document.archived_at.iso8601, archived_by_id: @document.archived_by_id),
                ip_address: request.remote_ip, user_agent: request.user_agent)
              @document.update!(archived_at: nil, archived_by_id: nil)
            end
          end
          render json: { data: serialize_document(@document), message: "File unarchived." }
        end

        def destroy
          file_keys = nil
          disposition = nil
          @document.with_lock do
            file_keys = [ @document.preview_file_key, @document.file_key ].compact
            disposition = @document.archive_or_destroy!(actor: current_user)
            PortalActivity.record!(user: current_user, record: @document,
              action: "admin_client_documents##{disposition == :archived ? 'archive' : 'destroy'}",
              metadata: PortalActivity.document_metadata(@document),
              ip_address: request.remote_ip, user_agent: request.user_agent)
          end
          if disposition == :archived
            render json: { data: serialize_document(@document), message: "File archived. It is kept with the messages or evidence that reference it." }
          else
            cleanup_storage_keys(file_keys)
            head :no_content
          end
        end

        private

        def private_document_response!
          response.set_header("Cache-Control", "private, no-store")
          response.set_header("X-Content-Type-Options", "nosniff")
        end

        def set_document
          @document = ClientDocument.find_by(id: params[:id], company_id: current_company_id)
          return if @document

          render json: { error: "Document not found" }, status: :not_found
        end

        def serialize_document(document)
          {
            id: document.id,
            title: document.title,
            category: document.category,
            file_name: document.file_name,
            content_type: document.content_type,
            file_size: document.file_size,
            notes: document.notes,
            employee_id: document.employee_id,
            employee_name: document.employee&.full_name,
            uploaded_by_id: document.uploaded_by_id,
            uploaded_by_name: document.uploaded_by&.name,
            visible_to_client: document.visible_to_client,
            shared_by_staff: document.shared_by_staff,
            created_at: document.created_at,
            archived_at: document.archived_at,
            archived_by_id: document.archived_by_id,
            scan_status: document.scan_status,
            preview_status: document.preview_status,
            preview_available: document.preview_available?(staff_read: true),
            preview_generated_at: document.preview_generated_at,
            preview_content_type: document.preview_content_type,
            preview_error: document.preview_error
          }
        end

        def ensure_generated_preview!(document)
          return unless document.preview_generation_required?
          return if document.preview_ready?

          ClientDocumentPreviewGenerator.new(document: document, staff_read: true).generate!
          document.reload
        rescue ClientDocumentPreviewGenerator::GenerationUnavailable, ClientDocumentPreviewGenerator::GenerationFailed => e
          Rails.logger.warn("Admin client document preview generation failed for document #{document.id}: #{e.message}")
          document.reload
        end

        def enqueue_preview_generation(document)
          return unless document.preview_generation_required?

          GenerateClientDocumentPreviewJob.perform_later(document.id)
        end

        def preview_payload_for(document)
          storage = R2StorageService.new
          if document.preview_ready?
            data = storage.download(document.preview_file_key)
            return [ data, document.preview_content_type || "application/pdf", document.preview_filename ] if data
          elsif document.preview_served_from_original?
            data = storage.download(document.file_key)
            return [ data, document.content_type, document.download_filename ] if data
          end

          [ nil, nil, nil ]
        end

        def cleanup_storage_keys(file_keys)
          storage = R2StorageService.new
          file_keys.each do |key|
            storage.delete(key)
          rescue R2StorageService::UploadError => e
            Rails.logger.error("Admin client document storage cleanup failed for #{key}: #{e.message}")
          end
        end

        def audit_requirement_received!(requirement)
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "employee_document_requirements#receive",
            record_type: "employee_document_requirements",
            record_id: requirement.id,
            subject_name: requirement.employee.full_name,
            metadata: { employee_id: requirement.employee_id, employee_name: requirement.employee.full_name, requirement_type: requirement.requirement_type },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        end
      end
    end
  end
end
