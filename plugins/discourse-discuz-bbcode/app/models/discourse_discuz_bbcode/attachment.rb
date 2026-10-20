# frozen_string_literal: true

module ::DiscourseDiscuzBbcode
  class Attachment < ActiveRecord::Base
    self.table_name = "discuz_attachments"

    belongs_to :post
    belongs_to :user, optional: true

    validates :aid, :discuz_pid, :discuz_tid, :discuz_uid, :object_key, :filename, presence: true
    validates :aid, uniqueness: true
  end
end
