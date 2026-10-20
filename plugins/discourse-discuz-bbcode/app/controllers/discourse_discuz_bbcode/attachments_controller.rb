# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class AttachmentsController < ::ApplicationController
    requires_plugin "discourse-discuz-bbcode"

    skip_before_action :check_xhr, only: :show

    def metadata
      attachment, = find_accessible_attachment!

      response.headers["Cache-Control"] = "private, no-store"
      render json: {
               filename: attachment.filename,
               is_image: attachment.is_image,
               delivery_ready: DiscuzAttachmentUrl.configured?,
               url: "/discuz-attachments/#{attachment.aid}?post_id=#{attachment.post_id}",
             }
    end

    def show
      attachment, = find_accessible_attachment!
      raise Discourse::NotFound unless DiscuzAttachmentUrl.configured?

      response.headers["Cache-Control"] = "private, no-store"
      redirect_to(DiscuzAttachmentUrl.url_for(attachment), allow_other_host: true)
    end

    def list
      raise Discourse::NotFound unless SiteSetting.discourse_discuz_bbcode_attachments_enabled

      post = Post.find_by(id: strict_positive_integer(params[:post_id]))
      raise Discourse::NotFound unless post && guardian.can_see?(post)

      excluded_aids = parsed_excluded_aids
      protected_sections =
        if SiteSetting.discourse_discuz_bbcode_sell_enabled
          SellSection.where(post_id: post.id).to_a
        else
          []
        end
      items =
        Attachment
          .where(post_id: post.id)
          .order(:aid)
          .filter_map do |attachment|
            next if excluded_aids.include?(attachment.aid.to_i)
            next if protected_section_for(attachment, protected_sections)
            next if restricted_source_attachment?(attachment)

            {
              aid: attachment.aid,
              filename: attachment.filename,
              is_image: attachment.is_image,
              delivery_ready: DiscuzAttachmentUrl.configured?,
              url: "/discuz-attachments/#{attachment.aid}?post_id=#{attachment.post_id}",
            }
          end

      response.headers["Cache-Control"] = "private, no-store"
      render json: { attachments: items }
    end

    private

    def find_accessible_attachment!
      raise Discourse::NotFound unless SiteSetting.discourse_discuz_bbcode_attachments_enabled

      attachment = Attachment.find_by(aid: params[:aid].to_i)
      requested_post_id = params[:post_id].to_s
      valid_post_id = requested_post_id.match?(/\A[1-9]\d*\z/)
      unless attachment && valid_post_id && requested_post_id.to_i == attachment.post_id
        raise Discourse::NotFound
      end

      post = Post.find_by(id: attachment.post_id)
      raise Discourse::NotFound unless post && guardian.can_see?(post)

      # Discuz reads from the configured attachment directory when remote=0. On
      # this site that path is an s3fs COS mount. For either source flag, delegate
      # file access to Discuz's own attachment handler rather than reading blobs here.
      # Discuz read levels and paid-post/attachment credit logs have not been mapped yet.
      # Deny these objects until an explicit Discourse entitlement adapter is installed.
      sections =
        if SiteSetting.discourse_discuz_bbcode_sell_enabled
          SellSection.where(post_id: post.id).to_a
        else
          []
        end
      section = protected_section_for(attachment, sections)
      raise Discourse::NotFound if section && !SellAccess.allowed?(section, current_user, guardian)

      raise Discourse::NotFound if restricted_source_attachment?(attachment)

      [attachment, post]
    end

    def protected_section_for(attachment, sections)
      sections.find { |section| section.protected_aid?(attachment.aid) }
    end

    def restricted_source_attachment?(attachment)
      [attachment.readperm, attachment.attachment_price, attachment.topic_price].any? do |value|
        value.to_i != 0
      end
    end

    def strict_positive_integer(value)
      text = value.to_s
      raise Discourse::NotFound unless text.match?(/\A[1-9]\d*\z/)

      text.to_i
    end

    def parsed_excluded_aids
      values = params[:exclude].to_s.split(",", -1)
      return [] if values.empty? || values == [""]
      unless values.length <= 2_000 && values.all? { |value| value.match?(/\A[1-9]\d*\z/) }
        raise Discourse::NotFound
      end

      values.map(&:to_i).to_set
    end
  end
end
