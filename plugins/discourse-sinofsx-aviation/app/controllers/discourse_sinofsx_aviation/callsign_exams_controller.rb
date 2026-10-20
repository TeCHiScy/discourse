# frozen_string_literal: true

module ::DiscourseSinofsxAviation
  class CallsignExamsController < ::ApplicationController
    requires_plugin "discourse-sinofsx-aviation"
    before_action :ensure_logged_in
    before_action :ensure_exam_enabled

    def show
      render json: CallsignExam.status_for(current_user)
    rescue CallsignExam::QuestionBankUnavailable
      render json: { configured: false, passed: false, questions: [] }
    end

    def submit
      result = CallsignExam.submit!(current_user, params[:answers] || {})
      render json: result
    rescue CallsignExam::InvalidSubmission
      render_json_error(
        I18n.t("sinofsx_aviation.callsign_exam.invalid_submission"),
        status: :unprocessable_entity,
      )
    rescue CallsignExam::QuestionBankUnavailable
      render_json_error(
        I18n.t("sinofsx_aviation.callsign_exam.not_configured"),
        status: :service_unavailable,
      )
    end

    private

    def ensure_exam_enabled
      raise Discourse::NotFound unless SiteSetting.discourse_sinofsx_aviation_callsign_exam_enabled
    end
  end
end
