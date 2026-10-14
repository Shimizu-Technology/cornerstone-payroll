# frozen_string_literal: true

require Rails.root.join("lib/database_integrity")

# Covers db:schema:load, db:test:prepare and isolated-schema concurrency drills.
# Regular upgrades continue to install guards through their original migrations.
ActiveRecord::Schema::Definition.prepend(DatabaseIntegrity::SchemaDefinition)
