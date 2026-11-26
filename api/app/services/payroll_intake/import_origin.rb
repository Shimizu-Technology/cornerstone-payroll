# frozen_string_literal: true

module PayrollIntake
  # Builds structured import_origin provenance metadata for intake imports:
  # which registered adapter and descriptor/parser version produced the import,
  # whether it came from a staff upload or a client portal revision, whether it
  # superseded an earlier package (re-import), and whether it replaced
  # hand-edited worksheet hours.
  module ImportOrigin
    module_function

    def build(session:, portal_submission: nil, replaced_hand_edited_hours: false)
      descriptor = PayrollIntake::Registry.find(session.source_type)
      submission = portal_submission || submission_from_session(session)

      {
        "adapter_key" => session.source_type,
        "parser_version" => session.parser_version,
        "descriptor_version" => descriptor&.parser_version || session.parser_version,
        "extraction" => descriptor&.extraction,
        "channel" => submission ? "portal_revision" : "staff_upload",
        "package_id" => session.package_id,
        "package_revision" => session.package_revision,
        "reimport" => session.supersedes_id.present?,
        "supersedes_package_id" => session.supersedes&.package_id,
        "portal_submission_id" => submission&.id,
        "portal_revision" => submission&.revision,
        "replaced_hand_edited_hours" => replaced_hand_edited_hours == true
      }.compact
    end

    def submission_from_session(session)
      submission_id = session.evidence_snapshot.to_h["payroll_submission_id"]
      return nil if submission_id.blank?

      PayrollSubmission.find_by(id: submission_id)
    end
    private_class_method :submission_from_session
  end
end
