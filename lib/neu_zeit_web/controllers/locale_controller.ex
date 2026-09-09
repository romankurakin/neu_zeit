defmodule NeuZeitWeb.LocaleController do
  use NeuZeitWeb, :controller

  @doc """
  Stores the selected language and redirects to a local return path.

  The redirected request mounts the page with the new session language.
  """
  def update(conn, %{"locale" => locale} = params) do
    conn
    |> NeuZeitWeb.Locale.put(locale)
    |> redirect(to: safe_return_to(params["return_to"]))
  end

  # Only ever return to a path on this site.
  defp safe_return_to("/" <> _ = path), do: path
  defp safe_return_to(_other), do: ~p"/"
end
