defmodule NeuZeitWeb.Storybook do
  use PhoenixStorybook,
    otp_app: :neu_zeit,
    content_path: Path.expand("../storybook", __DIR__),
    # Compile stories during gettext extraction so example-only messages retain translations.
    compilation_mode: :eager,
    title: "NeuZeit Components",
    css_path: "/assets/css/app.css",
    js_path: "/assets/js/storybook.js",
    js_script_type: "module",
    sandbox_class: "neu-zeit app-typography font-sans bg-base-100 text-base-content",
    color_mode: true

  # Volt serves source modules in development; there is no static file to hash.
  defoverridable asset_hash: 1
  def asset_hash(:js_path), do: nil
  def asset_hash(asset), do: super(asset)
end
