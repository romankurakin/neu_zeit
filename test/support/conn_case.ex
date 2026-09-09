defmodule NeuZeitWeb.ConnCase do
  @moduledoc """
  Sets up connection tests with Phoenix helpers and a SQL sandbox.

  Database changes are rolled back after each test. PostgreSQL tests can run
  concurrently with `async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint NeuZeitWeb.Endpoint

      use NeuZeitWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import NeuZeitWeb.ConnCase
    end
  end

  setup tags do
    NeuZeit.DataCase.setup_sandbox(tags)
    {:ok, conn: build_conn_with_locale(tags[:locale] || "en")}
  end

  @doc """
  Creates a connection with an English session locale by default.

  Use a locale tag, such as `@tag locale: "ru"`, for translation tests.
  """
  def build_conn_with_locale(locale) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"locale" => locale})
  end
end
