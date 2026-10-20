# frozen_string_literal: true

module ::DiscourseSinofsxAviation
  class ExamAttempt < ActiveRecord::Base
    self.table_name = "sinofsx_exam_attempts"

    belongs_to :user

    validates :user_id, uniqueness: true
  end
end
