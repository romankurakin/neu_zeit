defmodule NeuZeitWeb.JavaScriptFormatter do
  @moduledoc """
  Formats JavaScript when `mix format` runs, in files and inside `<script>` tags.

  Without this the assets need a separate formatter, and the colocated hooks
  drift from their style, because the template formatter treats a script as text.

  Formatting runs on the BEAM through Volt, so it needs no Node. Volt offers the
  same as `Volt.Formatter`, but that reads `config :volt, :format`, which this
  project already uses to ask the bundler for ESM.
  """

  @behaviour Mix.Tasks.Format
  @behaviour Phoenix.LiveView.HTMLFormatter.TagFormatter

  @impl Mix.Tasks.Format
  def features(_opts), do: [extensions: [".js", ".mjs"]]

  @impl Mix.Tasks.Format
  def format(contents, opts), do: run(contents, opts[:file] || "input.js")

  @impl Phoenix.LiveView.HTMLFormatter.TagFormatter
  def render_tag({"script", _attrs, content}, _opts) do
    {:ok, run(content, "hook.js")}
  rescue
    # A script the formatter refuses stays as written. One snippet must not
    # fail the whole run.
    _error -> :skip
  end

  def render_tag(_tag, _opts), do: :skip

  defp run(source, filename),
    do: OXC.Format.run!(source, filename, Volt.JS.Format.load_json_config())
end
