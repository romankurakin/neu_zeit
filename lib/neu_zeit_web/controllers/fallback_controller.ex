defmodule NeuZeitWeb.FallbackController do
  use NeuZeitWeb, :controller

  alias NeuZeitWeb.Problem

  def call(conn, {:error, :not_found}) do
    not_found(conn, "Not Found")
  end

  def call(conn, {:error, {:not_found, detail}}) do
    not_found(conn, detail)
  end

  def call(conn, {:error, {:conflict, detail}}) do
    Problem.send(
      conn,
      :conflict,
      Problem.type(:conflict),
      "Resource Conflict",
      detail
    )
  end

  def call(conn, {:error, {:bad_request, detail}}) do
    Problem.send(
      conn,
      :bad_request,
      Problem.type(:bad_request),
      "Bad Request",
      detail
    )
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    if conflict_changeset?(changeset) do
      Problem.send(
        conn,
        :conflict,
        Problem.type(:conflict),
        "Resource Conflict",
        "Request conflicts with existing resource state.",
        %{errors: Problem.changeset_errors(changeset)}
      )
    else
      validation_error(conn, changeset)
    end
  end

  def call(conn, {:error, %{errors: errors}}) when is_list(errors) do
    Problem.send(
      conn,
      :unprocessable_entity,
      Problem.type(:timetable_constraints),
      "Timetable Constraint Violation",
      "Request violates timetable constraints.",
      %{errors: Problem.timetable_errors(errors)}
    )
  end

  def call(conn, {:error, reason}) do
    Problem.send(
      conn,
      :unprocessable_entity,
      Problem.type(:unprocessable),
      "Unprocessable Content",
      generic_detail(reason)
    )
  end

  defp not_found(conn, detail) do
    Problem.send(conn, :not_found, Problem.type(:not_found), "Not Found", detail)
  end

  defp validation_error(conn, changeset) do
    Problem.send(
      conn,
      :unprocessable_entity,
      Problem.type(:validation),
      "Validation Error",
      "Request validation failed.",
      %{errors: Problem.changeset_errors(changeset)}
    )
  end

  defp conflict_changeset?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique
    end)
  end

  defp generic_detail(reason) when is_binary(reason), do: reason
  defp generic_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp generic_detail(_reason), do: "Request could not be processed."
end
