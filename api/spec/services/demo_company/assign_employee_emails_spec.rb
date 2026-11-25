# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe DemoCompany::AssignEmployeeEmails do
  let(:organization) { create(:organization) }
  let!(:kitchen) { create_demo_company(organization: organization) }
  let!(:catering) { create_demo_company(organization: organization, name: "Harbor Finch Catering", fixture_key: DemoCompany::Roster::CATERING) }
  let(:aliases) { (1..6).map { |index| "reviewer+hf-emp#{index}@demo-mail.example" } }

  around do |example|
    saved = ENV[DemoOutbound::ENV_KEY]
    ENV[DemoOutbound::ENV_KEY] = aliases.join(",")
    example.run
  ensure
    ENV[DemoOutbound::ENV_KEY] = saved
  end

  before do
    DemoCompany::Roster::PEOPLE.each do |person|
      company = person[:company] == DemoCompany::Roster::KITCHEN ? kitchen : catering
      create(:employee, company: company, first_name: person[:first], last_name: person[:last], email: nil)
    end
  end

  def emails_by_name(company)
    Employee.where(company: company).where.not(email: nil).order(:id).pluck(:first_name, :email).to_h
  end

  it "gives the roster's people their aliases in order, the same one at both employers, and is safe to rerun" do
    outcomes = described_class.new(organization: organization, emails: aliases.join(", ")).call
    people = DemoCompany::Roster::PEOPLE.map { |person| person[:first] }.uniq.first(6)
    expect(emails_by_name(kitchen)).to eq(people.zip(aliases).to_h)
    # Kit Wren is the sixth person and works at both employers.
    expect(emails_by_name(catering)).to eq("Kit" => aliases[5])
    expect(outcomes.map(&:status).uniq).to eq([ "assigned" ])
    expect(outcomes.size).to eq(7)
    expect(AuditLog.where(action: "employees#demo_email_assigned").count).to eq(7)

    expect(described_class.new(organization: organization, emails: aliases).call.map(&:status).uniq).to eq([ "unchanged" ])
    expect(AuditLog.where(action: "employees#demo_email_assigned").count).to eq(7)
  end

  it "refuses addresses off the allow-list, repeats and missing employers, changing nothing" do
    expect { described_class.new(organization: organization, emails: [ aliases[0], "someone@client.example" ]).call }
      .to raise_error(described_class::Refused, /allow-list/)
    expect { described_class.new(organization: organization, emails: [ aliases[0], aliases[0] ]).call }
      .to raise_error(described_class::Refused, /once/)
    expect { described_class.new(organization: organization, emails: "").call }.to raise_error(described_class::Refused)
    expect(Employee.where.not(email: nil)).to be_empty
    expect { described_class.new(organization: create(:organization), emails: aliases).call }
      .to raise_error(described_class::Refused, /Seed the demo employers/)
  end

  it "runs as a rake task that prints domains, not addresses" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("demo:assign_employee_emails")
    task = Rake::Task["demo:assign_employee_emails"]
    task.reenable
    saved = ENV.to_h.slice("ORGANIZATION_ID", "EMAILS")
    ENV.update("ORGANIZATION_ID" => organization.id.to_s, "EMAILS" => aliases.first(2).join(","))
    expect { task.invoke }.to output(/OK    demo:assign_employee_emails Robin Lantern demo-mail\.example assigned/).to_stdout
    task.reenable
    expect { task.invoke }.not_to output(/reviewer\+/).to_stdout
  ensure
    %w[ORGANIZATION_ID EMAILS].each { |key| ENV[key] = saved&.dig(key) }
  end
end
