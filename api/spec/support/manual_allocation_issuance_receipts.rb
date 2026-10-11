# frozen_string_literal: true

module ManualAllocationIssuanceReceipts
  def manual_issue_receipt(allocation, request, replayed: false)
    fixture = JSON.parse(Rails.root.join("spec/fixtures/manual_allocation_issuance_receipt.json").read)
    response = fixture.fetch("fresh_response").slice("manual_allocation", "integration", "command")
    source = allocation.time_tracking_source
    response["integration"] = {
      "protocol" => source.source_protocol, "protocol_version" => source.source_protocol_version,
      "source_type" => source.remote_source_identifier || source.source_type,
      "source_instance_id" => source.expected_source_instance_id,
      "capabilities" => source.source_capabilities, "policy_constraints" => source.source_policy_constraints
    }
    response["command"] = { "id" => request.fetch(:command_id), "replayed" => replayed }
    remote = response.fetch("manual_allocation")
    remote.merge!("id" => allocation.remote_allocation_id,
      "version" => request.fetch(:expected_version) + 1,
      "source_time_entry_id" => allocation.source_time_entry_id,
      "source_time_entry_version" => allocation.source_time_entry_version,
      "source_user_uuid" => allocation.source_user_uuid,
      "work_date" => allocation.original_work_date.iso8601, "pay_date" => allocation.pay_period.pay_date.iso8601,
      "regular_hours" => allocation.regular_hours.to_s("F"), "overtime_hours" => allocation.overtime_hours.to_s("F"),
      "total_hours" => allocation.total_hours.to_s("F"),
      "external_pay_period_id" => allocation.pay_period_id.to_s, "external_payroll_item_id" => allocation.payroll_item_id.to_s,
      "issued_at" => request.fetch(:occurred_at))
    tuple = request.slice(:payment_method, :payment_reference, :payment_effective_on).stringify_keys
    remote.merge!(tuple)
    remote["issued_payment"].merge!(tuple.merge("occurred_at" => request.fetch(:occurred_at), "reason" => request.fetch(:reason)))
    response["command_result"] = {
      "manual_allocation_id" => allocation.remote_allocation_id.to_i,
      "expected_version" => request.fetch(:expected_version), "result_version" => remote.fetch("version"),
      "status" => "issued", "manual_allocation" => remote.deep_dup,
      "integration" => response.fetch("integration").deep_dup
    }
    response["command_result"]["manual_allocation"]["issued_payment"].delete("reason")
    response
  end
end

RSpec.configure { |config| config.include ManualAllocationIssuanceReceipts }
