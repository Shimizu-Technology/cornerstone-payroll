# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ClientDocumentsController < BaseController
        before_action :set_document, only: [ :download, :preview, :destroy ]

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
          return render json: { error: @document.preview_error.presence || "Preview is unavailable for this file" }, status: :unprocessable_entity unless data

          send_data data,
            filename: filename,
            type: content_type,
            disposition: "inline"
        end

        def destroy
          R2StorageService.new.delete(@document.preview_file_key) if @document.preview_file_key.present?
          R2StorageService.new.delete(@document.file_key) if @document.file_key.present?
          @document.destroy!
          head :no_content
        end

        private

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
            created_at: document.created_at,
            preview_status: document.preview_status,
            preview_available: document.preview_available?,
            preview_generated_at: document.preview_generated_at,
            preview_content_type: document.preview_content_type,
            preview_error: document.preview_error
          }
        end

        def ensure_generated_preview!(document)
          return unless document.preview_generation_required?
          return if document.preview_ready?

          ClientDocumentPreviewGenerator.new(document: document).generate!
          document.reload
        rescue ClientDocumentPreviewGenerator::GenerationUnavailable, ClientDocumentPreviewGenerator::GenerationFailed => e
          Rails.logger.warn("Admin client document preview generation failed for document #{document.id}: #{e.message}")
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
      end
    end
  end
end
