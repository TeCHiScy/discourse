import Component from "@glimmer/component";
import { trustHTML } from "@ember/template";
import { apiInitializer } from "discourse/lib/api";

class DiscuzPostSignature extends Component {
  static shouldRender(args) {
    return (
      args.post?.discuz_signature_enabled !== false &&
      Boolean(args.post?.user_custom_fields?.discuz_signature_html)
    );
  }

  <template>
    <div class="discuz-post-signature">
      {{trustHTML @post.user_custom_fields.discuz_signature_html}}
    </div>
  </template>
}

export default apiInitializer((api) => {
  api.addModelField("post", "discuz_signature_enabled");
  api.renderAfterWrapperOutlet("post-cooked-html", DiscuzPostSignature);
});
