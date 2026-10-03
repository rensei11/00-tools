(() => {
  const mode = document.querySelector('meta[name="cezar-command-mode"]')?.content?.trim() || "";
  const message = document.querySelector('meta[name="cezar-command-message"]')?.content || "";
  if (!mode) {
    return;
  }

  chrome.runtime.sendMessage({
    type: "cezar_command_control",
    mode,
    message,
    controlOrigin: location.origin,
  }).catch(() => {});
})();
