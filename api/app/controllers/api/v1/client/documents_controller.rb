# frozen_string_literal: true

module Api
  module V1
    module Client
      class DocumentsController < BaseController
        before_action :set_document, only: [ :download, :preview ]
        before_action :set_owned_document, only: [ :destroy ]

        def index
          documents = ClientDocument.where(company_id: current_company_id)
                                    .client_visible
                                    .includes(:employee, :uploaded_by)
                                    .recent_first

          documents = documents.where(category: params[:category]) if params[:category].present?
          documents = documents.where(employee_id: params[:employee_id]) if params[:employee_id].present?

          render json: {
            data: documents.map { |document| serialize_document(document) }
          }
        end

        def create
          result = ClientDocumentUploadService.new(
            company_id: current_company_id,
            current_user: current_user,
            params: params.merge(visible_to_client: true)
          ).upload!
          documents = result.documents

          documents.each do |document|
            enqueue_preview_generation(document)
            AuditLog.record!(
              user: current_user,
              company_id: current_company_id,
              action: "client_documents#create",
              record_type: "client_documents",
              record_id: document.id,
              metadata: { title: document.title, category: document.category },
              ip_address: request.remote_ip,
              user_agent: request.user_agent
            )
          end

          render json: {
            data: documents.map { |document| serialize_document(document) },
            message: documents.count == 1 ? "Document uploaded successfully" : "#{documents.count} documents uploaded successfully"
          }, status: :created
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Employee not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def download
          data = R2StorageService.new.download(@document.file_key)
          return render json: { error: "File not found" }, status: :not_found unless data

          send_data data,
            filename: @document.download_filename,
            type: @document.content_type,
            disposition: "attachment"
        end

        def preview
          ensure_generated_preview!(@document)
          data, content_type, filename = preview_payload_for(@document)
          return render json: { error: public_preview_error(@document) }, status: :unprocessable_entity unless data

          send_data data,
            filename: filename,
            type: content_type,
            disposition: "inline"
        end

        def destroy
          file_keys = [ @document.preview_file_key, @document.file_key ].compact

          @document.destroy!
          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "client_documents#destroy",
            record_type: "client_documents",
            record_id: @document.id,
            metadata: { title: @document.title, category: @document.category },
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
          cleanup_storage_keys(file_keys)
          head :no_content
        end

        private

        def set_document
          @document = ClientDocument.client_visible.find_by(id: params[:id], company_id: current_company_id)
          return if @document

          render json: { error: "Document not found" }, status: :not_found
        end

        def set_owned_document
          @document = ClientDocument.find_by(
            id: params[:id],
            company_id: current_company_id,
            uploaded_by_id: current_user.id
          )
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
            preview_status: document.preview_status,
            preview_available: document.preview_available?,
            preview_generated_at: document.preview_generated_at,
            preview_content_type: document.preview_content_type,
            preview_error: public_preview_error(document)
          }
        end

        def enqueue_preview_generation(document)
          return unless document.preview_generation_required?

          GenerateClientDocumentPreviewJob.perform_later(document.id)
        end

        def ensure_generated_preview!(document)
          return unless document.preview_generation_required?
          return if document.preview_ready?

          ClientDocumentPreviewGenerator.new(document: document).generate!
          document.reload
        rescue ClientDocumentPreviewGenerator::GenerationUnavailable, ClientDocumentPreviewGenerator::GenerationFailed => e
          Rails.logger.warn("Client document preview generation failed for document #{document.id}: #{e.message}")
          document.reload
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
            Rails.logger.error("Client document storage cleanup failed for #{key}: #{e.message}")
          end
        end

        def public_preview_error(document)
          return nil unless document.preview_status == "failed"

          "Preview is unavailable for this file."
        end
      end
    end
  end
end
