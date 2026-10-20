# frozen_string_literal: true

class CreateDiscuzMedalMappings < ActiveRecord::Migration[7.2]
  def change
    create_table :discuz_medal_mappings do |t|
      t.bigint :discuz_medalid, null: false
      t.integer :badge_id, null: false
      t.text :source_name, null: false
      t.text :source_description
      t.text :source_image
      t.boolean :source_available, null: false, default: false
      t.timestamps null: false
    end

    add_index :discuz_medal_mappings, :discuz_medalid, unique: true
    add_index :discuz_medal_mappings, :badge_id, unique: true

    create_table :discuz_user_medal_grants do |t|
      t.bigint :discuz_uid, null: false
      t.bigint :discuz_medalid, null: false
      t.integer :user_id, null: false
      t.integer :badge_id, null: false
      t.bigint :source_expiration_at, null: false, default: 0
      t.datetime :source_awarded_at
      t.timestamps null: false
    end

    add_index :discuz_user_medal_grants,
              %i[discuz_uid discuz_medalid],
              unique: true,
              name: "index_discuz_user_medal_grants_on_source_pair"
    add_index :discuz_user_medal_grants, :user_id
    add_index :discuz_user_medal_grants, :badge_id
  end
end
