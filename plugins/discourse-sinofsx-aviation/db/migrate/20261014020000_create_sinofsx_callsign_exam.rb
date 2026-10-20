# frozen_string_literal: true

class CreateSinofsxCallsignExam < ActiveRecord::Migration[7.2]
  def change
    create_table :sinofsx_exam_questions do |t|
      t.bigint :source_qid, null: false
      t.text :question_text, null: false
      t.jsonb :answers, null: false, default: {}
      t.string :correct_option, limit: 1, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :sinofsx_exam_questions, :source_qid, unique: true
    add_index :sinofsx_exam_questions, :active

    create_table :sinofsx_exam_attempts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :question_ids, null: false, default: []
      t.jsonb :option_orders, null: false, default: {}
      t.jsonb :correct_labels, null: false, default: {}
      t.boolean :last_result
      t.datetime :passed_at
      t.timestamps
    end
  end
end
