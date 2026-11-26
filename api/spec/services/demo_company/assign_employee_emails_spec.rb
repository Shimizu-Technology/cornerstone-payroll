# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe DemoCompany::AssignEmployeeEmails do
  let(:organization) { create(:organization) }
  let!(:kitchen) { create_demo_company(organization: organization) }
  let!(:catering) { create_demo_company(organization: organization, name: "Harbor Finch Catering", fixture_key: DemoCompany::Roster::CATERING) }
  let(:aliases) { (1..6).map { |index| "reviewer+hf-emp#{index}@demo-mail.example" } }
  let(:admin) { create(:user, company: create(:company, organization: organization), organization: organization, role: "admin") }

  def assign(emails, actor: admin, target: organization)
    described_class.new(organization: target, actor: actor, emails: emails).call
  end

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
    Employee.where(company: company).where.not(email: nil).order(:id).pluck(:first_name, :last_name, :email)
      .to_h { |first, last, email| [ "#{first} #{last}", email ] }
  end

  it "gives the roster's people their aliases in order, the same one at both employers, and is safe to rerun" do
    outcomes = assign(aliases.join(", "))
    people = DemoCompany::Roster::PEOPLE.map { |person| DemoCompany::Roster.full_name(person) }.uniq.first(6)
    expect(emails_by_name(kitchen)).to eq(people.zip(aliases).to_h)
    # Employee 06 is the sixth person and works at both employers.
    expect(emails_by_name(catering)).to eq("Employee 06" => aliases[5])
    expect(outcomes.map(&:status).uniq).to eq([ "assigned" ])
    expect(outcomes.size).to eq(7)
    expect(AuditLog.where(action: "employees#demo_email_assigned").count).to eq(7)

    expect(assign(aliases).map(&:status).uniq).to eq([ "unchanged" ])
    expect(AuditLog.where(action: "employees#demo_email_assigned").count).to eq(7)
  end

  it "refuses addresses off the allow-list, repeats and missing employers, changing nothing" do
    expect { assign([ aliases[0], "someone@client.example" ]) }.to raise_error(described_class::Refused, /allow-list/)
    expect { assign([ aliases[0], aliases[0] ]) }.to raise_error(described_class::Refused, /once/)
    expect { assign("") }.to raise_error(described_class::Refused)
    ENV[DemoOutbound::ENV_KEY] = (aliases + [ "not an address" ]).join(",")
    expect { assign([ aliases[0], "not an address" ]) }.to raise_error(described_class::Refused, /valid email/)
    expect(Employee.where.not(email: nil)).to be_empty
    other = create(:organization)
    expect { assign(aliases, target: other, actor: create(:user, company: create(:company, organization: other), organization: other, role: "admin")) }
      .to raise_error(described_class::Refused, /Seed the demo employers/)
  end

  it "checks every target employee before writing any" do
    Employee.find_by!(company: catering, first_name: "Employee", last_name: "06").update_columns(last_name: "99")
    expect { assign(aliases) }.to raise_error(described_class::Refused, /nothing was changed/)
    expect(Employee.where.not(email: nil)).to be_empty
    expect(AuditLog.where(action: "employees#demo_email_assigned")).to be_empty
  end

  it "requires an organization administrator and records the change as that person" do
    accountant = create(:user, company: admin.company, organization: organization, role: "accountant")
    expect { assign(aliases, actor: accountant) }.to raise_error(described_class::Refused, /administrator/)
    expect { assign(aliases, actor: nil) }.to raise_error(described_class::Refused, /administrator/)
    expect(Employee.where.not(email: nil)).to be_empty

    assign(aliases.first(1))
    expect(AuditLog.find_by!(action: "employees#demo_email_assigned").user_id).to eq(admin.id)
  end

  it "keeps the email and its audit row together" do
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid)
    expect { assign(aliases.first(1)) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Employee.where.not(email: nil)).to be_empty
  end

  it "runs as a rake task that prints domains, not addresses" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("demo:assign_employee_emails")
    task = Rake::Task["demo:assign_employee_emails"]
    task.reenable
    saved = ENV.to_h.slice("ORGANIZATION_ID", "ACTOR_ID", "EMAILS")
    ENV.update("ORGANIZATION_ID" => organization.id.to_s, "ACTOR_ID" => admin.id.to_s, "EMAILS" => aliases.first(2).join(","))
    expect { task.invoke }.to output(/OK    demo:assign_employee_emails Employee 01 demo-mail\.example assigned/).to_stdout
    task.reenable
    expect { task.invoke }.not_to output(/reviewer\+/).to_stdout

    task.reenable
    ENV["ACTOR_ID"] = "999999999"
    expect { task.invoke }.to raise_error(SystemExit).and output(/FAIL  demo:assign_employee_emails/).to_stderr
  ensure
    %w[ORGANIZATION_ID ACTOR_ID EMAILS].each { |key| ENV[key] = saved&.dig(key) }
  end
end
