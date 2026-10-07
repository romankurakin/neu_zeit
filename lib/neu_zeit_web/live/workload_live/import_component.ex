defmodule NeuZeitWeb.WorkloadLive.ImportComponent do
  @moduledoc """
  The CSV import dialog of the teaching load page.

  The file is uploaded as soon as it is chosen, then parsed and matched. The
  preview lists every line with its reasons. Import writes all rows or none.
  On success the component sends `{__MODULE__, :imported, count}` to the parent,
  which shows the result and closes the dialog. The parent also handles the
  dialog's `import_close` event, because the dialog hook talks to the LiveView.
  """
  use NeuZeitWeb, :live_component

  alias NeuZeit.Catalog.WorkloadImport
  alias NeuZeitWeb.UI.Errors

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:uploads] do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(rows: nil, file_error: nil)
       |> allow_upload(:csv,
         accept: ~w(.csv .txt),
         max_entries: 1,
         max_file_size: 1_000_000,
         auto_upload: true,
         progress: &handle_progress/3
       )}
    end
  end

  defp handle_progress(:csv, entry, socket) do
    if entry.done? do
      [content] =
        consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)

      case WorkloadImport.parse(content) do
        {:ok, rows} ->
          rows = WorkloadImport.resolve(rows, WorkloadImport.context(socket.assigns.term))
          {:noreply, assign(socket, rows: rows, file_error: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, rows: nil, file_error: file_message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("import", _params, socket) do
    rows = socket.assigns.rows

    if WorkloadImport.valid?(rows) do
      case WorkloadImport.save(socket.assigns.term.id, rows) do
        {:ok, count} ->
          send(self(), {__MODULE__, :imported, count})
          {:noreply, socket}

        {:error, {line, reason}} ->
          {:noreply, assign(socket, :file_error, line_message(line, Errors.message(reason)))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.dialog
        id="workload-import"
        title={gettext("Import teaching load from CSV")}
        on_cancel="import_close"
        class="w-11/12 max-w-5xl"
      >
        <form
          id="workload-import-form"
          phx-change="validate"
          phx-submit="import"
          phx-target={@myself}
          class="flex flex-col gap-4"
        >
          <div class="flex flex-col gap-2">
            <p>{gettext("The first line names the columns. One line per teaching load row.")}</p>
            <pre class="overflow-x-auto rounded-box bg-base-200 p-3"><code>{WorkloadImport.header() <> "\n" <> gettext("Algorithms, Lecture, Ivanova, CS-1|CS-2, 32, 2, in person")}</code></pre>
            <ul class="list-disc pl-5">
              <li>{gettext("groups: group names separated by |.")}</li>
              <li>{gettext("hours: academic hours per semester.")}</li>
              <li>
                {gettext("duration: session duration in academic hours, one of %{options}.",
                  options: Enum.map_join(@duration_options, ", ", &decimal(&1.hours))
                )}
              </li>
              <li>{gettext("format: in person (default) or online.")}</li>
              <li>
                {gettext("Fields are separated by a comma or a semicolon. Quotes are allowed.")}
              </li>
            </ul>
          </div>
          <div class="fieldset type-detail">
            <label for={@uploads.csv.ref}>
              <span class="label mb-1">{gettext("CSV file")}</span>
              <.live_file_input upload={@uploads.csv} class="file-input w-full" />
            </label>
            <.error :for={
              error <- Enum.flat_map(@uploads.csv.entries, &upload_errors(@uploads.csv, &1))
            }>
              {upload_message(error)}
            </.error>
          </div>
          <p :if={@file_error} id="workload-import-error" class="text-error" role="alert">
            {@file_error}
          </p>
          <.table
            :if={@rows}
            id="workload-import-preview"
            rows={@rows}
            row_id={&"workload-import-line-#{&1.line}"}
          >
            <:col :let={row} label={gettext("Line")} numeric>{row.line}</:col>
            <:col :let={row} label={gettext("Course")}>{row.course}</:col>
            <:col :let={row} label={gettext("Teaching type")}>{row.teaching_type}</:col>
            <:col :let={row} label={gettext("Teacher")}>{row.teacher}</:col>
            <:col :let={row} label={gettext("Groups")}>{Enum.join(row.groups, ", ")}</:col>
            <:col :let={row} label={gettext("Hours")} numeric>{row.hours}</:col>
            <:col :let={row} label={gettext("Duration")} numeric>{row.duration}</:col>
            <:col :let={row} label={gettext("Format")}>{row.format}</:col>
            <:col :let={row} label={gettext("Status")}>
              <span :if={row.errors == []}>{gettext("Ready")}</span>
              <p :for={error <- row.errors} class="text-error">
                {line_message(row.line, row_message(error))}
              </p>
            </:col>
          </.table>
          <div class="modal-action">
            <.button type="button" phx-click="import_close">{gettext("Cancel")}</.button>
            <.button
              :if={@rows}
              type="submit"
              variant="primary"
              disabled={!WorkloadImport.valid?(@rows)}
              phx-disable-with={gettext("Importing")}
            >
              {ngettext("Import %{count} row", "Import %{count} rows", length(@rows))}
            </.button>
          </div>
        </form>
      </.dialog>
    </div>
    """
  end

  defp decimal(value),
    do: value |> Decimal.round(2) |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp line_message(line, message),
    do: gettext("Line %{line}: %{message}", line: line, message: message)

  defp upload_message(:too_large), do: gettext("The file is larger than 1 MB.")
  defp upload_message(:not_accepted), do: gettext("Choose a CSV file.")
  defp upload_message(:too_many_files), do: gettext("Choose one file.")
  defp upload_message(_error), do: gettext("The file could not be uploaded. Try again.")

  defp file_message(:invalid_encoding), do: gettext("The file is not UTF-8 text.")
  defp file_message(:empty), do: gettext("The file has no rows.")

  defp file_message({:missing_columns, columns}),
    do:
      gettext("The first line is missing columns: %{columns}.", columns: Enum.join(columns, ", "))

  defp row_message({:blank, :course}), do: gettext("the course is empty.")
  defp row_message({:blank, :teaching_type}), do: gettext("the teaching type is empty.")
  defp row_message({:blank, :teacher}), do: gettext("the teacher is empty.")
  defp row_message({:blank, :groups}), do: gettext("the groups are empty.")
  defp row_message({:blank, :hours}), do: gettext("the hours are empty.")
  defp row_message({:blank, :duration}), do: gettext("the duration is empty.")

  defp row_message({:not_found, :course, name}),
    do: gettext("course \"%{name}\" not found.", name: name)

  defp row_message({:not_found, :teaching_type, name}),
    do: gettext("teaching type \"%{name}\" is not assigned to this course.", name: name)

  defp row_message({:not_found, :teacher, name}),
    do: gettext("teacher \"%{name}\" not found.", name: name)

  defp row_message({:not_found, :group, name}),
    do: gettext("group \"%{name}\" not found.", name: name)

  defp row_message({:ambiguous, :course, name}),
    do: gettext("course \"%{name}\" matches more than one course.", name: name)

  defp row_message({:ambiguous, :teaching_type, name}),
    do: gettext("teaching type \"%{name}\" matches more than one teaching type.", name: name)

  defp row_message({:ambiguous, :teacher, name}),
    do: gettext("teacher \"%{name}\" matches more than one teacher.", name: name)

  defp row_message({:ambiguous, :group, name}),
    do: gettext("group \"%{name}\" matches more than one group.", name: name)

  defp row_message({:invalid_number, :hours, value}),
    do: gettext("hours \"%{value}\" is not a number greater than 0.", value: value)

  defp row_message({:invalid_number, :duration, value}),
    do: gettext("duration \"%{value}\" is not a number greater than 0.", value: value)

  defp row_message({:invalid_duration, value}),
    do: gettext("duration %{value} is not a session duration of this term.", value: value)

  defp row_message({:invalid_format, value}),
    do: gettext("format \"%{value}\" is not \"in person\" or \"online\".", value: value)
end
