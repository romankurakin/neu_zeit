defmodule NeuZeitWeb.JavaScriptFormatter do
  @moduledoc """
  Adapts Volt's JavaScript formatter to `<script>` tags in HEEx templates.
  """

  @behaviour Phoenix.LiveView.HTMLFormatter.TagFormatter

  @impl Phoenix.LiveView.HTMLFormatter.TagFormatter
  def render_tag({"script", _attrs, content}, _opts) do
    {:ok, Volt.Formatter.format(content, file: "hook.js")}
  rescue
    # A script the formatter refuses stays as written. One snippet must not
    # fail the whole run.
    _error -> :skip
  end

  def render_tag(_tag, _opts), do: :skip
end
