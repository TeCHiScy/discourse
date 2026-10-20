import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";

function renderDiscuzAttachment(node, aid, postId) {
  const metadataUrl = `/discuz-attachments/${aid}/metadata?post_id=${postId}`;

  ajax(metadataUrl)
    .then((metadata) => {
      if (!node.isConnected) {
        return;
      }

      if (!metadata.delivery_ready) {
        node.textContent = metadata.filename || `[Discuz 附件 ${aid}]`;
        node.title = "附件暂不可用";
        return;
      }

      const link = document.createElement("a");
      link.className = "discuz-attachment-file";
      link.href = metadata.url;
      link.textContent = metadata.filename || `附件 ${aid}`;

      if (metadata.is_image) {
        const image = document.createElement("img");
        image.className = "discuz-attachment-image";
        image.src = metadata.url;
        image.alt = metadata.filename || `附件 ${aid}`;
        image.loading = "lazy";
        image.decoding = "async";
        link.replaceChildren(image);
      }

      node.replaceWith(link);
    })
    .catch(() => {
      if (node.isConnected) {
        node.textContent = `[Discuz 附件 ${aid}]`;
      }
    });
}

export default apiInitializer((api) => {
  api.decorateCookedElement((element, helper) => {
    const postId = helper.model?.id;
    if (!Number.isInteger(postId) || postId < 1) {
      return;
    }

    element
      .querySelectorAll("span.discuz-attachment[data-aid]")
      .forEach((node) => {
        const aid = node.dataset.aid;
        if (/^[1-9]\d*$/.test(aid)) {
          renderDiscuzAttachment(node, aid, postId);
        }
      });
  });
});
