defmodule NeuZeitWeb.Storybook do
  use PhoenixStorybook,
    otp_app: :neu_zeit,
    content_path: Path.expand("../storybook", __DIR__),
    # Compile stories during gettext extraction so example-only messages retain translations.
    compilation_mode: :eager,
    title: "NeuZeit Components",
    css_path: "/assets/css/app.css",
    js_path: "/assets/js/storybook.ts",
    js_script_type: "module",
    sandbox_class: "neu-zeit app-typography font-sans bg-base-100 text-base-content",
    color_mode: true

  # Volt resolves development modules and the hashed files from a build.
  defoverridable config: 2, asset_hash: 1

  def config(:css_path, _default),
    do: Volt.static_path(NeuZeitWeb.Endpoint, "/assets/css/app.css")

  def config(:js_path, _default),
    do:
      Volt.static_path(NeuZeitWeb.Endpoint, "/assets/js/storybook.js",
        entry: "assets/js/storybook.ts"
      )

  def config(key, default), do: super(key, default)
  def asset_hash(_asset), do: nil
end
