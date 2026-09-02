# frozen_string_literal: true

require "kamal"

class KamalMigrationExecutor
  MIGRATION_KEYS = %w[
    MIGRATION_DATABASE_URL
    MIGRATION_CACHE_DATABASE_URL
    MIGRATION_QUEUE_DATABASE_URL
    MIGRATION_CABLE_DATABASE_URL
  ].freeze

  class SensitiveEnvironment < Hash
  end

  module InjectEnvironment
    def exec(*command)
      options[:env] = KamalMigrationExecutor.migration_environment
      super
    end
  end

  module RedactEnvironment
    def argumentize(argument, attributes, sensitive: false)
      sensitive ||= attributes.is_a?(KamalMigrationExecutor::SensitiveEnvironment)
      super(argument, attributes, sensitive: sensitive)
    end
  end

  class << self
    attr_accessor :environment

    def migration_environment
      values = MIGRATION_KEYS.to_h do |key|
        [ key, environment.fetch(key, "").strip ]
      end.compact_blank

      unless values.key?("MIGRATION_DATABASE_URL")
        raise "MIGRATION_DATABASE_URL must be set to a direct, non-pooler connection before deploying."
      end

      SensitiveEnvironment.new.merge(values)
    end
  end

  def initialize(environment: ENV, cli: Kamal::Cli::Main)
    self.class.environment = environment
    @environment = environment
    @cli = cli
  end

  def run!
    self.class.migration_environment
    install_extensions!
    @cli.start(command_arguments)
  end

  def command_arguments
    arguments = [
      "app",
      "exec",
      "--quiet",
      "--primary",
      "--version",
      @environment.fetch("KAMAL_VERSION"),
      "--",
      "bin/rails db:safe_prepare"
    ]
    destination = @environment.fetch("KAMAL_DESTINATION", "").strip
    arguments.insert(6, "--destination", destination) unless destination.empty?
    arguments
  end

  private

  def install_extensions!
    Kamal::Cli::App.prepend(InjectEnvironment) unless Kamal::Cli::App < InjectEnvironment
    Kamal::Utils.singleton_class.prepend(RedactEnvironment) unless Kamal::Utils.singleton_class < RedactEnvironment
  end
end
