# frozen_string_literal: true

module DiscourseDiscuzLegacyAuth
  module UserPasswordExtension
    extend ActiveSupport::Concern

    included { after_save :clear_discuz_legacy_credentials }

    private

    def clear_discuz_legacy_credentials
      imported_user = user
      fields = imported_user.custom_fields
      return unless fields["discuz_source"] == "discuz_x3.5"
      return if fields["discuz_password_hash"].blank? && fields["discuz_password_salt"].blank?

      fields.delete("discuz_password_hash")
      fields.delete("discuz_password_salt")
      imported_user.save_custom_fields
    end
  end
end
