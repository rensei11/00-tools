(() => {
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

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
