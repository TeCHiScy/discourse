# frozen_string_literal: true

class RetireDsaNoticeAnonymity < ActiveRecord::Migration[8.0]
  def up
    change_column_default :dsa_notices, :anonymous, nil
    change_column_null :dsa_notices, :anonymous, true
    Migration::ColumnDropper.mark_readonly(:dsa_notices, :anonymous)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
