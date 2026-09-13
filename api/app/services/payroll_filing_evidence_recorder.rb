# frozen_string_literal: true

class PayrollFilingEvidenceRecorder
  class Error < StandardError; end

  OUTCOME_EVENTS = %w[accepted accepted_with_errors rejected].freeze

  def initialize(company:, actor:, attributes:, evidence_document:)
    @company = company
    @actor = actor
    @attributes = attributes.to_h.with_indifferent_access
    @evidence_document = evidence_document
  end

  def call
    validate_identity!
    validate_event!

    PayrollFilingRecord.transaction do
      Company.lock.find(company.id)
      record = PayrollFilingRecord.lock.find_by(identity)
      validate_transition!(record)

      source = source_for(record)
      occurred_at = parse_occurred_at!
      validate_chronology!(record, occurred_at)
      event = PayrollFilingEvent.create!(
        payroll_filing_record: record || build_record(source: source, occurred_at: occurred_at),
        company: company,
        recorded_by: actor,
        evidence_document: evidence_document,
        event_type: event_type,
        from_status: record&.status,
        to_status: target_status,
        occurred_at: occurred_at,
        reference_number: attributes[:reference_number].to_s.strip,
        preparer_name: attributes[:preparer_name].to_s.strip,
        signer_name: normalized_optional_text(:signer_name),
        signer_title: normalized_optional_text(:signer_title),
        notes: attributes[:notes].presence,
        source_fingerprint: source.fingerprint,
        source_snapshot: source.snapshot,
        idempotency_key: attributes[:idempotency_key].presence || SecureRandom.uuid
      )

      event.payroll_filing_record.update!(
        status: target_status,
        submitted_at: occurred_at_for_submission(record, occurred_at),
        resolved_at: OUTCOME_EVENTS.include?(event_type) ? occurred_at : nil,
        confirmation_number: event.reference_number,
        source_fingerprint: source.fingerprint,
        source_snapshot: source.snapshot
      )
      event
    end
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.join(", ")
  rescue ArgumentError, Date::Error => e
    raise Error, e.message
  end

  private

  attr_reader :company, :actor, :attributes, :evidence_document

  def filing_type
    attributes[:filing_type].to_s
  end

  def tax_year
    @tax_year ||= Integer(attributes[:tax_year])
  end

  def quarter
    return if PayrollFilingRecord::ANNUAL_TYPES.include?(filing_type)

    @quarter ||= Integer(attributes[:quarter])
  end

  def event_type
    attributes[:event_type].to_s
  end

  def target_status
    return "submitted" if event_type == "resubmitted"
    return "needs_correction" if event_type == "correction_needed"

    event_type
  end

  def identity
    { company_id: company.id, filing_type: filing_type, tax_year: tax_year, quarter: quarter }
  end

  def validate_identity!
    raise Error, "Unsupported filing type" unless filing_type.in?(PayrollFilingRecord::FILING_TYPES)
    raise Error, "tax_year must be a valid tax year" unless tax_year.in?(2000..2200)
    raise Error, "quarter must be 1, 2, 3, or 4" if quarter.present? && !quarter.in?(1..4)
    raise Error, "Evidence must belong to this company" unless evidence_document&.company_id == company.id
    raise Error, "Choose a filing-evidence document" unless evidence_document.category == "filing_evidence"
    raise Error, "Filing evidence must be retained as an internal document" if evidence_document.visible_to_client?
  end

  def validate_event!
    raise Error, "Unsupported filing event" unless event_type.in?(PayrollFilingEvent::EVENT_TYPES)
    raise Error, "Reference or confirmation number is required" if attributes[:reference_number].blank?
    raise Error, "Preparer name is required" if attributes[:preparer_name].blank?
    raise Error, "Idempotency key is required" if attributes[:idempotency_key].blank?

    if return_filing? && event_type.in?(%w[submitted resubmitted]) && attributes[:signer_name].blank?
      raise Error, "Signer name is required for a tax return submission"
    end
    if event_type.in?(%w[accepted_with_errors rejected correction_needed]) && attributes[:notes].blank?
      raise Error, "Explain the agency errors or rejection before saving"
    end
  end

  def validate_transition!(record)
    if record.nil?
      raise Error, "The first event must record the submission" unless event_type == "submitted"
      validate_ready_to_submit!
      return
    end

    allowed = {
      "submitted" => OUTCOME_EVENTS,
      "accepted_with_errors" => %w[resubmitted],
      "rejected" => %w[resubmitted],
      "accepted" => %w[correction_needed],
      "needs_correction" => %w[resubmitted]
    }.fetch(record.status)
    raise Error, "#{record.display_name} cannot move from #{record.status.humanize.downcase} to #{event_type.humanize.downcase}" unless event_type.in?(allowed)

    validate_ready_to_submit! if event_type == "resubmitted"
  end

  def validate_ready_to_submit!
    if quarter.present?
      validate_quarterly_readiness!
    elsif filing_type == "w2_gu_w3_ss"
      validate_w2_readiness!
    else
      validate_1099_readiness!
    end
  end

  def validate_quarterly_readiness!
    packet = QuarterlyCompliancePacket.find_by(company_id: company.id, year: tax_year, quarter: quarter)
    raise Error, "Start the quarterly filing workflow before recording a submission" unless packet

    task_types = {
      "form_500_payment" => %w[form_500],
      "w1" => %w[w1],
      "swica" => %w[swica],
      "federal_941" => %w[federal_941 schedule_b]
    }.fetch(filing_type)
    tasks = packet.quarterly_compliance_tasks.where(task_type: task_types).index_by(&:task_type)
    primary_task = tasks[task_types.first]
    raise Error, "Mark #{task_types.first.humanize} ready before recording the submission" unless primary_task&.status == "ready_to_file"

    incomplete = task_types.drop(1).reject { |type| tasks[type]&.status.in?(%w[ready_to_file not_required]) }
    raise Error, "Mark #{incomplete.map(&:humanize).join(' and ')} ready before recording the submission" if incomplete.any?

    filing_gate = PayrollFilingResponsibilityGate.new(
      company: company,
      tax_year: tax_year,
      quarter: quarter,
      filing_type: PayrollFilingResponsibilityGate::TASK_FILING_TYPES.fetch(task_types.first)
    ).payload
    raise Error, filing_gate[:blockers].first[:message] unless filing_gate.dig(:capabilities, :can_mark_filing_ready)
  end

  def validate_w2_readiness!
    readiness = W2FilingReadiness.find_by(company_id: company.id, year: tax_year)
    raise Error, "Run W-2GU preflight and mark the wage filing ready first" unless readiness&.status == "filing_ready"

    gate = PayrollFilingResponsibilityGate.annual(company: company, tax_year: tax_year)
    raise Error, gate[:blockers].first[:message] unless gate.dig(:capabilities, :all_filing_ready_exports_allowed)
  end

  def validate_1099_readiness!
    report = Form1099NecAggregator.new(company, tax_year).generate
    raise Error, "There are no reportable 1099-NEC contractors for this tax year" if report.dig(:meta, :reportable_count).to_i.zero?

    issues = report.fetch(:reportable_contractors).flat_map { |row| row.fetch(:compliance_issues) }
    raise Error, "Resolve all reportable contractor filing issues before recording the submission" if issues.any?
  end

  def source_for(record)
    return PayrollFilingSourceSnapshot::Result.new(snapshot: record.source_snapshot, fingerprint: record.source_fingerprint) if record && event_type != "resubmitted"

    PayrollFilingSourceSnapshot.new(company: company, tax_year: tax_year, quarter: quarter).call
  end

  def build_record(source:, occurred_at:)
    PayrollFilingRecord.create!(
      **identity,
      status: "submitted",
      submitted_at: occurred_at,
      confirmation_number: attributes[:reference_number].to_s.strip,
      source_fingerprint: source.fingerprint,
      source_snapshot: source.snapshot
    )
  end

  def parse_occurred_at!
    value = attributes[:occurred_at].presence
    return Time.current unless value

    Time.zone.parse(value.to_s) || raise(ArgumentError)
  rescue ArgumentError
    raise Error, "Event date and time is invalid"
  end

  def occurred_at_for_submission(record, occurred_at)
    event_type.in?(%w[submitted resubmitted]) ? occurred_at : record.submitted_at
  end

  def validate_chronology!(record, occurred_at)
    previous_at = record&.events&.maximum(:occurred_at)
    return if previous_at.blank? || occurred_at >= previous_at

    raise Error, "Event date and time cannot be before the previous filing event"
  end

  def return_filing?
    filing_type != "form_500_payment"
  end

  def normalized_optional_text(key)
    attributes[key].to_s.strip.presence
  end
end
