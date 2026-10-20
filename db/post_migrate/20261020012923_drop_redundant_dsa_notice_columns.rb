# frozen_string_literal: true

class DropRedundantDsaNoticeColumns < ActiveRecord::Migration[8.0]
  DROPPED_COLUMNS = { dsa_notices: %i[declaration group_notified_at updated_at] }

  def up
    DROPPED_COLUMNS.each { |table, columns| Migration::ColumnDropper.execute_drop(table, columns) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
