// Convert the npm SVGs into the hero-* classes used by Phoenix components.
import fileSystem from "fs"
import path from "path"
import plugin from "tailwindcss/plugin"

const iconsDirectory = path.resolve("node_modules/heroicons")

const readIconValues = () => {
  /** @type {Map<string, string>} */
  const values = new Map()
  for (const [suffix, folder] of [
    ["", "24/outline"],
    ["-solid", "24/solid"],
    ["-mini", "20/solid"],
    ["-micro", "16/solid"],
  ]) {
    for (const file of fileSystem.readdirSync(path.join(iconsDirectory, folder))) {
      values.set(path.basename(file, ".svg") + suffix, path.join(iconsDirectory, folder, file))
    }
  }
  return Object.fromEntries(values)
}

/** @param {string} fullPath @param {(key: string) => unknown} theme */
const renderIcon = (fullPath, theme) => {
  const content = encodeURIComponent(
    fileSystem.readFileSync(fullPath, "utf8").replaceAll(/\r?\n|\r/gu, ""),
  )
  const mask = `url('data:image/svg+xml;utf8,${content}')`
  let size = theme("spacing.6")
  if (fullPath.includes("/20/solid/")) {
    size = theme("spacing.5")
  } else if (fullPath.includes("/16/solid/")) {
    size = theme("spacing.4")
  }
  if (typeof size !== "string") {
    throw new TypeError("Missing icon spacing in the Tailwind theme")
  }
  return {
    "--hero-icon": mask,
    "-webkit-mask": "var(--hero-icon)",
    "background-color": "currentColor",
    display: "inline-block",
    height: size,
    mask: "var(--hero-icon)",
    "mask-repeat": "no-repeat",
    "vertical-align": "middle",
    width: size,
  }
}

export default plugin((api) => {
  api.matchComponents(
    { hero: (fullPath) => renderIcon(fullPath, (key) => api.theme(key)) },
    { values: readIconValues() },
  )
})
