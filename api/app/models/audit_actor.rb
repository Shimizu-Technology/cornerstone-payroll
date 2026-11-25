# frozen_string_literal: true

class AuditActor < Data.define(:type, :id, :name, :email, :role)
  TYPES = %w[staff_user client_user employee operator source_system source_worker kiosk system_job].freeze

  def self.for_user(user)
    type = case user.role
    when "client" then "client_user"
    when "employee", "portal_employee" then "employee"
    else "staff_user"
    end
    new(type: type, id: user.id.to_s, name: user.name,
      email: user.email, role: user.role)
  end

  def self.employee(employee)
    new(type: "employee", id: employee.id.to_s, name: employee.full_name, email: nil, role: "employee")
  end

  def self.kiosk(id:, name:)
    new(type: "kiosk", id: id.to_s, name: name.presence || "Kiosk (#{id})", email: nil, role: "kiosk")
  end

  def self.operator(name)
    new(type: "operator", id: nil, name: name, email: nil, role: "operator")
  end

  def self.source_system(source:)
    name = source.source_type == "aire_services" ? "AIRE System" : source.name
    new(type: "source_system", id: source.id.to_s, name: name, email: nil, role: "source_system")
  end

  def self.source_worker(id:)
    new(type: "source_worker", id: id.to_s, name: "AIRE Worker (#{id})", email: nil, role: "source_worker")
  end

  def self.system_job(job)
    name, id = job.is_a?(String) ? [ job, nil ] : [ job.class.name, job.job_id ]
    new(type: "system_job", id: id, name: name, email: nil, role: "system_job")
  end
end
