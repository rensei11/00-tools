const COMMANDER_KEY = "cezarCommanderTab";
const EXTENSION_VERSION = chrome.runtime.getManifest().version;

function canonicalChatUrl(value) {
  try {
    const url = new URL(String(value || ""));
    if (url.protocol !== "https:" || url.hostname !== "chatgpt.com") {
      return "";
    }
    const match = url.pathname.match(/^\/c\/([^/]+)/);
    if (!match) {
      return "";
    }
    return "https://chatgpt.com/c/" + match[1];
  } catch {
    return "";
  }
}

async function postResult(controlOrigin, payload) {
  await fetch(controlOrigin + "/result", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...payload,
      extensionVersion: EXTENSION_VERSION,
    }),
    cache: "no-store",
  });
}

async function closeControlTab(tabId) {
  if (Number.isInteger(tabId)) {
    await chrome.tabs.remove(tabId).catch(() => {});
  }
}

async function storedCommander() {
  const stored = await chrome.storage.local.get(COMMANDER_KEY);
  const record = stored[COMMANDER_KEY];
  const url = canonicalChatUrl(record?.url);
  if (!url || !Number.isInteger(record?.tabId)) {
    return null;
  }
  try {
    const tab = await chrome.tabs.get(record.tabId);
    if (canonicalChatUrl(tab?.url) !== url) {
      return null;
    }
    return { tab, url };
  } catch {
    return null;
  }
}

async function registerCurrentChat(sender, requestedUrl) {
  const tab = sender.tab;
  const url = canonicalChatUrl(requestedUrl || tab?.url);
  if (!Number.isInteger(tab?.id) || !url || canonicalChatUrl(tab.url) !== url) {
    return {
      registered: false,
      error: "This page is not a ChatGPT conversation.",
    };
  }

  await chrome.storage.local.set({
    [COMMANDER_KEY]: {
      tabId: tab.id,
      url,
    },
  });
  return {
    registered: true,
    conversationUrl: url,
  };
}

async function confirmCommanderRegistration() {
  const existing = await storedCommander();
  if (!existing) {
    throw new Error(
      "Commander chat is not registered. Click the Cezar commander registration button in the intended ChatGPT conversation."
    );
  }
  return {
    status: "REGISTERED",
    conversationUrl: existing.url,
  };
}

async function findCommanderTab() {
  const existing = await storedCommander();
  if (existing) {
    return existing.tab;
  }

  const stored = await chrome.storage.local.get(COMMANDER_KEY);
  const record = stored[COMMANDER_KEY];
  const storedUrl = canonicalChatUrl(record?.url);
  if (!storedUrl) {
    throw new Error("Commander ChatGPT tab has not been registered.");
  }

  const tabs = await chrome.tabs.query({});
  const candidate = tabs.find((tab) => canonicalChatUrl(tab.url) === storedUrl);
  if (!candidate || !Number.isInteger(candidate.id)) {
    throw new Error("Registered commander ChatGPT conversation is not open.");
  }

  await chrome.storage.local.set({
    [COMMANDER_KEY]: {
      tabId: candidate.id,
      url: storedUrl,
    },
  });
  return candidate;
}

async function ensureContentScript(tabId) {
  try {
    const response = await chrome.tabs.sendMessage(tabId, {
      type: "cezar_commander_probe",
    });
    if (response?.ready) {
      return;
    }
  } catch {
    // Inject below.
  }
  await chrome.scripting.executeScript({
    target: { tabId },
    files: ["chatgpt.js"],
  });
}

async function injectIntoOpenChatTabs() {
  const tabs = await chrome.tabs.query({
    url: [
      "https://chatgpt.com/c/*",
    ],
  });
  for (const tab of tabs) {
    if (!Number.isInteger(tab.id)) {
      continue;
    }
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ["chatgpt.js"],
    }).catch(() => {});
  }
}

async function deliverCommander(message) {
  const tab = await findCommanderTab();
  await ensureContentScript(tab.id);
  const response = await chrome.tabs.sendMessage(tab.id, {
    type: "cezar_commander_inject",
    prompt: String(message || ""),
  });
  if (!response?.submitted) {
    throw new Error(response?.error || "Commander prompt was not submitted.");
  }
  return {
    status: "SUBMITTED",
    conversationUrl: canonicalChatUrl(response.conversationUrl),
  };
}

chrome.runtime.onInstalled.addListener(() => {
  injectIntoOpenChatTabs().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  injectIntoOpenChatTabs().catch(() => {});
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "cezar_commander_register_this_tab") {
    registerCurrentChat(sender, message.conversationUrl)
      .then(sendResponse)
      .catch((error) => {
        sendResponse({
          registered: false,
          error: error instanceof Error ? error.message : String(error),
        });
      });
    return true;
  }

  if (message?.type === "cezar_commander_probe") {
    sendResponse({ ready: true });
    return;
  }

  if (message?.type !== "cezar_command_control") {
    return;
  }

  const mode = String(message.mode || "");
  const controlOrigin = String(message.controlOrigin || "");
  const controlTabId = sender.tab?.id;

  (async () => {
    try {
      let result;
      if (mode === "register") {
        result = await confirmCommanderRegistration();
      } else if (mode === "deliver") {
        result = await deliverCommander(message.message);
      } else {
        throw new Error("Unknown command mode.");
      }
      await postResult(controlOrigin, result);
    } catch (error) {
      await postResult(controlOrigin, {
        status: "BLOCKED",
        error: error instanceof Error ? error.message : String(error),
      }).catch(() => {});
    } finally {
      await closeControlTab(controlTabId);
    }
  })();
});
