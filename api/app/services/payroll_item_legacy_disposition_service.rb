# frozen_string_literal: true

require "digest"

class PayrollItemLegacyDispositionService
  class Error < StandardError; end

  def self.preview(company_id:)
    rows = PayrollItem.joins(:pay_period)
      .where(company_id: company_id, pay_periods: { status: "committed" })
      .includes(:pay_period, :payroll_item_earnings, :payroll_item_deductions, :payroll_item_field_entries)

    results = []
    rows.in_batches(of: 200) do |batch|
      items = batch.to_a
      inspections = PayrollItemActivity.analyze_many(items)
      dispositioned_ids = PayrollItemLegacyDisposition.where(payroll_item_id: items.map(&:id)).pluck(:payroll_item_id).to_set
      results.concat(items.map do |item|
        inspection = inspections.fetch(item)
        {
          payroll_item_id: item.id,
          pay_period_id: item.pay_period_id,
          employee_id: item.employee_id,
          classification: inspection.fetch(:classification),
          reasons: inspection.fetch(:reasons),
          evidence_digest: digest_for(item, inspection: inspection),
          already_dispositioned: dispositioned_ids.include?(item.id)
        }
      end)
    end
    results
  end

  # `entries` must come from a reviewed preview manifest. Each row contains
  # payroll_item_id and evidence_digest; changed evidence rejects the batch.
  def self.apply!(company_id:, actor:, entries:)
    unless actor&.persisted? && actor.active? && actor.staff_member? && actor.can_access_company?(Integer(company_id))
      raise Error, "An authorized payroll staff actor is required"
    end
    raise Error, "Select at least one reviewed item" if entries.blank?

    reviewed = entries.map(&:symbolize_keys)
    ids = reviewed.map { |entry| Integer(entry.fetch(:payroll_item_id)) }
    raise Error, "Duplicate payroll items in manifest" unless ids.uniq.length == ids.length
    raise Error, "Each item needs its preview evidence digest" unless reviewed.all? { |entry| entry[:evidence_digest].to_s.match?(/\A[0-9a-f]{64}\z/) }

    ApplicationRecord.transaction do
      Company.lock.find(company_id)
      items = PayrollItem.where(company_id: company_id, id: ids).order(:id).lock.index_by(&:id)
      raise Error, "Manifest includes an item outside this company" unless items.length == ids.length

      reviewed.map do |entry|
        item = items.fetch(Integer(entry.fetch(:payroll_item_id)))
        existing = PayrollItemLegacyDisposition.find_by(payroll_item_id: item.id)
        digest = digest_for(item)
        raise Error, "Item ##{item.id} changed after preview" unless digest == entry.fetch(:evidence_digest)
        raise Error, "Item ##{item.id} is not a committed verified-empty row" unless item.pay_period.committed? && PayrollItemActivity.classify(item) == :verified_empty
        if existing
          raise Error, "Item ##{item.id} has a different recorded disposition" unless existing.company_id == company_id && existing.evidence_digest == digest
          existing
        else
          PayrollItemLegacyDisposition.create!(
            payroll_item: item,
            company_id: company_id,
            created_by: actor,
            reason: PayrollItemLegacyDisposition::REASON,
            evidence_digest: digest,
            evidence: evidence_for(item)
          )
        end
      end
    end
  rescue ArgumentError, KeyError => e
    raise Error, "Invalid reviewed manifest: #{e.message}"
  end

  def self.digest_for(item, inspection: nil)
    Digest::SHA256.hexdigest(JSON.generate(evidence_for(item, inspection: inspection)))
  end

  def self.evidence_for(item, inspection: nil)
    inspection ||= {
      classification: PayrollItemActivity.classify(item),
      reasons: PayrollItemActivity.reasons(item)
    }
    {
      "item_attributes" => item.attributes.sort.to_h,
      "pay_period_status" => item.pay_period.status,
      "classification" => inspection.fetch(:classification).to_s,
      "reasons" => inspection.fetch(:reasons),
      "earnings" => item.payroll_item_earnings.map(&:attributes).sort_by { |row| row.fetch("id", 0).to_i },
      "deductions" => item.payroll_item_deductions.map(&:attributes).sort_by { |row| row.fetch("id", 0).to_i },
      "field_entries" => item.payroll_item_field_entries.map(&:attributes).sort_by { |row| row.fetch("id", 0).to_i }
    }
  end
end
