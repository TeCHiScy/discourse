import { i18n } from "discourse-i18n";

export default <template>
  {{#let @outletArgs.user.custom_fields as |fields|}}
    {{#if fields.sinofsx_callsign}}
      <div class="user-card-metadata-outlet sinofsx-aviation">
        <span class="desc">{{i18n "sinofsx_aviation.callsign"}}</span>
        <span>{{fields.sinofsx_callsign}}</span>

        {{#if fields.sinofsx_company_name}}
          <span class="desc">{{i18n "sinofsx_aviation.airline"}}</span>
          <span>{{fields.sinofsx_company_name}}</span>
        {{/if}}

        {{#if fields.sinofsx_atc_rank}}
          <span class="desc">{{i18n "sinofsx_aviation.atc_rank"}}</span>
          <span>{{fields.sinofsx_atc_rank}}</span>
        {{/if}}

        {{#if fields.sinofsx_pilot_hours}}
          <span class="desc">{{i18n "sinofsx_aviation.pilot_hours"}}</span>
          <span>{{fields.sinofsx_pilot_hours}}</span>
        {{/if}}

        {{#if fields.sinofsx_atc_hours}}
          <span class="desc">{{i18n "sinofsx_aviation.atc_hours"}}</span>
          <span>{{fields.sinofsx_atc_hours}}</span>
        {{/if}}
      </div>
    {{/if}}
  {{/let}}
</template>
