# frozen_string_literal: true

class RetireRedundantDsaNoticeColumns < ActiveRecord::Migration[8.0]
  def up
    change_column_null :dsa_notices, :declaration, true
    change_column_null :dsa_notices, :updated_at, true
    Migration::ColumnDropper.mark_readonly(:dsa_notices, :declaration)
    Migration::ColumnDropper.mark_readonly(:dsa_notices, :group_notified_at)
    Migration::ColumnDropper.mark_readonly(:dsa_notices, :updated_at)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
