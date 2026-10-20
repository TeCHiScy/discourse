# frozen_string_literal: true

require "strscan"

module DiscuzMigration
  module Smilies
    HIGH_CONFIDENCE_MAP = {
      "{:2_25:}" => ":smile:",
      "{:2_26:}" => ":open_mouth:",
      "{:2_27:}" => ":grimacing:",
      "{:2_28:}" => ":anguished:",
      "{:2_29:}" => ":grimacing:",
      "{:2_31:}" => ":smile:",
      "{:2_32:}" => ":scream:",
      "{:2_33:}" => ":rage:",
      "{:2_34:}" => ":frowning:",
      "{:2_36:}" => ":dizzy_face:",
      "{:2_37:}" => ":heart_eyes:",
      "{:2_38:}" => ":grimacing:",
      "{:2_39:}" => ":stuck_out_tongue:",
      "{:3_41:}" => ":open_mouth:",
      "{:3_43:}" => ":grimacing:",
      "{:3_44:}" => ":sob:",
      "{:3_46:}" => ":heart_eyes:",
      "{:3_48:}" => ":smile:",
      "{:3_49:}" => ":cry:",
      "{:3_50:}" => ":scream:",
      "{:3_51:}" => ":joy:",
      "{:3_52:}" => ":slightly_smiling_face:",
      "{:3_53:}" => ":face_with_head_bandage:",
      "{:3_54:}" => ":sunglasses:",
      "{:3_55:}" => ":sob:",
      "{:3_56:}" => ":face_vomiting:",
      "{:3_57:}" => ":dizzy_face:",
      "{:3_58:}" => ":sleepy:",
      "{:3_59:}" => ":star_struck:",
      "{:3_60:}" => ":cold_sweat:",
      "{:3_61:}" => ":scream:",
      "{:3_63:}" => ":wink:",
    }.freeze

    TEXT_SMILEY_MAP = {
      ":'(" => ":cry:",
      ":‘(" => ":cry:",
      ":’(" => ":cry:",
      ":handshake" => ":handshake:",
    }.freeze

    TOKEN_PATTERN = /\{(:[^{}\s]+:)\}/
    TEXT_TOKEN_PATTERN = /:(?:['‘’]\(|handshake(?![\w:]))/
    NUMERIC_TOKEN_PATTERN = /\A:\d+_\d+:\z/
    FENCE_OPEN_PATTERN = /\A[ \t]{0,3}(`{3,}|~{3,})/

    def self.convert(text)
      fence = nil

      text
        .each_line
        .each_with_object(+"") do |line, result|
          opening_fence = FENCE_OPEN_PATTERN.match(line)

          if fence
            result << line
            fence = nil if closing_fence?(line, fence)
          elsif opening_fence
            marker = opening_fence[1]
            fence = { character: marker[0], length: marker.length }
            result << line
          else
            result << convert_line(line)
          end
        end
    end

    def self.closing_fence?(line, fence)
      marker = Regexp.escape(fence[:character])
      marker_pattern = "#{marker}{#{fence[:length]},}"
      closing_pattern = Regexp.new("\\A[ \\t]{0,3}#{marker_pattern}[ \\t]*\\r?\\n?\\z")

      closing_pattern.match?(line)
    end
    private_class_method :closing_fence?

    def self.convert_line(line)
      scanner = StringScanner.new(line)
      result = +""

      until scanner.eos?
        delimiter = scanner.scan(/`+/)
        if delimiter
          result << delimiter
          code_span = scanner.scan_until(/(?<!`)#{Regexp.escape(delimiter)}(?!`)/)

          if code_span
            result << code_span
          else
            result << scanner.rest
            break
          end

          next
        end

        token = scanner.scan(TOKEN_PATTERN)
        if token
          shortcode = HIGH_CONFIDENCE_MAP[token]
          if shortcode
            result << shortcode
          else
            code = token[1...-1]
            result << (NUMERIC_TOKEN_PATTERN.match?(code) ? token : code)
          end

          next
        end

        text_token = scanner.scan(TEXT_TOKEN_PATTERN)
        if text_token
          result << TEXT_SMILEY_MAP.fetch(text_token)
          next
        end

        result << scanner.getch
      end

      result
    end
    private_class_method :convert_line
  end
end
