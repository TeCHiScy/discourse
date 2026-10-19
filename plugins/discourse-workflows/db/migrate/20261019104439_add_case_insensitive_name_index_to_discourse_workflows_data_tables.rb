# frozen_string_literal: true

class AddCaseInsensitiveNameIndexToDiscourseWorkflowsDataTables < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE discourse_workflows_data_tables AS data_tables
      SET name = LEFT(data_tables.name, 100 - LENGTH(data_tables.id::text) - 1) || '_' || data_tables.id
      FROM (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY LOWER(name) ORDER BY id) AS position
        FROM discourse_workflows_data_tables
      ) AS ranked
      WHERE data_tables.id = ranked.id AND ranked.position > 1
    SQL

    remove_index :discourse_workflows_data_tables, name: "idx_dwf_data_tables_on_name"
    add_index :discourse_workflows_data_tables,
              "LOWER(name)",
              unique: true,
              name: "idx_dwf_data_tables_on_lower_name"
  end

  def down
    remove_index :discourse_workflows_data_tables, name: "idx_dwf_data_tables_on_lower_name"
    add_index :discourse_workflows_data_tables,
              :name,
              unique: true,
              name: "idx_dwf_data_tables_on_name"
  end
end
