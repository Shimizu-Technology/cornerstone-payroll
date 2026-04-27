# frozen_string_literal: true

module Api
  module V1
    module Client
      class DocumentsController < BaseController
        before_action :set_document, only: [ :download, :preview ]
        before_action :set_owned_document, only: [ :destroy ]

        def index
          documents = ClientDocument.where(company_id: current_company_id)
                                    .includes(:employee, :uploaded_by)
                                    .recent_first

          documents = documents.where(category: params[:category]) if params[:category].present?
          documents = documents.where(employee_id: params[:employee_id]) if params[:employee_id].present?

          render json: {
            data: documents.map { |document| serialize_document(document) }
          }
        end

        def create
          files = uploaded_files
          return render json: { error: "at least one file is required" }, status: :unprocessable_entity if files.empty?

          employee = if params[:employee_id].present?
            Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          end
          return render json: { error: "Employee not found" }, status: :not_found if params[:employee_id].present? && employee.nil?

          validation_errors = validation_errors_for(files)
          if validation_errors.any?
            return render json: { error: "Validation failed", details: { file: validation_errors } }, status: :unprocessable_entity
          end

          storage = R2StorageService.new
          uploaded_keys = []
          documents = []

          ClientDocument.transaction do
            files.each do |file|
              file_key = build_file_key(file.original_filename)
              content_type = ClientDocument.detected_content_type(file)
              storage.upload(file_key, file.tempfile || file, content_type: content_type)
              uploaded_keys << file_key

              document = ClientDocument.create!(
                company_id: current_company_id,
                employee: employee,
                uploaded_by: current_user,
                title: document_title_for(file, files.count),
                category: params[:category].presence || "misc",
                file_name: file.original_filename,
                file_key: file_key,
                content_type: content_type,
                file_size: file.size,
                notes: params[:notes],
                preview_status: ClientDocument.initial_preview_status_for(file)
              )
              documents << document
            end
          end

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
            message: files.count == 1 ? "Document uploaded successfully" : "#{files.count} documents uploaded successfully"
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          uploaded_keys&.each { |key| storage&.delete(key) }
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        rescue R2StorageService::UploadError => e
          uploaded_keys&.each { |key| storage&.delete(key) }
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
          @document = ClientDocument.find_by(id: params[:id], company_id: current_company_id)
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
            created_at: document.created_at,
            preview_status: document.preview_status,
            preview_available: document.preview_available?,
            preview_generated_at: document.preview_generated_at,
            preview_content_type: document.preview_content_type,
            preview_error: public_preview_error(document)
          }
        end

        def build_file_key(original_filename)
          sanitized_name = File.basename(original_filename.to_s).gsub(/[^A-Za-z0-9.\-_]/, "_")
          "client_documents/company_#{current_company_id}/#{Time.current.strftime('%Y/%m')}/#{SecureRandom.uuid}_#{sanitized_name}"
        end

        def uploaded_files
          Array.wrap(params[:files].presence || params[:file]).compact
        end

        def validation_errors_for(files)
          files.flat_map do |file|
            ClientDocument.upload_validation_errors(file).map do |message|
              "#{file.original_filename}: #{message}"
            end
          end
        end

        def document_title_for(file, total_files)
          return file.original_filename if total_files > 1

          params[:title].presence || file.original_filename
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
