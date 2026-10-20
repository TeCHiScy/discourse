# frozen_string_literal: true

class CreateDiscuzAttachments < ActiveRecord::Migration[7.2]
  def change
    create_table :discuz_attachments do |t|
      t.bigint :aid, null: false
      t.bigint :discuz_pid, null: false
      t.bigint :discuz_tid, null: false
      t.bigint :discuz_uid, null: false
      t.integer :post_id, null: false
      t.integer :user_id
      t.string :object_key, null: false
      t.string :filename, null: false
      t.bigint :filesize, null: false, default: 0
      t.boolean :is_image, null: false, default: false
      t.boolean :has_thumbnail, null: false, default: false
      t.boolean :is_remote, null: false, default: false
      t.integer :readperm, null: false, default: 0
      t.integer :attachment_price, null: false, default: 0
      t.integer :topic_price, null: false, default: 0
      t.integer :uploaded_at, null: false, default: 0
      t.timestamps null: false
    end

    add_index :discuz_attachments, :aid, unique: true
    add_index :discuz_attachments, :post_id
    add_index :discuz_attachments, :discuz_pid
  end
end
