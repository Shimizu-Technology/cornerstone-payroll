# frozen_string_literal: true

namespace :employee_documents do
  desc "Classify existing pay stub revisions by printed figures (dry run unless APPLY=1)"
  task classify_pay_stub_revisions: :environment do
    apply = ENV["APPLY"] == "1"
    counts = Hash.new(0)
    read_figures = lambda do |document|
      EmployeeDocuments::PrintedFigures.for_document(document) if document
    rescue EmployeeDocuments::PrintedFigures::Unreadable, R2StorageService::DownloadError
      nil
    end
    TenantScope.as_system(reason: "Classify frozen employee pay stub revisions") do
      item_ids = EmployeeDocument.where.not(payroll_item_id: nil).select(:payroll_item_id)
      PayrollItem.where(id: item_ids).find_each do |item|
        figures_by_id = {}
        prior_label = false
        EmployeeDocument.where(company_id: item.company_id, payroll_item_id: item.id).order(:revision).each do |document|
          figures = read_figures.call(document)
          figures_by_id[document.id] = figures
          predecessor = document.replaces_document
          same_item = predecessor&.payroll_item_id == item.id
          previous_figures = same_item ? figures_by_id[predecessor.id] : read_figures.call(predecessor)
          classification = EmployeeDocuments::RevisionClassification.compare(
            figures: figures, previous_figures: previous_figures, predecessor: predecessor, same_item: same_item,
            prior_label: prior_label)
          if !figures || (predecessor && !previous_figures) || (document.revision > 1 && !predecessor)
            counts[:unresolved] += 1
            # An incomplete history cannot justify clearing an existing label.
            classification[:correction_label] ||= document.correction_label?
          elsif predecessor
            key = if classification[:money_changed]
              :money_changed
            elsif classification[:ytd_changed]
              :ytd_changed
            else
              :same_figures
            end
            counts[key] += 1
          end
          prior_label = classification[:correction_label]
          counts[:label_changes] += 1 if prior_label != document.correction_label?
          if apply
            EmployeeDocument.where(id: document.id, company_id: item.company_id)
              .update_all(**(figures&.attributes || {}), **classification)
          end
        end
      end
    end

    %i[money_changed same_figures ytd_changed label_changes unresolved].each { |key| puts "#{key}=#{counts[key]}" }
  end
end
