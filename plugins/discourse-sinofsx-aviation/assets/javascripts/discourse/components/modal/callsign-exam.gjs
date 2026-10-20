import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

const EXAM_URL = "/sinofsx-aviation/callsign-exam";

export default class CallsignExamModal extends Component {
  @tracked configured = false;
  @tracked failed = false;
  @tracked loading = true;
  @tracked passed = false;
  @tracked questions = [];
  @tracked submitting = false;
  @tracked answers = {};

  constructor() {
    super(...arguments);
    this.loadExam();
  }

  get canSubmit() {
    return (
      this.questions.length > 0 &&
      this.questions.every((question) => this.answers[question.id])
    );
  }

  get examUnavailable() {
    return !this.configured;
  }

  get submitDisabled() {
    return this.submitting || !this.canSubmit;
  }

  @action
  async loadExam() {
    this.loading = true;
    try {
      this.applyResult(await ajax(EXAM_URL));
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  @action
  selectAnswer(questionId, event) {
    this.answers = { ...this.answers, [questionId]: event.target.value };
    this.questions = this.questions.map((question) =>
      question.id === questionId
        ? {
            ...question,
            answers: question.answers.map((answer) => ({
              ...answer,
              checked: answer.label === event.target.value,
            })),
          }
        : question
    );
  }

  @action
  async submit() {
    this.submitting = true;
    try {
      this.applyResult(
        await ajax(EXAM_URL, {
          type: "POST",
          data: { answers: this.answers },
        })
      );
      this.answers = {};
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.submitting = false;
    }
  }

  applyResult(result) {
    this.configured = result.configured;
    this.failed = result.failed;
    this.passed = result.passed;
    this.questions = (result.questions || []).map((question) => ({
      ...question,
      answers: question.answers.map((answer) => ({
        ...answer,
        checked: false,
      })),
    }));
  }

  <template>
    <DModal
      class="sinofsx-callsign-exam-modal"
      @closeModal={{@closeModal}}
      @title={{i18n "sinofsx_aviation.callsign_exam.title"}}
    >
      <:body>
        {{#if this.loading}}
          <p>{{i18n "sinofsx_aviation.callsign_exam.loading"}}</p>
        {{else if this.passed}}
          <p>{{i18n "sinofsx_aviation.callsign_exam.already_passed"}}</p>
        {{else if this.examUnavailable}}
          <p>{{i18n "sinofsx_aviation.callsign_exam.not_configured"}}</p>
        {{else}}
          {{#if this.failed}}
            <p class="alert alert-error">
              {{i18n "sinofsx_aviation.callsign_exam.failed"}}
            </p>
          {{/if}}
          <div>
            {{#each this.questions as |question|}}
              <fieldset class="sinofsx-callsign-exam-question">
                <legend>{{question.question}}</legend>
                {{#each question.answers as |answer|}}
                  <label>
                    <input
                      checked={{answer.checked}}
                      name={{question.input_name}}
                      type="radio"
                      value={{answer.label}}
                      {{on "change" (fn this.selectAnswer question.id)}}
                    />
                    {{answer.label}}.
                    {{answer.text}}
                  </label>
                {{/each}}
              </fieldset>
            {{/each}}
          </div>
        {{/if}}
      </:body>
      <:footer>
        {{#if this.configured}}
          {{#unless this.passed}}
            <DButton
              class="btn-primary"
              @action={{this.submit}}
              @disabled={{this.submitDisabled}}
              @translatedLabel={{i18n "sinofsx_aviation.callsign_exam.submit"}}
            />
          {{/unless}}
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
