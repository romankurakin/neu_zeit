defmodule NeuZeitWeb.ApiJSON do
  @moduledoc false

  def data(records) when is_list(records), do: Enum.map(records, &data/1)

  def data(%_schema{} = record) do
    if function_exported?(record.__struct__, :__schema__, 1) do
      fields =
        record.__struct__.__schema__(:fields)
        |> Map.new(fn field -> {field, encode_value(Map.get(record, field))} end)

      associations =
        record.__struct__.__schema__(:associations)
        |> Enum.filter(&Ecto.assoc_loaded?(Map.get(record, &1)))
        |> Map.new(fn association ->
          {association, encode_value(Map.get(record, association))}
        end)

      Map.merge(fields, associations)
    else
      record
      |> Map.from_struct()
      |> data()
    end
  end

  def data(%{} = map) do
    Map.new(map, fn {key, value} -> {key, encode_value(value)} end)
  end

  def data(value), do: encode_value(value)

  def errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp encode_value(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp encode_value(%Date{} = date), do: Date.to_iso8601(date)
  defp encode_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(%{} = value), do: data(value)
  defp encode_value(value), do: value
end
