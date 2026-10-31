const {
  app,
  BrowserWindow,
  Menu,
  dialog,
  ipcMain,
  clipboard,
  nativeImage,
  protocol,
  net,
} = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const sharp = require("sharp");
const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const run = promisify(execFile);
const os = require("node:os");
let win,
  dirty = false,
  projectPath = null,
  pendingFile = null;
const openedProjects = new Set();
const smoke = process.env.FILTERED_TEST === "1";
if (smoke)
  app.setPath(
    "userData",
    path.join(os.tmpdir(), "filtered-test-profile-" + process.pid),
  );
protocol.registerSchemesAsPrivileged([
  {
    scheme: "filtered",
    privileges: { standard: true, secure: true, supportFetchAPI: true },
  },
]);
function send(action, data) {
  win?.webContents.send("command", action, data);
}
function guard(event) {
  if (
    event.sender !== win?.webContents ||
    event.senderFrame !== win.webContents.mainFrame ||
    !event.senderFrame.url.startsWith("filtered://app/")
  )
    throw new Error("Unauthorized request");
}
function handle(name, fn) {
  ipcMain.handle(name, async (event, ...args) => {
    guard(event);
    return fn(...args);
  });
}
async function atomicWrite(file, data) {
  const tmp = file + "." + process.pid + ".tmp";
  try {
    await fs.writeFile(tmp, data);
    await fs.rename(tmp, file);
  } finally {
    await fs.rm(tmp, { force: true }).catch(() => {});
  }
}
async function readFile(file) {
  const stat = await fs.stat(file);
  if (stat.size > 350 * 1024 * 1024)
    throw new Error("File is too large (350 MB maximum).");
  const data = await fs.readFile(file);
  if (path.extname(file).toLowerCase() === ".ftrd") {
    openedProjects.add(file);
    return {
      type: "project",
      name: path.basename(file),
      text: data.toString("utf8"),
      path: file,
    };
  }
  let image = sharp(data, { animated: false, limitInputPixels: 100000000 });
  let meta;
  try {
    meta = await image.metadata();
    if (meta.format === "heif")
      await image.clone().resize(1, 1).png().toBuffer();
  } catch (error) {
    if (
      process.platform !== "darwin" ||
      ![".heic", ".heif"].includes(path.extname(file).toLowerCase())
    )
      throw error;
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "filtered-import-"));
    try {
      const output = path.join(dir, "image.png");
      await run("/usr/bin/sips", [
        "-s",
        "format",
        "png",
        file,
        "--out",
        output,
      ]);
      image = sharp(await fs.readFile(output));
      meta = await image.metadata();
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  }
  if ((meta.width || 0) * (meta.pageHeight || meta.height || 0) > 67108864)
    throw new Error("Image exceeds 64 megapixels.");
  return {
    type: "image",
    name: path.basename(file),
    png: (await image.rotate().png().toBuffer()).toString("base64"),
    animated:
      meta.pages > 1 && meta.format === "gif" ? data.toString("base64") : null,
  };
}
handle("open", async () => {
  const result = await dialog.showOpenDialog(win, {
    properties: ["openFile"],
    filters: [
      {
        name: "Images & Filtered projects",
        extensions: [
          "ftrd",
          "png",
          "jpg",
          "jpeg",
          "webp",
          "gif",
          "tif",
          "tiff",
          "heic",
          "avif",
          "bmp",
        ],
      },
    ],
  });
  return result.canceled ? null : readFile(result.filePaths[0]);
});
handle("read-drop", async (file) => {
  if (typeof file !== "string") throw new Error("Invalid file");
  return readFile(file);
});
handle("save", async (text, saveAs) => {
  if (typeof text !== "string" || text.length > 500 * 1024 * 1024)
    throw new Error("Invalid project");
  JSON.parse(text);
  let target = projectPath;
  if (!target || saveAs) {
    const result = await dialog.showSaveDialog(win, {
      defaultPath: target || "Untitled.ftrd",
      filters: [{ name: "Filtered Project", extensions: ["ftrd"] }],
    });
    if (result.canceled) return null;
    target = result.filePath;
  }
  await atomicWrite(target, text);
  projectPath = target;
  dirty = false;
  win.setDocumentEdited(false);
  app.addRecentDocument(target);
  return path.basename(target);
});
handle("document", async (state) => {
  dirty = !!state.dirty;
  win.setDocumentEdited(dirty);
  if (state.openPath) {
    if (!openedProjects.has(state.openPath))
      throw new Error("Project was not opened through the file dialog");
    projectPath = state.openPath;
    app.addRecentDocument(projectPath);
  }
  if (state.resetPath) projectPath = null;
  win.setTitle(`${state.name || "Untitled"}${dirty ? " •" : ""} — Filtered`);
});
handle("confirm", async () => {
  if (!dirty) return "discard";
  const { response } = await dialog.showMessageBox(win, {
    type: "question",
    message: "Save your changes?",
    detail: "Your unsaved changes will be lost if you discard them.",
    buttons: ["Save", "Cancel", "Discard"],
    defaultId: 0,
    cancelId: 1,
  });
  return ["save", "cancel", "discard"][response];
});
handle(
  "export",
  async ({
    bytes,
    format,
    quality = 90,
    dpi = 72,
    author = "",
    name = "Filtered",
    batch = [],
  }) => {
    if (!["png", "jpeg", "webp", "tiff", "gif", "heic"].includes(format))
      throw new Error("Unsupported export format");
    const data = Buffer.from(bytes);
    if (data.length > 400 * 1024 * 1024) throw new Error("Export too large");
    const result = await dialog.showSaveDialog(win, {
      defaultPath: `${path.basename(name, path.extname(name))}.${format === "jpeg" ? "jpg" : format}`,
      filters: [
        {
          name: format.toUpperCase(),
          extensions: [format === "jpeg" ? "jpg" : format],
        },
      ],
    });
    if (result.canceled) return false;
    async function encode(input, target) {
      if (format === "gif") {
        await atomicWrite(target, input);
        return;
      }
      let pipeline = sharp(input).withMetadata({
        density: Math.max(1, Math.min(1200, dpi)),
      });
      if (author)
        pipeline = pipeline.withExif({
          IFD0: { Artist: String(author).slice(0, 1000) },
        });
      if (format === "heic") {
        if (process.platform !== "darwin")
          throw new Error(
            "HEIC export requires macOS. Use PNG or TIFF on this platform.",
          );
        const dir = await fs.mkdtemp(path.join(os.tmpdir(), "filtered-heic-"));
        try {
          await pipeline.png().toFile(path.join(dir, "source.png"));
          await run("/usr/bin/sips", [
            "-s",
            "format",
            "heic",
            path.join(dir, "source.png"),
            "--out",
            path.join(dir, "output.heic"),
          ]);
          await atomicWrite(
            target,
            await fs.readFile(path.join(dir, "output.heic")),
          );
        } finally {
          await fs.rm(dir, { recursive: true, force: true });
        }
        return;
      }
      if (format === "jpeg")
        pipeline = pipeline.flatten({ background: "#ffffff" });
      await atomicWrite(
        target,
        await pipeline
          .toFormat(format, { quality: Math.max(1, Math.min(100, quality)) })
          .toBuffer(),
      );
    }
    await encode(data, result.filePath);
    for (const item of batch) {
      if (![2, 3].includes(item.scale)) throw new Error("Invalid export scale");
      const ext = path.extname(result.filePath);
      await encode(
        Buffer.from(item.bytes),
        result.filePath.slice(0, -ext.length) + `@${item.scale}x` + ext,
      );
    }
    return true;
  },
);
handle("clipboard", async (bytes) => {
  const image = nativeImage.createFromBuffer(Buffer.from(bytes));
  if (image.isEmpty()) throw new Error("Image could not be copied.");
  clipboard.writeImage(image);
  return true;
});
handle("paste", async () => {
  const image = clipboard.readImage();
  return image.isEmpty()
    ? null
    : {
        type: "image",
        name: "Clipboard",
        png: image.toPNG().toString("base64"),
      };
});
handle("font", async () => {
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: "Fonts", extensions: ["ttf", "otf", "woff", "woff2"] }],
    properties: ["openFile"],
  });
  if (result.canceled) return null;
  const file = result.filePaths[0];
  return {
    name: path.basename(file, path.extname(file)),
    data: (await fs.readFile(file)).toString("base64"),
  };
});
handle("platform", () => process.platform);
handle("fonts", async () => {
  if (process.platform !== "darwin")
    return [
      "Arial",
      "Georgia",
      "Times New Roman",
      "Courier New",
      "Verdana",
      "sans-serif",
      "serif",
      "monospace",
    ];
  const { stdout } = await run(path.join(__dirname, "native", "cutout"), [
    "--fonts",
  ]);
  return JSON.parse(stdout);
});
handle("cutout", async (png) => {
  if (process.platform !== "darwin")
    throw new Error("Subject cutout is currently available on macOS only.");
  const helper = path.join(__dirname, "native", "cutout");
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "filtered-cutout-"));
  try {
    await fs.writeFile(
      path.join(dir, "source.png"),
      Buffer.from(png, "base64"),
    );
    await run(helper, [
      path.join(dir, "source.png"),
      path.join(dir, "output.png"),
    ]);
    return (await fs.readFile(path.join(dir, "output.png"))).toString("base64");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
app.on("open-file", (event, file) => {
  event.preventDefault();
  if (win?.webContents && !win.webContents.isLoading())
    readFile(file)
      .then((data) => send("open-file", data))
      .catch((error) => dialog.showErrorBox("Open failed", error.message));
  else pendingFile = file;
});
app.whenReady().then(() => {
  protocol.handle("filtered", (request) => {
    const url = new URL(request.url);
    if (url.host !== "app") return new Response("Forbidden", { status: 403 });
    const relative = decodeURIComponent(url.pathname),
      target = path.resolve(__dirname, "../dist", "." + relative),
      root = path.resolve(__dirname, "../dist") + path.sep;
    if (!target.startsWith(root))
      return new Response("Forbidden", { status: 403 });
    return net.fetch(pathToFileURL(target).toString());
  });
  win = new BrowserWindow({
    width: 1440,
    height: 960,
    minWidth: 1000,
    minHeight: 680,
    backgroundColor: "#151617",
    title: "Filtered",
    icon: path.join(__dirname, "../assets/icon.png"),
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (event) => event.preventDefault());
  win.webContents.session.setPermissionRequestHandler(
    (_wc, _permission, callback) => callback(false),
  );
  win.on("close", (event) => {
    if (dirty) {
      event.preventDefault();
      send("close");
    }
  });
  handle("close", () => {
    dirty = false;
    win.close();
  });
  const command = (label, action, accelerator) => ({
    label,
    accelerator,
    click: () => send(action),
  });
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      ...(process.platform === "darwin" ? [{ role: "appMenu" }] : []),
      {
        label: "File",
        submenu: [
          command("New Canvas", "new", "CmdOrCtrl+N"),
          command("Open…", "open", "CmdOrCtrl+O"),
          command("Save", "save", "CmdOrCtrl+S"),
          command("Save As…", "save-as", "CmdOrCtrl+Shift+S"),
          { type: "separator" },
          command("Export…", "export", "CmdOrCtrl+E"),
          {
            role: "recentDocuments",
            submenu: [{ role: "clearRecentDocuments" }],
          },
          { role: "close" },
        ],
      },
      {
        label: "Edit",
        submenu: [
          command("Undo", "undo", "CmdOrCtrl+Z"),
          command("Redo", "redo", "CmdOrCtrl+Shift+Z"),
          { role: "cut" },
          { role: "copy" },
          command("Copy Rendered Image", "copy", "CmdOrCtrl+Alt+C"),
          command("Paste Image", "paste", "CmdOrCtrl+Shift+V"),
          { role: "paste" },
          { role: "selectAll" },
          command("Duplicate Layer", "duplicate", "CmdOrCtrl+D"),
          command("Group Layers", "group", "CmdOrCtrl+G"),
          command("Ungroup", "ungroup", "CmdOrCtrl+Shift+G"),
        ],
      },
      {
        label: "View",
        submenu: [
          command("Compare Original", "compare", "CmdOrCtrl+\\"),
          command("Fit Canvas", "fit", "CmdOrCtrl+0"),
          { role: "togglefullscreen" },
          ...(!app.isPackaged ? [{ role: "toggleDevTools" }] : []),
        ],
      },
    ]),
  );
  win.loadURL("filtered://app/index.html");
  win.webContents.once("did-finish-load", () => {
    if (pendingFile)
      readFile(pendingFile).then((data) => send("open-file", data));
  });
});
app.on("window-all-closed", () => app.quit());
