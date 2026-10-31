const { contextBridge, ipcRenderer, webUtils } = require("electron");
contextBridge.exposeInMainWorld("desktop", {
  open: () => ipcRenderer.invoke("open"),
  readDrop: (file) =>
    ipcRenderer.invoke("read-drop", webUtils.getPathForFile(file)),
  save: (text, saveAs) => ipcRenderer.invoke("save", text, saveAs),
  document: (state) => ipcRenderer.invoke("document", state),
  confirm: () => ipcRenderer.invoke("confirm"),
  export: (options) => ipcRenderer.invoke("export", options),
  copy: (bytes) => ipcRenderer.invoke("clipboard", bytes),
  paste: () => ipcRenderer.invoke("paste"),
  font: () => ipcRenderer.invoke("font"),
  platform: () => ipcRenderer.invoke("platform"),
  fonts: () => ipcRenderer.invoke("fonts"),
  cutout: (png) => ipcRenderer.invoke("cutout", png),
  close: () => ipcRenderer.invoke("close"),
  onCommand: (callback) => {
    const listener = (_event, action, data) => callback(action, data);
    ipcRenderer.on("command", listener);
    return () => ipcRenderer.removeListener("command", listener);
  },
});
