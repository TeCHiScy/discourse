import { trustHTML } from "@ember/template";
import { i18n } from "discourse-i18n";

export default <template>
  {{#if @outletArgs.category.discuz_rules_html}}
    <section class="discuz-category-rules">
      <h3 class="discuz-category-rules__title">
        {{i18n "category.discuz_rules.display_title"}}
      </h3>
      <div class="discuz-category-rules__content">
        {{trustHTML @outletArgs.category.discuz_rules_html}}
      </div>
    </section>
  {{/if}}
</template>
