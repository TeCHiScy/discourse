import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";

function renderAttachmentNode(node, attachment, aid) {
  if (!node.isConnected) {
    return;
  }

  if (!attachment.delivery_ready || !attachment.url) {
    node.textContent = attachment.filename || `[Discuz 附件 ${aid}]`;
    node.title = "附件暂不可用";
    return;
  }

  const link = document.createElement("a");
  link.className = "discuz-attachment-file";
  link.href = attachment.url;
  link.textContent = attachment.filename || `附件 ${aid}`;

  if (attachment.is_image) {
    const image = document.createElement("img");
    image.className = "discuz-attachment-image";
    image.src = attachment.url;
    image.alt = attachment.filename || `附件 ${aid}`;
    image.loading = "lazy";
    image.decoding = "async";
    link.replaceChildren(image);
  }

  node.replaceWith(link);
}

function renderDiscuzAttachment(node, aid, postId) {
  const metadataUrl = `/discuz-attachments/${aid}/metadata?post_id=${postId}`;

  ajax(metadataUrl)
    .then((metadata) => renderAttachmentNode(node, metadata, aid))
    .catch(() => {
      if (node.isConnected) {
        node.textContent = `[Discuz 附件 ${aid}]`;
      }
    });
}

function renderAttachmentMarkers(root, postId) {
  root
    .querySelectorAll("span[data-discuz-attachment='true'][data-aid]")
    .forEach((node) => {
      const aid = node.dataset.aid;
      if (/^[1-9]\d*$/.test(aid)) {
        renderDiscuzAttachment(node, aid, postId);
      }
    });
}

function sellCurrencyLabel(section) {
  return `${section.credit_unit || ""}${section.credit_title || "积分"}`;
}

function renderUnlockedSellSection(node, section, postId) {
  node.classList.remove("discuz-sell-section-locked");
  node.classList.add("discuz-sell-section-unlocked");
  node.innerHTML = section.html;
  renderAttachmentMarkers(node, postId);
}

function renderLockedSellSection(node, section, pid, cid, postId) {
  node.classList.add("discuz-sell-section-locked");
  node.replaceChildren();

  const price = Number(section.price) || 0;
  const currency = sellCurrencyLabel(section);
  const details = document.createElement("span");
  if (section.requires_login) {
    details.textContent = `付费内容（${price} ${currency}），登录后可购买。`;
    node.appendChild(details);
    const login = document.createElement("a");
    login.href = "/login";
    login.textContent = "登录";
    node.appendChild(login);
    return;
  }

  const balance = Number(section.balance) || 0;
  if (!section.purchase_enabled || !section.can_purchase) {
    details.textContent = `付费内容（${price} ${currency}），当前无法购买。`;
    node.appendChild(details);
    return;
  }

  details.textContent = `付费内容：${price} ${currency}；当前余额：${balance} ${currency}。`;
  node.appendChild(details);

  const button = document.createElement("button");
  button.type = "button";
  button.className = "btn btn-primary discuz-sell-purchase-button";
  button.disabled = balance < price;
  button.textContent =
    balance < price ? "积分不足" : `支付 ${price} ${currency} 并解锁`;
  node.appendChild(button);

  const feedback = document.createElement("span");
  feedback.className = "discuz-sell-purchase-feedback";
  node.appendChild(feedback);

  let confirmationPending = false;
  let cancelButton;
  button.addEventListener("click", () => {
    if (!confirmationPending) {
      confirmationPending = true;
      const taxPercent = Number(section.tax_percent) || 0;
      const authorIncome = price - Math.floor((price * taxPercent) / 100);
      feedback.textContent = `确认支付 ${price} ${currency} 吗？作者将获得 ${authorIncome} ${currency}。`;
      button.textContent = "确认购买";
      cancelButton = document.createElement("button");
      cancelButton.type = "button";
      cancelButton.className = "btn btn-default discuz-sell-cancel-button";
      cancelButton.textContent = "取消";
      node.insertBefore(cancelButton, feedback);
      cancelButton.addEventListener("click", () => {
        confirmationPending = false;
        cancelButton.remove();
        button.textContent = `支付 ${price} ${currency} 并解锁`;
        feedback.textContent = "";
      });
      return;
    }

    confirmationPending = false;
    cancelButton.remove();
    button.disabled = true;
    button.textContent = "处理中…";
    feedback.textContent = "";
    ajax(`/discuz-sell-sections/${pid}/${cid}/purchase`, {
      type: "POST",
      data: { post_id: postId },
    })
      .then((result) => {
        if (node.isConnected) {
          renderUnlockedSellSection(node, result, postId);
        }
      })
      .catch((error) => {
        if (!node.isConnected) {
          return;
        }

        const response =
          error?.responseJSON || error?.jqXHR?.responseJSON || {};
        if (response.error === "insufficient_credit") {
          feedback.textContent = `积分不足：需要 ${response.required} ${currency}，当前余额 ${response.available} ${currency}。`;
          button.textContent = "积分不足";
          return;
        }

        feedback.textContent =
          response.error === "already_purchased"
            ? "已购买，请刷新页面查看内容。"
            : "购买失败，请刷新后重试。";
        button.disabled = false;
        button.textContent = `支付 ${price} ${currency} 并解锁`;
      });
  });
}

function appendUnreferencedAttachments(root, postId) {
  if (root.dataset.discuzAttachmentListLoaded === "true") {
    return;
  }
  root.dataset.discuzAttachmentListLoaded = "true";

  const explicitAids = [
    ...root.querySelectorAll("span[data-discuz-attachment='true'][data-aid]"),
  ]
    .map((node) => node.dataset.aid)
    .filter((aid) => /^[1-9]\d*$/.test(aid));
  const query =
    explicitAids.length > 0 ? `?exclude=${explicitAids.join(",")}` : "";

  ajax(`/discuz-posts/${postId}/attachments${query}`)
    .then(({ attachments = [] }) => {
      if (!root.isConnected || attachments.length === 0) {
        return;
      }

      const list = document.createElement("div");
      list.className = "discuz-attachment-list";
      attachments.forEach((attachment) => {
        const node = document.createElement("span");
        node.className = "discuz-attachment-list-item";
        list.appendChild(node);
        renderAttachmentNode(node, attachment, attachment.aid);
      });
      root.appendChild(list);
    })
    .catch(() => {});
}

function renderDiscuzSellSection(node, postId) {
  node.classList.add("discuz-sell-section");
  const pid = node.dataset.pid;
  const cid = node.dataset.cid;
  if (!/^[1-9]\d*$/.test(pid) || !/^\d+$/.test(cid)) {
    return;
  }

  ajax(`/discuz-sell-sections/${pid}/${cid}?post_id=${postId}`)
    .then((section) => {
      if (!node.isConnected) {
        return;
      }

      if (section.locked) {
        renderLockedSellSection(node, section, pid, cid, postId);
        return;
      }

      renderUnlockedSellSection(node, section, postId);
    })
    .catch(() => {
      if (node.isConnected) {
        node.classList.add("discuz-sell-section-locked");
        node.textContent = "付费内容暂不可用";
      }
    });
}

export default apiInitializer((api) => {
  api.decorateCookedElement((element, helper) => {
    const postId = helper.model?.id;
    if (!Number.isInteger(postId) || postId < 1) {
      return;
    }

    renderAttachmentMarkers(element, postId);
    element
      .querySelectorAll(
        "span[data-discuz-sell-section='true'][data-pid][data-cid]"
      )
      .forEach((node) => renderDiscuzSellSection(node, postId));
    appendUnreferencedAttachments(element, postId);
  });
});
