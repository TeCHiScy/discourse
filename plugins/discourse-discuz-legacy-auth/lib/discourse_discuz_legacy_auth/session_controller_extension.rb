# frozen_string_literal: true

module DiscourseDiscuzLegacyAuth
  module SessionControllerExtension
    extend ActiveSupport::Concern

    included { before_action :check_discuz_legacy_password, only: :create }

    private

    def check_discuz_legacy_password
      return unless request.path == path("/session")

      login_name = params[:login].to_s.strip
      password = params[:password].to_s
      return if login_name.blank? || password.blank? || password.length > User.max_password_length

      user =
        find_discuz_user(
          login_name,
          login_type: "username_or_email",
          normalized_login_name: normalized_login_param,
        )
      return unless discuz_user?(user)

      raise Discourse::ReadOnly if @staff_writes_only_mode && !user.staff?
      if user.confirm_password?(password)
        clear_discuz_password_credentials!(user)
        return
      end
      return unless discuz_password_matches?(user, password)

      rate_limit_second_factor!(user)

      if login_not_approved_for?(user)
        render json: login_not_approved
        return
      end

      if payload = login_error_check(user)
        render json: payload
        return
      end

      second_factor_auth_result = authenticate_second_factor(user)
      return render(json: @second_factor_failure_payload) unless second_factor_auth_result.ok
      return not_activated(user) unless user.active && user.email_confirmed?

      result = upgrade_discuz_password!(user, password)
      if result[:password_errors].present?
        message =
          I18n.t(
            "discourse_discuz_legacy_auth.password_reset_required",
            password_error: result[:password_errors].to_sentence,
          )
        render json: { error: message, reason: "password_reset_required" }
        return
      end
      return unless result[:success]

      Invite.invalidate_for_email(user.email)
      login(user, second_factor_auth_result: second_factor_auth_result)
    end
  end
end
