# frozen_string_literal: true

module ::DiscourseSinofsxAviation
  class ExamQuestion < ActiveRecord::Base
    self.table_name = "sinofsx_exam_questions"

    validates :source_qid, :question_text, :answers, :correct_option, presence: true
    validates :source_qid, uniqueness: true
    validates :correct_option, inclusion: { in: %w[A B C] }
  end
end
