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
      restricted =
        [attachment.readperm, attachment.attachment_price, attachment.topic_price].any? do |value|
          value.to_i != 0
        end
      raise Discourse::NotFound if restricted

      [attachment, post]
    end
  end
end
