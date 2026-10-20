import { i18n } from "discourse-i18n";

export default <template>
  <@outletArgs.form.Section
    class="category-custom-settings-outlet discuz-category-rules-settings"
    @title={{i18n "category.discuz_rules.section_title"}}
  >
    <@outletArgs.form.Object @name="custom_fields" as |object|>
      <object.Field
        @format="full"
        @name="discuz_rules"
        @title={{i18n "category.discuz_rules.field_title"}}
        @type="textarea"
        as |field|
      >
        <field.Control />
      </object.Field>
    </@outletArgs.form.Object>
  </@outletArgs.form.Section>
</template>
