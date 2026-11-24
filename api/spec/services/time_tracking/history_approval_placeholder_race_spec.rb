# frozen_string_literal: true

require "rails_helper"
require "timeout"
require "support/aire_history_approval_evidence"

# The real approve! against a concurrent placeholder mark, on two PostgreSQL
# connections: the approval is held right after its locked fingerprint check
# (at persist_mappings!), and a mark of the employee's address is started on
# another connection. The organization placeholder lock must make the mark
# wait for the approval's commit.
RSpec.describe TimeTracking::HistoryApproval, :postgres_concurrency do
  include_context "aire history approval evidence"
  self.use_transactional_tests = false

  def table_counts
    connection = ActiveRecord::Base.connection
    connection.tables.sort.to_h { |table| [ table, connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}").to_i ] }
  end

  # The highest integer id per table before the example, so cleanup can remove
  # exactly the rows it created (factories also create other companies).
  def table_max_ids
    connection = ActiveRecord::Base.connection
    connection.tables.each_with_object({}) do |table, ids|
      id = connection.columns(table).find { |column| column.name == "id" }
      next unless id && %i[integer bigint].include?(id.type)

      ids[table] = connection.select_value("SELECT coalesce(max(id), 0) FROM #{connection.quote_table_name(table)}").to_i
    end
  end

  prepend_before do
    @baseline_counts = table_counts
    @baseline_max_ids = table_max_ids
  end

  after do
    # Never leave a paused approval holding its locks, even after a failure.
    @release&.push(true)
    [ @approval, @marker ].compact.each do |thread|
      Timeout.timeout(30) { thread.join }
    rescue StandardError
      thread.kill
    end
    connection = ActiveRecord::Base.connection
    keys = { "company_id" => company.id, "time_tracking_source_id" => source.id, "employee_id" => employee.id }
    connection.transaction do
      # Cleanup only: foreign keys and evidence triggers would otherwise block it.
      connection.execute("SET LOCAL session_replication_role = replica")
      connection.tables.each do |table|
        quoted = connection.quote_table_name(table)
        if @baseline_max_ids.key?(table)
          connection.execute("DELETE FROM #{quoted} WHERE id > #{@baseline_max_ids.fetch(table)}")
        else
          columns = connection.columns(table).map(&:name)
          keys.each do |column, id|
            connection.execute("DELETE FROM #{quoted} WHERE #{connection.quote_column_name(column)} = #{Integer(id)}") if columns.include?(column)
          end
        end
      end
    end
    expect(table_counts).to eq(@baseline_counts)
  end

  it "makes a placeholder mark wait for an approval paused after its fingerprint check, and keeps the approval correct" do
    # Auto-matched by name and email, so a late mark of this address matters.
    TimeTrackingEmployeeMapping.where(company: company, time_tracking_source: source).delete_all
    employee.update_columns(email: "worker.inbox@example.com")
    allow(client).to receive(:payroll_cockpit_employees).and_return(
      "employees" => [ { "id" => "91", "payroll_integration_id" => uuid, "full_name" => employee.full_name, "email" => employee.email, "active" => true } ],
      "pagination" => { "current_page" => 1, "per_page" => 100, "total_count" => 1, "total_pages" => 1, "truncated" => false }
    )
    page = history_service.prepare!
    expect(page["mappings"].sole).to include("employee_id" => employee.id, "confirmation_required" => false)

    paused = Queue.new
    release = @release = Queue.new
    finished = Queue.new
    service = history_service
    allow(service).to receive(:persist_mappings!).and_wrap_original do |original, *args|
      paused << true
      release.pop
      original.call(*args)
    end

    @approval = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = service.approve!(review: AireHistoryReview.find(page.fetch("review_id")), digest: page.fetch("digest"),
          attestation: described_class::ATTESTATION)
        finished << :approval
        result
      end
    end
    Timeout.timeout(30) { paused.pop }

    marker_pid = Queue.new
    @marker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        marker_pid << connection.select_value("SELECT pg_backend_pid()")
        result = TenantScope.as_system(reason: "Mark a placeholder during an approval") do
          EmployeeContactHygiene::PlaceholderEmailService.new(
            organization: company.organization, email: employee.email, actor: actor, company: company
          ).mark!
        end
        finished << :mark
        result
      end
    end

    # While the approval is held after its check, the marker's backend waits
    # on the organization's advisory lock rather than committing.
    pid = Timeout.timeout(30) { marker_pid.pop }
    waiting = <<~SQL
      SELECT EXISTS (
        SELECT FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE l.pid = #{Integer(pid)} AND l.locktype = 'advisory' AND NOT l.granted AND a.wait_event_type = 'Lock'
      )
    SQL
    Timeout.timeout(10) do
      sleep 0.02 until ActiveRecord::Base.connection.select_value(waiting)
    end
    expect(@marker).to be_alive
    expect(EmployeePlaceholderEmail.where(organization: company.organization).count).to eq(0)

    release << true
    Timeout.timeout(30) { [ @approval, @marker ].each(&:join) }
    expect([ finished.pop, finished.pop ]).to eq(%i[approval mark])

    # The approval committed what it checked (no mark yet); the mark landed after.
    expect(@approval.value["approved_at"]).to be_present
    review = AireHistoryReview.find(page.fetch("review_id"))
    expect(review.approved_at).to be_present
    expect(TimeTrackingEmployeeMapping.where(company: company, time_tracking_source: source).pluck(:employee_id)).to eq([ employee.id ])
    mark = EmployeePlaceholderEmail.find_by!(organization: company.organization, email: employee.email)
    expect(mark.created_at).to be > review.approved_at
    expect(@marker.value).to have_attributes(marked: true, changed: true)
  end
end
