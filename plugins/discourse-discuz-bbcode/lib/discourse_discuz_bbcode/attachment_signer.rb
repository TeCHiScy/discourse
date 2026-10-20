# frozen_string_literal: true

require "base64"
require "digest"
require "uri"

module ::DiscourseDiscuzBbcode
  class DiscuzAttachmentUrl
    class ConfigurationError < StandardError
    end

    def self.url_for(attachment)
      authkey = ENV["DISCUZ_LEGACY_AUTHKEY"].to_s
      source_url = attachment_source_url
      raise ConfigurationError if authkey.blank? || source_url.blank?

      aid = attachment.aid.to_i
      timestamp = Time.current.to_i
      uid = 0
      key_digest = Digest::MD5.hexdigest(authkey)
      token_digest = Digest::MD5.hexdigest("#{aid}#{key_digest}#{timestamp}#{uid}")[0, 8]
      encoded_aid =
        Base64.strict_encode64(
          [aid, token_digest, timestamp, uid, attachment.discuz_tid.to_i].join("|"),
        )
      query = URI.encode_www_form({ mod: "attachment", aid: encoded_aid, noupdate: "yes" })

      "#{source_url}/forum.php?#{query}"
    end

    def self.configured?
      ENV["DISCUZ_LEGACY_AUTHKEY"].present? && attachment_source_url.present?
    end

    def self.attachment_source_url
      value = ENV["DISCUZ_ATTACHMENT_SOURCE_URL"].to_s.strip
      return if value.blank?

      uri = URI.parse(value)
      local_http = uri.scheme == "http" && %w[127.0.0.1 localhost ::1].include?(uri.host)
      return unless uri.scheme == "https" || local_http
      if uri.host.blank? || uri.userinfo.present? || uri.query.present? || uri.fragment.present?
        return
      end
      return if ["", "/"].exclude?(uri.path)

      uri.to_s.sub(%r{/+\z}, "")
    rescue URI::InvalidURIError
      nil
    end
    private_class_method :attachment_source_url
  end
end
