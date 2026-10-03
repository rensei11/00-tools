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

async function registerCommander(sender, controlOrigin) {
  const controlTab = sender.tab;
  if (!Number.isInteger(controlTab?.id) || !Number.isInteger(controlTab?.windowId)) {
    throw new Error("Control tab information is unavailable.");
  }

  const tabs = await chrome.tabs.query({ windowId: controlTab.windowId });
  const chatTabs = tabs.filter((tab) => {
    return Number.isInteger(tab.id) &&
      tab.id !== controlTab.id &&
      Boolean(canonicalChatUrl(tab.url));
  });

  if (!chatTabs.length) {
    throw new Error("No ChatGPT conversation tab was found in the same Chrome window.");
  }

  const left = chatTabs
    .filter((tab) => Number.isInteger(tab.index) && tab.index < controlTab.index)
    .sort((a, b) => b.index - a.index);
  const candidate = left[0] || chatTabs.sort((a, b) => b.index - a.index)[0];
  const url = canonicalChatUrl(candidate.url);
  if (!url) {
    throw new Error("Commander ChatGPT URL is invalid.");
  }

  await chrome.storage.local.set({
    [COMMANDER_KEY]: {
      tabId: candidate.id,
      url,
    },
  });

  return {
    status: "REGISTERED",
    conversationUrl: url,
  };
}

async function findCommanderTab() {
  const stored = await chrome.storage.local.get(COMMANDER_KEY);
  const record = stored[COMMANDER_KEY];
  const storedUrl = canonicalChatUrl(record?.url);
  if (!storedUrl) {
    throw new Error("Commander ChatGPT tab has not been registered.");
  }

  if (Number.isInteger(record?.tabId)) {
    try {
      const tab = await chrome.tabs.get(record.tabId);
      if (canonicalChatUrl(tab.url) === storedUrl) {
        return tab;
      }
    } catch {
      // Fall through to URL search.
    }
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

async function deliverCommander(message) {
  const tab = await findCommanderTab();
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

chrome.runtime.onMessage.addListener((message, sender) => {
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
        result = await registerCommander(sender, controlOrigin);
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
