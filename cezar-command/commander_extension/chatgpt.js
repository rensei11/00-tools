(() => {
  if (window.__renseiCezarCommanderLinkLoaded) {
    return;
  }
  window.__renseiCezarCommanderLinkLoaded = true;

  const COMPOSER_SELECTORS = [
    '#prompt-textarea[contenteditable="true"]',
    'div.ProseMirror[contenteditable="true"][role="textbox"]',
    '[data-virtualkeyboard="true"][contenteditable="true"][role="textbox"]',
  ];
  const SEND_SELECTORS = [
    '[data-testid="send-button"]',
    '#composer-submit-button',
    'button[type="submit"]',
  ];
  const ELEMENT_WAIT_MS = 30000;

  function findComposer() {
    for (const selector of COMPOSER_SELECTORS) {
      const element = document.querySelector(selector);
      if (element?.isContentEditable) {
        return element;
      }
    }
    return null;
  }

  function waitForComposer(timeoutMs) {
    const current = findComposer();
    if (current) {
      return Promise.resolve(current);
    }
    return new Promise((resolve, reject) => {
      const observer = new MutationObserver(() => {
        const element = findComposer();
        if (!element) {
          return;
        }
        clearTimeout(timer);
        observer.disconnect();
        resolve(element);
      });
      const timer = setTimeout(() => {
        observer.disconnect();
        reject(new Error("Required ChatGPT composer was not found."));
      }, timeoutMs);
      observer.observe(document.documentElement, {
        attributes: true,
        childList: true,
        subtree: true,
      });
    });
  }

  function normalizeText(value) {
    return String(value || "")
      .replace(/\u00a0/g, " ")
      .replace(/\r\n?/g, "\n")
      .replace(/\n/g, "")
      .trim();
  }

  function composerText(composer) {
    return (composer.innerText || composer.textContent || "")
      .replace(/\u00a0/g, " ")
      .replace(/\r\n?/g, "\n")
      .trim();
  }

  function setComposerText(composer, prompt) {
    composer.focus();
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(composer);
    selection?.removeAllRanges();
    selection?.addRange(range);

    const inserted = document.execCommand("insertText", false, prompt);
    if (!inserted) {
      throw new Error("ChatGPT composer did not accept text insertion.");
    }
    if (normalizeText(composerText(composer)) !== normalizeText(prompt)) {
      throw new Error("ChatGPT composer text did not match the requested prompt.");
    }
  }

  function usable(button) {
    if (!(button instanceof HTMLButtonElement)) {
      return false;
    }
    if (button.disabled || button.getAttribute("aria-disabled") === "true") {
      return false;
    }
    const rect = button.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function findSendButton(composer) {
    const form = composer.closest("form");
    if (!form) {
      return null;
    }
    for (const selector of SEND_SELECTORS) {
      const button = form.querySelector(selector);
      if (usable(button)) {
        return button;
      }
    }
    return null;
  }

  async function waitForSendButton(composer) {
    const current = findSendButton(composer);
    if (current) {
      return current;
    }
    const form = composer.closest("form");
    if (!form) {
      throw new Error("ChatGPT composer form was not found.");
    }
    return new Promise((resolve, reject) => {
      const observer = new MutationObserver(() => {
        const button = findSendButton(composer);
        if (!button) {
          return;
        }
        clearTimeout(timer);
        observer.disconnect();
        resolve(button);
      });
      const timer = setTimeout(() => {
        observer.disconnect();
        reject(new Error("ChatGPT send button did not become ready."));
      }, ELEMENT_WAIT_MS);
      observer.observe(form, {
        attributes: true,
        childList: true,
        subtree: true,
      });
    });
  }

  function conversationUrl() {
    try {
      const url = new URL(location.href);
      const match = url.pathname.match(/^\/c\/([^/]+)/);
      return match ? "https://chatgpt.com/c/" + match[1] : "";
    } catch {
      return "";
    }
  }

  async function installRegistrationButton() {
    if (!conversationUrl() || document.getElementById("rensei-cezar-commander-register")) {
      return;
    }

    try {
      const status = await chrome.runtime.sendMessage({
        type: "cezar_commander_status",
      });
      if (status?.registered) {
        return;
      }
    } catch {
      return;
    }

    const button = document.createElement("button");
    button.id = "rensei-cezar-commander-register";
    button.type = "button";
    button.textContent = "このチャットをCezar司令に登録";
    Object.assign(button.style, {
      position: "fixed",
      right: "18px",
      bottom: "86px",
      zIndex: "2147483647",
      padding: "10px 14px",
      borderRadius: "10px",
      border: "1px solid #777",
      background: "#202020",
      color: "#fff",
      fontSize: "13px",
      fontWeight: "700",
      cursor: "pointer",
      boxShadow: "0 4px 18px rgba(0,0,0,.25)",
    });

    button.addEventListener("click", async () => {
      button.disabled = true;
      button.textContent = "登録中...";
      try {
        const response = await chrome.runtime.sendMessage({
          type: "cezar_commander_register_this_tab",
          conversationUrl: conversationUrl(),
        });
        if (!response?.registered) {
          throw new Error(response?.error || "登録できませんでした");
        }
        button.textContent = "Cezar司令に登録済み";
        setTimeout(() => button.remove(), 1800);
      } catch (error) {
        button.disabled = false;
        button.textContent = "登録失敗 - もう一度押す";
        console.error(error);
      }
    });

    document.documentElement.appendChild(button);
  }

  installRegistrationButton().catch(() => {});

  function waitForSubmissionAccepted(composer, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
      const deadline = Date.now() + timeoutMs;
      const inspect = () => {
        if (!composer.isConnected) {
          resolve();
          return;
        }
        if (!composerText(composer)) {
          resolve();
          return;
        }
        if (Date.now() >= deadline) {
          reject(new Error("ChatGPT did not confirm prompt submission."));
          return;
        }
        setTimeout(inspect, 120);
      };
      inspect();
    });
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "cezar_commander_registered") {
      document.getElementById("rensei-cezar-commander-register")?.remove();
      return;
    }
    if (message?.type === "cezar_commander_probe") {
      sendResponse({
        ready: true,
        conversationUrl: conversationUrl(),
      });
      return;
    }
    if (message?.type !== "cezar_commander_inject") {
      return;
    }
    const prompt = String(message.prompt || "").trim();
    if (!prompt) {
      sendResponse({ submitted: false, error: "Prompt is empty." });
      return;
    }

    (async () => {
      try {
        const composer = await waitForComposer(ELEMENT_WAIT_MS);
        setComposerText(composer, prompt);
        const button = await waitForSendButton(composer);
        button.click();
        await waitForSubmissionAccepted(composer);
        sendResponse({
          submitted: true,
          conversationUrl: location.href,
        });
      } catch (error) {
        sendResponse({
          submitted: false,
          error: error instanceof Error ? error.message : String(error),
          conversationUrl: location.href,
        });
      }
    })();
    return true;
  });
})();
