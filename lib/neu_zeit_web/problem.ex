defmodule NeuZeitWeb.Problem do
  @moduledoc """
  RFC 9457 Problem Details helpers for API error responses.
  """

  import Plug.Conn

  @content_type "application/problem+json"

  @types %{
    validation: "/problems/validation-error",
    timetable_constraints: "/problems/timetable-constraint-violation",
    bad_request: "/problems/bad-request",
    not_found: "/problems/not-found",
    conflict: "/problems/resource-conflict",
    unprocessable: "/problems/unprocessable-content"
  }

  def content_type, do: @content_type

  def type(name), do: Map.fetch!(@types, name)

  def send(conn, status, type, title, detail, extensions \\ %{}) do
    problem =
      status
      |> build(type, title, detail, Map.put_new(extensions, :instance, instance(conn)))
      |> Phoenix.json_library().encode_to_iodata!()

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status_code(status), problem)
  end

  def build(status, type, title, detail, extensions \\ %{}) do
    base = %{
      type: type,
      title: title,
      status: status_code(status),
      detail: detail
    }

    extensions
    |> Enum.reduce(base, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  def from_template(template) do
    status =
      template
      |> String.split(".")
      |> List.first()
      |> String.to_integer()

    build(status, "about:blank", status_title(status), status_title(status))
  end

  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> flatten_errors()
  end

  def timetable_errors(errors) when is_list(errors) do
    Enum.map(errors, fn error ->
      %{
        code: to_string(error_value(error, :type, "constraint_violation")),
        detail: error_value(error, :message, "Timetable constraint violated"),
        placement_ids: error |> error_value(:placement_ids, []) |> present_list()
      }
      |> put_present(:session_ids, error |> error_value(:session_ids, []) |> present_list())
      |> put_present(:exception_ids, error |> error_value(:exception_ids, []) |> present_list())
      |> put_present(
        :occurrence_dates,
        error |> error_value(:occurrence_dates, []) |> present_list()
      )
      |> put_present(:solver_status, error_value(error, :solver_status, nil))
    end)
  end

  def status_title(status), do: Plug.Conn.Status.reason_phrase(status_code(status))
  def status_code(status) when is_integer(status), do: status
  def status_code(status) when is_atom(status), do: Plug.Conn.Status.code(status)

  defp flatten_errors(errors) do
    errors
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{
          code: "invalid",
          detail: message,
          pointer: pointer(field)
        }
      end)
    end)
  end

  defp pointer(field) do
    field
    |> to_string()
    |> escape_json_pointer()
    |> then(&"#/#{&1}")
  end

  defp escape_json_pointer(value) do
    value
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp error_value(error, key, default) do
    Map.get(error, key, Map.get(error, Atom.to_string(key), default))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp present_list(values) when is_list(values), do: Enum.reject(values, &is_nil/1)
  defp present_list(_value), do: []

  defp instance(conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end
end
