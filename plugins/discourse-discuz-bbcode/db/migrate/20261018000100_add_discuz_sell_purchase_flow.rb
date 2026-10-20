# frozen_string_literal: true

class AddDiscuzSellPurchaseFlow < ActiveRecord::Migration[7.2]
  def change
    add_column :discuz_sell_sections, :discuz_fid, :integer, null: false, default: 0
    add_column :discuz_sell_sections, :credit_title, :string, null: false, default: "积分"
    add_column :discuz_sell_sections, :credit_unit, :string, null: false, default: ""

    create_table :discuz_sell_credit_balances do |t|
      t.integer :user_id, null: false
      t.integer :credit_id, null: false
      t.bigint :balance, null: false, default: 0
      t.timestamps null: false
    end
    add_index :discuz_sell_credit_balances,
              %i[user_id credit_id],
              unique: true,
              name: "idx_discuz_sell_credit_balances_account"

    create_table :discuz_sell_transactions do |t|
      t.bigint :discuz_pid, null: false
      t.integer :section_index, null: false
      t.integer :buyer_user_id, null: false
      t.integer :author_user_id, null: false
      t.integer :credit_id, null: false
      t.integer :paid_amount, null: false
      t.integer :tax_percent, null: false
      t.integer :tax_amount, null: false
      t.integer :author_income, null: false
      t.timestamps null: false
    end
    add_index :discuz_sell_transactions,
              %i[discuz_pid section_index buyer_user_id],
              unique: true,
              name: "idx_discuz_sell_transactions_purchase"
    add_index :discuz_sell_transactions, :buyer_user_id
    add_index :discuz_sell_transactions, :author_user_id
  end
end
