# frozen_string_literal: true

namespace :employee_documents do
  desc "Classify existing pay stub revisions by printed figures (dry run unless APPLY=1)"
  task classify_pay_stub_revisions: :environment do
    apply = ENV["APPLY"] == "1"
    counts = Hash.new(0)
    TenantScope.as_system(reason: "Classify frozen employee pay stub revisions") do
      EmployeeDocument.where.not(payroll_item_id: nil).where(revision: 2..).find_each do |document|
        previous = document.replaces_document
        unless previous && previous.company_id == document.company_id
          counts[:unresolved] += 1
          next
        end

        if document.payroll_item.correction_entry? || document.payroll_item.financial_correction_origin_item_id ||
          previous.payroll_item_id != document.payroll_item_id || previous.withdrawal_reason.present? || previous.withdrawn?
          counts[:preserved] += 1
          next
        end

        figures = EmployeeDocuments::PrintedFigures.for_document(document)
        corrected = figures != EmployeeDocuments::PrintedFigures.for_document(previous)
        counts[corrected ? :money_changed : :same_figures] += 1
        counts[:label_changes] += 1 if corrected != document.correction_label?
        if apply
          # Classification is derived metadata. Leave frozen bytes, the
          # revision chain, and document timestamps intact.
          EmployeeDocument.where(id: document.id, company_id: document.company_id)
            .update_all(money_changed: corrected, printed_figures_sha256: figures)
        end
      rescue EmployeeDocuments::PrintedFigures::Unreadable, R2StorageService::DownloadError
        counts[:unresolved] += 1
      end
    end

    %i[money_changed same_figures label_changes preserved unresolved].each { |key| puts "#{key}=#{counts[key]}" }
  end
end
