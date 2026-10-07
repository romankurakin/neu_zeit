defmodule NeuZeit.Catalog.WorkloadImport do
  @moduledoc """
  Reads teaching load rows from a CSV file and matches names to catalog records.

  The first line names the columns: `course, teaching type, teacher, groups,
  hours, duration, format`. Names are matched case-insensitively after trimming.
  Column order is free and unknown columns are ignored. `format` is optional.
  Fields are separated by a comma or a semicolon, detected from the first line.
  Double quotes enclose fields; a doubled quote stands for a quote inside.

  `parse/1` and `resolve/2` are pure. `save/2` writes all rows in one
  transaction through `NeuZeit.Catalog.Workloads.save/3`.
  """
  import Ecto.Query

  alias NeuZeit.Catalog.{Cohort, Course, Teacher, Workloads}
  alias NeuZeit.Repo

  defmodule Row do
    @moduledoc "One data line of the file with its matched attributes or reasons."
    defstruct [
      :line,
      :course,
      :teaching_type,
      :teacher,
      :hours,
      :duration,
      :format,
      :attrs,
      groups: [],
      errors: []
    ]
  end

  @required_columns ["course", "teaching type", "teacher", "groups", "hours", "duration"]
  @columns @required_columns ++ ["format"]
  @formats %{"in person" => "in_person", "online" => "online"}

  def columns, do: @columns
  def header, do: Enum.join(@columns, ", ")

  @doc "Splits the file into rows. Errors concern the whole file."
  def parse(content) when is_binary(content) do
    content = strip_bom(content)

    cond do
      not String.valid?(content) ->
        {:error, :invalid_encoding}

      String.trim(content) == "" ->
        {:error, :empty}

      true ->
        [{_line, header} | records] = tokenize(content, separator(content))

        case column_index(header) do
          {:ok, index} ->
            records
            |> Enum.reject(fn {_line, fields} -> Enum.all?(fields, &(String.trim(&1) == "")) end)
            |> Enum.map(&row(&1, index))
            |> case do
              [] -> {:error, :empty}
              rows -> {:ok, rows}
            end

          {:error, missing} ->
            {:error, {:missing_columns, missing}}
        end
    end
  end

  @doc "Loads the records that rows are matched against."
  def context(term) do
    %{
      courses:
        Repo.all(
          from c in Course,
            order_by: [c.title, c.id],
            preload: [:translations, components: [teaching_type: :translations]]
        ),
      teachers: Repo.all(from t in Teacher, order_by: t.name),
      cohorts: Repo.all(from c in Cohort, order_by: c.name),
      duration_options: Workloads.duration_options(term)
    }
  end

  @doc "Fills each row's attributes for `Workloads.save/3`, or its reasons."
  def resolve(rows, context), do: Enum.map(rows, &resolve_row(&1, context))

  def valid?(rows), do: rows != [] and Enum.all?(rows, &(&1.errors == []))

  @doc "Saves every row or nothing. An error names the failing line."
  def save(term_id, rows) do
    Repo.transaction(fn ->
      Enum.each(rows, fn row ->
        case Workloads.save(term_id, nil, row.attrs) do
          {:ok, :saved} -> :ok
          {:error, reason} -> Repo.rollback({row.line, reason})
        end
      end)

      length(rows)
    end)
  end

  defp resolve_row(row, context) do
    {course, course_errors} = find(context.courses, row.course, :course, &course_names/1)

    {component, component_errors} =
      case course do
        nil -> {nil, []}
        course -> find(course.components, row.teaching_type, :teaching_type, &type_names/1)
      end

    {teacher, teacher_errors} = find(context.teachers, row.teacher, :teacher, &[&1.name])

    {cohorts, group_errors} =
      case row.groups do
        [] ->
          {[], [{:blank, :groups}]}

        names ->
          Enum.map_reduce(names, [], fn name, errors ->
            {cohort, found_errors} = find(context.cohorts, name, :group, &[&1.name])
            {cohort, errors ++ found_errors}
          end)
      end

    {hours, hours_errors} = positive_number(row.hours, :hours)
    {duration, duration_errors} = duration(row.duration, context.duration_options)
    {format, format_errors} = format(row.format)

    errors =
      course_errors ++
        component_errors ++
        teacher_errors ++ group_errors ++ hours_errors ++ duration_errors ++ format_errors

    attrs =
      if errors == [],
        do: %{
          "course_component_id" => component.id,
          "teacher_id" => teacher.id,
          "cohort_ids" => Enum.map(cohorts, & &1.id),
          "contact_hours" => Decimal.to_string(hours, :normal),
          "duration_slots" => duration.slots,
          "delivery_mode" => format
        }

    %{row | attrs: attrs, errors: errors}
  end

  defp find(_records, "", kind, _names), do: {nil, [{:blank, kind}]}

  defp find(records, name, kind, names) do
    needle = normalize(name)

    case Enum.filter(records, fn record ->
           Enum.any?(names.(record), &(normalize(&1) == needle))
         end) do
      [record] -> {record, []}
      [] -> {nil, [{:not_found, kind, name}]}
      _several -> {nil, [{:ambiguous, kind, name}]}
    end
  end

  defp course_names(course), do: [course.title | Enum.map(course.translations, & &1.title)]

  defp type_names(component),
    do: [component.kind | Enum.map(component.teaching_type.translations, & &1.name)]

  defp positive_number("", kind), do: {nil, [{:blank, kind}]}

  defp positive_number(value, kind) do
    case Decimal.parse(String.replace(value, ",", ".")) do
      {number, ""} ->
        if Decimal.compare(number, 0) == :gt,
          do: {number, []},
          else: {nil, [{:invalid_number, kind, value}]}

      _ ->
        {nil, [{:invalid_number, kind, value}]}
    end
  end

  defp duration(value, options) do
    case positive_number(value, :duration) do
      {nil, errors} ->
        {nil, errors}

      {hours, []} ->
        case Enum.find(options, &Decimal.equal?(&1.hours, hours)) do
          nil -> {nil, [{:invalid_duration, value}]}
          option -> {option, []}
        end
    end
  end

  defp format(""), do: {"in_person", []}

  defp format(value) do
    case Map.fetch(@formats, normalize(value)) do
      {:ok, mode} -> {mode, []}
      :error -> {nil, [{:invalid_format, value}]}
    end
  end

  defp normalize(text), do: text |> String.trim() |> String.downcase()

  defp row({line, fields}, index) do
    field = fn column ->
      case index[column] do
        nil -> ""
        position -> fields |> Enum.at(position, "") |> String.trim()
      end
    end

    %Row{
      line: line,
      course: field.("course"),
      teaching_type: field.("teaching type"),
      teacher: field.("teacher"),
      groups:
        field.("groups")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "")),
      hours: field.("hours"),
      duration: field.("duration"),
      format: field.("format")
    }
  end

  defp column_index(header) do
    index =
      header
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {name, position}, acc ->
        Map.put_new(acc, name |> normalize() |> String.replace(~r/\s+/, " "), position)
      end)

    case Enum.reject(@required_columns, &Map.has_key?(index, &1)) do
      [] -> {:ok, index}
      missing -> {:error, missing}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  # The first line decides: a semicolon wins when it appears more often than a comma.
  defp separator(content) do
    first = content |> String.split(~r/\r\n|\r|\n/, parts: 2) |> hd()
    if count(first, ";") > count(first, ","), do: ?;, else: ?,
  end

  defp count(text, char), do: text |> String.graphemes() |> Enum.count(&(&1 == char))

  # Records with their starting line number. Quotes may enclose separators and line breaks.
  defp tokenize(content, sep), do: unquoted(content, sep, 1, 1, "", [], [])

  defp unquoted("", _sep, start, _line, field, fields, records),
    do: finish(start, field, fields, records)

  defp unquoted(<<?", rest::binary>>, sep, start, line, "", fields, records),
    do: quoted(rest, sep, start, line, "", fields, records)

  defp unquoted(<<sep, rest::binary>>, sep, start, line, field, fields, records),
    do: unquoted(rest, sep, start, line, "", [field | fields], records)

  defp unquoted(<<"\r\n", rest::binary>>, sep, start, line, field, fields, records),
    do: unquoted(rest, sep, line + 1, line + 1, "", [], [record(start, field, fields) | records])

  defp unquoted(<<break, rest::binary>>, sep, start, line, field, fields, records)
       when break in [?\n, ?\r],
       do:
         unquoted(rest, sep, line + 1, line + 1, "", [], [record(start, field, fields) | records])

  defp unquoted(<<char::utf8, rest::binary>>, sep, start, line, field, fields, records),
    do: unquoted(rest, sep, start, line, field <> <<char::utf8>>, fields, records)

  defp quoted("", _sep, start, _line, field, fields, records),
    do: finish(start, field, fields, records)

  defp quoted(<<?", ?", rest::binary>>, sep, start, line, field, fields, records),
    do: quoted(rest, sep, start, line, field <> "\"", fields, records)

  defp quoted(<<?", rest::binary>>, sep, start, line, field, fields, records),
    do: unquoted(rest, sep, start, line, field, fields, records)

  defp quoted(<<"\r\n", rest::binary>>, sep, start, line, field, fields, records),
    do: quoted(rest, sep, start, line + 1, field <> "\n", fields, records)

  defp quoted(<<break, rest::binary>>, sep, start, line, field, fields, records)
       when break in [?\n, ?\r],
       do: quoted(rest, sep, start, line + 1, field <> "\n", fields, records)

  defp quoted(<<char::utf8, rest::binary>>, sep, start, line, field, fields, records),
    do: quoted(rest, sep, start, line, field <> <<char::utf8>>, fields, records)

  defp record(start, field, fields), do: {start, Enum.reverse([field | fields])}

  defp finish(_start, "", [], records), do: Enum.reverse(records)

  defp finish(start, field, fields, records),
    do: Enum.reverse([record(start, field, fields) | records])
end
