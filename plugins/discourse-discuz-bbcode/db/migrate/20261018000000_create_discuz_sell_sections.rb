# frozen_string_literal: true

class CreateDiscuzSellSections < ActiveRecord::Migration[7.2]
  def change
    create_table :discuz_sell_sections do |t|
      t.bigint :discuz_pid, null: false
      t.integer :section_index, null: false
      t.integer :post_id, null: false
      t.bigint :author_uid, null: false
      t.integer :author_user_id, null: false
      t.integer :price, null: false, default: 0
      t.integer :credit_id, null: false, default: 0
      t.text :body, null: false
      t.jsonb :attachment_aids, null: false, default: []
      t.timestamps null: false
    end

    add_index :discuz_sell_sections,
              %i[discuz_pid section_index],
              unique: true,
              name: "idx_discuz_sell_sections_source"
    add_index :discuz_sell_sections, :post_id

    create_table :discuz_sell_purchases do |t|
      t.bigint :source_log_id, null: false
      t.bigint :discuz_pid, null: false
      t.integer :section_index, null: false
      t.bigint :discuz_uid, null: false
      t.integer :user_id
      t.integer :paid_amount, null: false, default: 0
      t.integer :credit_id, null: false, default: 0
      t.bigint :author_uid, null: false
      t.integer :author_income, null: false, default: 0
      t.integer :purchased_at, null: false, default: 0
      t.timestamps null: false
    end

    add_index :discuz_sell_purchases, :source_log_id, unique: true
    add_index :discuz_sell_purchases,
              %i[discuz_pid section_index discuz_uid],
              name: "idx_discuz_sell_purchases_entitlement"
    add_index :discuz_sell_purchases, :user_id
  end
end
