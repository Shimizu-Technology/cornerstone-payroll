# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe PortalFileRequests::Actions, :postgres_concurrency do
  self.use_transactional_tests = false

  let!(:organization) { Organization.create!(name: "File request concurrency #{SecureRandom.hex(4)}") }
  let!(:company) { create(:company, organization: organization) }
  let!(:client) { create(:user, company: company, organization: organization, role: "client", created_at: 1.year.ago) }
  let!(:staff) { Array.new(2) { create(:user, company: company, organization: organization, role: "accountant", created_at: 1.year.ago) } }

  before { allow(ClientPortalThreadChannel).to receive(:broadcast_thread) }

  after do
    ClientPortalMessage.where(company_id: company.id).update_all(portal_file_request_id: nil, kind: "message")
    PortalFileRequest.where(company_id: company.id).update_all(request_message_id: nil, last_response_message_id: nil)
    PortalMessageAttachment.where(company_id: company.id).delete_all
    PortalFileRequest.where(company_id: company.id).delete_all
    PortalThreadReadReceipt.joins(:client_portal_thread).where(client_portal_threads: { company_id: company.id }).delete_all
    ClientPortalMessage.where(company_id: company.id).delete_all
    ClientPortalThread.where(company_id: company.id).delete_all
    PortalNotificationDelivery.where(company_id: company.id).delete_all
    PortalNotificationEvent.where(company_id: company.id).delete_all
    AuditLog.where(company_id: company.id).delete_all
    ClientDocument.where(company_id: company.id).delete_all
    User.where(id: [ client.id, *staff.map(&:id) ]).delete_all
    Company.where(id: company.id).delete_all
    Organization.where(id: organization.id).delete_all
  end

  def actions(user)
    described_class.new(company: Company.find(company.id), actor: User.find(user.id))
  end

  def file
    create(:client_document, company: company, uploaded_by: client)
  end

  # Runs each block on its own connection, released together.
  def race(*blocks)
    gate = Queue.new
    results = Queue.new
    threads = blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          results << [ :ok, block.call ]
        rescue StandardError => error
          results << [ :error, error ]
        end
      end
    end
    blocks.size.times { gate << true }
    Timeout.timeout(20) { threads.each(&:join) }
    Array.new(blocks.size) { results.pop(true) }
  ensure
    threads&.each { |thread| thread.join(5) || thread.kill }
  end

  def responded_request
    request, = actions(staff.first).create!(ActionController::Parameters.new(title: "Timesheet", category: "payroll_source"))
    _, message, = actions(client).respond!(request, ActionController::Parameters.new(document_ids: [ file.id ]))
    [ request.reload, message ]
  end

  it "never accepts a response the reviewer did not see, whichever of accept and a new file lands first" do
    3.times do
      request, first_answer = responded_request
      newer = file
      outcomes = race(
        -> { actions(staff.first).accept!(PortalFileRequest.find(request.id), ActionController::Parameters.new(response_message_id: first_answer.id)) },
        -> { actions(client).respond!(PortalFileRequest.find(request.id), ActionController::Parameters.new(document_ids: [ newer.id ])) }
      )
      expect(outcomes.map(&:first)).to contain_exactly(:ok, :error), outcomes.inspect
      expect(outcomes.find { |kind, _| kind == :error }.last).to be_a(described_class::Conflict)
      request.reload
      if request.status == "accepted"
        expect(request.last_response_message_id).to eq(first_answer.id)
        expect(request.messages.where(kind: "file_response").count).to eq(1)
      else
        expect(request.status).to eq("responded")
        expect(request.last_response_message_id).not_to eq(first_answer.id)
      end
    end
  end

  it "lets only one of two staff accept, and saves one response for a doubled retry" do
    request, answer = responded_request
    outcomes = race(*staff.map { |user| -> { actions(user).accept!(PortalFileRequest.find(request.id), ActionController::Parameters.new(response_message_id: answer.id)) } })
    expect(outcomes.map(&:first)).to contain_exactly(:ok, :error)
    expect(request.reload.status).to eq("accepted")
    expect(request.messages.where(kind: "file_request_accepted").count).to eq(1)

    second, = actions(staff.first).create!(ActionController::Parameters.new(title: "W-4", category: "employee_onboarding"))
    attachment = file
    params = -> { ActionController::Parameters.new(document_ids: [ attachment.id ], idempotency_key: "same-retry") }
    outcomes = race(-> { actions(client).respond!(PortalFileRequest.find(second.id), params.call) },
      -> { actions(client).respond!(PortalFileRequest.find(second.id), params.call) })
    expect(outcomes.map(&:first)).to eq(%i[ok ok])
    expect(outcomes.map { |_, result| result.last }).to contain_exactly(true, false)
    expect(second.messages.where(kind: "file_response").count).to eq(1)
    expect(PortalNotificationEvent.where(event_type: "file_request_responded", company_id: company.id).count).to eq(2)
  end

  it "moves a read cursor only forward when two tabs report what they showed at once" do
    thread = ClientPortalThread.create!(company: company, created_by: client, subject: "Hours")
    first, second = Array.new(2) { |index| ClientPortalMessage.create!(client_portal_thread: thread, company: company, author: client, body: "Note #{index}") }
    reader = staff.first
    outcomes = race(-> { ClientPortalThread.find(thread.id).mark_read_for!(User.find(reader.id), displayed_message_ids: [ first.id, second.id ]) },
      -> { ClientPortalThread.find(thread.id).mark_read_for!(User.find(reader.id), displayed_message_ids: [ first.id ]) })
    expect(outcomes.map(&:first)).to eq(%i[ok ok])
    expect(PortalThreadReadReceipt.where(client_portal_thread_id: thread.id, user_id: reader.id).pluck(:last_displayed_message_id)).to eq([ second.id ])

    later = ClientPortalMessage.create!(client_portal_thread: thread, company: company, author: client, body: "Arrived after display")
    ClientPortalThread.find(thread.id).mark_read_for!(User.find(reader.id), displayed_message_ids: [ second.id ])
    expect(ClientPortalThread.find(thread.id).unread_for?(User.find(reader.id))).to be(true)
    expect(PortalThreadReadReceipt.find_by(client_portal_thread_id: thread.id, user_id: reader.id).last_displayed_message_id).to be < later.id
  end
end
