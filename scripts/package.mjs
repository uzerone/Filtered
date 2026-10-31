import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
const env = { ...process.env };
if (process.platform === "darwin") {
  if (
    !env.DEVELOPER_DIR &&
    existsSync("/Applications/Xcode.app/Contents/Developer")
  )
    env.DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer";
  const actool = execFileSync("xcrun", ["--find", "actool"], {
    env,
    encoding: "utf8",
  }).trim();
  env.PATH = `${path.dirname(actool)}${path.delimiter}${env.PATH}`;
}
execFileSync(
  process.execPath,
  ["node_modules/electron-builder/cli.js", ...process.argv.slice(2)],
  { env, stdio: "inherit" },
);
