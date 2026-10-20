import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import CallsignExamModal from "../../components/modal/callsign-exam";

export default class CallsignExamButton extends Component {
  static shouldRender(args, { currentUser, siteSettings }) {
    return (
      siteSettings.discourse_sinofsx_aviation_callsign_exam_enabled &&
      currentUser?.id === args.model.id
    );
  }

  @service modal;

  @action
  openExam() {
    this.modal.show(CallsignExamModal);
  }

  <template>
    <li class="user-profile-controls-outlet sinofsx-callsign-exam-control">
      <DButton
        class="btn-default"
        @action={{this.openExam}}
        @translatedLabel={{i18n "sinofsx_aviation.callsign_exam.open"}}
      />
    </li>
  </template>
}
