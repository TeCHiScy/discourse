# frozen_string_literal: true

require "digest"
require "bcrypt"

module DiscourseDiscuzLegacyAuth
  module LegacyCredentials
    private

    def find_discuz_user(login_name, login_type: nil, normalized_login_name: nil)
      login_type = params[:login_type].to_s if login_type.nil?

      if login_type == "uid"
        user_ids =
          UserCustomField.where(name: "discuz_uid", value: login_name).limit(2).pluck(:user_id)
      elsif login_type == "username_or_email"
        lookup_name = login_name.start_with?("@") ? login_name[1..] : login_name
        user_ids = [User.find_by_username_or_email(normalized_login_name)&.id]
        %w[import_username import_email discuz_original_email].each do |field|
          user_ids.concat(
            UserCustomField
              .where(name: field)
              .where("LOWER(user_custom_fields.value) = LOWER(?)", lookup_name)
              .limit(2)
              .pluck(:user_id),
          )
        end
        user_ids = user_ids.compact.uniq
      else
        return
      end

      users = User.where(id: user_ids.compact.uniq).to_a
      return unless users.one?

      user = users.first
      discuz_user?(user) ? user : nil
    end

    def discuz_user?(user)
      return false unless user&.custom_fields&.[]("discuz_source") == "discuz_x3.5"
      return false if user.custom_fields["discuz_uid"].blank?
      unless user.custom_fields["import_id"].to_s == user.custom_fields["discuz_uid"].to_s
        return false
      end
      if %w[t true 1].include?(user.custom_fields["discuz_missing_bbs_member"].to_s.downcase)
        return false
      end

      password_hash = user.custom_fields["discuz_password_hash"].to_s
      password_salt = user.custom_fields["discuz_password_salt"].to_s

      bcrypt_password_hash?(password_hash) ||
        (password_salt.length == 6 && password_hash.match?(/\A[0-9a-f]{32}\z/i))
    end

    def discuz_password_matches?(user, password)
      password_hash = user.custom_fields["discuz_password_hash"].to_s
      salt = user.custom_fields["discuz_password_salt"].to_s

      return BCrypt::Password.new(password_hash) == password if bcrypt_password_hash?(password_hash)

      return false unless salt.length == 6 && password_hash.match?(/\A[0-9a-f]{32}\z/i)

      password_hash = password_hash.downcase

      candidates = [Digest::MD5.hexdigest(password)]
      candidates.any? do |password_md5|
        expected = Digest::MD5.hexdigest("#{password_md5}#{salt}")
        ActiveSupport::SecurityUtils.secure_compare(password_hash, expected)
      end
    end

    def upgrade_discuz_password!(user, password)
      upgraded = false
      password_errors = []

      user.with_lock do
        if user.confirm_password?(password)
          clear_discuz_password_credentials!(user)
          upgraded = true
        elsif discuz_user?(user) && discuz_password_matches?(user, password)
          password_record = user.user_password || user.build_user_password
          password_record.password = password

          if password_record.save
            clear_discuz_password_credentials!(user)
            upgraded = true
          else
            password_errors = password_record.errors.full_messages_for(:password)
          end
        end
      end

      { success: upgraded, password_errors: password_errors }
    end

    def clear_discuz_password_credentials!(user)
      fields = user.custom_fields
      return if fields["discuz_password_hash"].blank? && fields["discuz_password_salt"].blank?

      fields.delete("discuz_password_hash")
      fields.delete("discuz_password_salt")
      user.save_custom_fields
    end

    def bcrypt_password_hash?(password_hash)
      match = /\A\$2[aby]\$(\d{2})\$[A-Za-z0-9.\/]{53}\z/.match(password_hash)
      match && match[1].to_i.between?(4, 16)
    end
  end
end
