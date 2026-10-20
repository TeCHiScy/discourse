# frozen_string_literal: true

module ::DiscourseSinofsxAviation
  class CallsignExam
    LABELS = %w[A B C].freeze
    QUESTION_COUNT = 3

    class QuestionBankUnavailable < StandardError
    end

    class InvalidSubmission < StandardError
    end

    def self.status_for(user)
      attempt = ExamAttempt.create_or_find_by!(user_id: user.id)

      if user.custom_fields.to_h["sinofsx_callsign"].present? && !attempt.passed_at?
        attempt.update!(passed_at: Time.current)
      end

      return { configured: true, passed: true, questions: [] } if attempt.passed_at?

      if attempt.question_ids.blank?
        return unconfigured unless create_questions!(attempt)
      end

      questions = questions_for(attempt)
      if questions.blank?
        attempt.update!(question_ids: [], option_orders: {}, correct_labels: {}, last_result: nil)
        return unconfigured
      end

      {
        configured: true,
        passed: false,
        failed: attempt.last_result == false,
        questions: questions,
      }
    end

    def self.submit!(user, submitted_answers)
      attempt = ExamAttempt.find_by(user_id: user.id)
      return { configured: true, passed: true, failed: false } if attempt&.passed_at?
      raise InvalidSubmission if attempt.blank? || attempt.question_ids.blank?

      answers =
        (
          if submitted_answers.respond_to?(:to_unsafe_h)
            submitted_answers.to_unsafe_h
          else
            submitted_answers.to_h
          end
        )
      answers = answers.transform_keys(&:to_s).transform_values { |value| value.to_s.upcase }
      question_ids = attempt.question_ids.map(&:to_s)

      unless answers.keys.sort == question_ids.sort &&
               answers.values.all? { |label| LABELS.include?(label) }
        raise InvalidSubmission
      end

      passed =
        question_ids.all? do |question_id|
          answers[question_id] == attempt.correct_labels[question_id]
        end
      attempt.update!(last_result: passed, passed_at: (Time.current if passed))

      status_for(user)
    end

    def self.create_questions!(attempt)
      questions =
        ExamQuestion.where(active: true).order(Arel.sql("RANDOM()")).limit(QUESTION_COUNT).to_a
      return false if questions.length < QUESTION_COUNT

      option_orders = {}
      correct_labels = {}

      questions.each do |question|
        correct_option = question.correct_option.to_s.upcase
        option_order = LABELS.shuffle
        correct_index = option_order.index(correct_option)
        raise QuestionBankUnavailable if correct_index.nil?

        question_id = question.source_qid.to_s
        option_orders[question_id] = option_order
        correct_labels[question_id] = LABELS[correct_index]

        answer_texts = question.answers.stringify_keys
        raise QuestionBankUnavailable unless LABELS.all? { |label| answer_texts[label].present? }
      end

      attempt.update!(
        question_ids: questions.map(&:source_qid),
        option_orders: option_orders,
        correct_labels: correct_labels,
        last_result: nil,
      )
      true
    end
    private_class_method :create_questions!

    def self.questions_for(attempt)
      question_ids = attempt.question_ids.map(&:to_i)
      questions_by_id =
        ExamQuestion.where(active: true, source_qid: question_ids).index_by(&:source_qid)
      return [] unless questions_by_id.size == QUESTION_COUNT

      question_ids.map do |question_id|
        question = questions_by_id[question_id]
        option_order = attempt.option_orders[question_id.to_s]
        return [] unless option_order.is_a?(Array) && option_order.size == LABELS.size

        answers = question.answers.stringify_keys
        {
          id: question_id,
          input_name: "question-#{question_id}",
          question: question.question_text,
          answers:
            option_order.each_with_index.map do |option, index|
              { label: LABELS[index], text: answers[option] }
            end,
        }
      end
    end
    private_class_method :questions_for

    def self.unconfigured
      { configured: false, passed: false, questions: [] }
    end
    private_class_method :unconfigured
  end
end
