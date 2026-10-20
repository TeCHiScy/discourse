# frozen_string_literal: true

# name: discourse-sinofsx-aviation
# about: Displays migrated SinoFSX flight and virtual-airline profile data.
# version: 0.1.0
# authors: SinoFSX

enabled_site_setting :discourse_sinofsx_aviation_callsign_exam_enabled

register_asset "stylesheets/common/sinofsx-aviation.scss"

Discourse::Application.routes.append do
  get "/sinofsx-aviation/callsign-exam", to: "discourse_sinofsx_aviation/callsign_exams#show"
  post "/sinofsx-aviation/callsign-exam", to: "discourse_sinofsx_aviation/callsign_exams#submit"
end

after_initialize do
  require_relative "app/models/discourse_sinofsx_aviation/exam_question"
  require_relative "app/models/discourse_sinofsx_aviation/exam_attempt"
  require_relative "lib/discourse_sinofsx_aviation/callsign_exam"
  require_relative "app/controllers/discourse_sinofsx_aviation/callsign_exams_controller"

  {
    "sinofsx_callsign" => :string,
    "sinofsx_company_name" => :string,
    "sinofsx_atc_rank" => :string,
    "sinofsx_pilot_hours" => :string,
    "sinofsx_atc_hours" => :string,
  }.each do |field, type|
    register_user_custom_field_type(field, type, max_length: 120)
    allow_public_user_custom_field(field)
  end
end
