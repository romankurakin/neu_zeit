defmodule NeuZeitWeb.UI.Errors do
  @moduledoc """
  Converts context errors into form errors, flash messages or diagnostics.

      %Ecto.Changeset{} -> form errors
      {:conflict, message} -> flash message
      :not_found -> flash message
      %{errors: entries} -> diagnostics
      %{"status" => status} -> calculation status

  Accepts a reason directly or wrapped in `{:error, reason}`.
  """

  use Gettext, backend: NeuZeitWeb.Gettext

  require Logger

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  @type reason :: term()
  @type classification ::
          {:form, Ecto.Changeset.t()}
          | {:flash, String.t()}
          | {:diagnostics, [map()]}
          | {:solver, String.t(), String.t()}

  @doc """
  Classifies a context error for display. Accepts a reason or `{:error, reason}`.
  """
  @spec classify(reason()) :: classification()
  def classify({:error, reason}), do: classify(reason)

  def classify(%Ecto.Changeset{} = changeset), do: {:form, changeset}

  def classify({:conflict, message}) when is_binary(message),
    do: {:flash, translate_validation({message, []})}

  def classify(:not_found), do: {:flash, gettext("This record no longer exists.")}

  def classify(%{errors: [_ | _] = errors}), do: {:diagnostics, errors}

  def classify(%{"status" => status} = result) when is_binary(status) do
    {:solver, status, solver_message(status, result["error"])}
  end

  def classify(other) do
    Logger.warning("Admin action failed: #{inspect(other)}")
    {:flash, gettext("The action could not be completed. Try again.")}
  end

  @doc """
  Formats an error as a message.

  Changeset errors use translated field labels so they can also be shown in a flash.
  """
  @spec message(reason()) :: String.t()
  def message(reason) do
    case classify(reason) do
      {:form, changeset} -> changeset_message(changeset)
      {:flash, message} -> message
      {:diagnostics, errors} -> diagnostics_message(errors)
      {:solver, _status, message} -> message
    end
  end

  @doc """
  Adds an error to a socket.

  Use `:as` to assign a changeset to a form. Other errors, or changesets without
  `:as`, are shown as flash messages.
  """
  @spec put(Phoenix.LiveView.Socket.t(), reason(), keyword()) :: Phoenix.LiveView.Socket.t()
  def put(socket, reason, opts \\ []) do
    case {classify(reason), Keyword.get(opts, :as)} do
      {{:form, changeset}, nil} ->
        put_flash(socket, :error, changeset_message(changeset))

      {{:form, changeset}, as} ->
        Phoenix.Component.assign(socket, as, to_form(changeset, action: :validate))

      {{:diagnostics, errors}, _as} ->
        put_flash(socket, :error, diagnostics_message(errors))

      {{_kind, message}, _as} when is_binary(message) ->
        put_flash(socket, :error, message)

      {{:solver, _status, message}, _as} ->
        put_flash(socket, :error, message)
    end
  end

  defp solver_message("INFEASIBLE", _detail),
    do:
      gettext(
        "No timetable fits the current rules. Review locked placements, time profiles and allowed rooms."
      )

  defp solver_message("TIMEOUT", _detail),
    do: gettext("Time limit reached. A complete timetable was not found.")

  defp solver_message("BUSY", _detail),
    do: gettext("Another solve is already running. Try again once it finishes.")

  defp solver_message(status, detail) do
    Logger.warning("Timetable generation failed: #{inspect(status)}, #{inspect(detail)}")
    gettext("Calculation could not finish. Try again.")
  end

  @doc "Localize structured diagnostics without changing the API's language-independent fields."
  def entry_message(%{type: "solver_" <> _, solver_status: status}) do
    case String.upcase(to_string(status)) do
      known when known in ["INFEASIBLE", "TIMEOUT", "BUSY"] -> solver_message(known, nil)
      _ -> gettext("Calculation could not finish. Try again.")
    end
  end

  def entry_message(%{other_term_name: other, term_name: term} = entry) do
    gettext(
      "%{term} / %{other_term}: %{resource} is already booked on %{date}, %{time}. %{course}, %{teacher}, %{room}.",
      term: term,
      other_term: other,
      resource: entry.resource_name,
      date: to_string(entry.date),
      time: entry.conflict_time,
      course: entry.other_course,
      teacher: entry.other_teacher,
      room: entry.other_room
    )
  end

  def entry_message(%{type: type, message: message} = entry) when is_binary(message) do
    summary = diagnostic_message(type) || message
    dates = Enum.join(Map.get(entry, :occurrence_dates, []), ", ")

    [summary, Map.get(entry, :related, ""), dates]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  def entry_message(entry), do: Map.get(entry, :message, "")

  defp diagnostic_message("grid_bounds"),
    do: gettext("Choose a teaching day and a time that fits the full session.")

  defp diagnostic_message("week_mask_mismatch"),
    do: gettext("Placement weeks must match the session's teaching weeks.")

  defp diagnostic_message("duration_mismatch"),
    do: gettext("Placement duration must match the session duration.")

  defp diagnostic_message("delivery_room_mismatch"),
    do: gettext("Online sessions do not use a room.")

  defp diagnostic_message("room_not_allowed"),
    do: gettext("Choose a room allowed for this teaching type.")

  defp diagnostic_message("time_not_allowed"),
    do: gettext("Choose a start time allowed by the session's time profile.")

  defp diagnostic_message("teacher_unavailable"),
    do: gettext("The teacher is not available for the full session at this time.")

  defp diagnostic_message("duplicate_session"),
    do: gettext("This session is scheduled more than once. Remove the duplicate placement.")

  defp diagnostic_message("room_conflict"),
    do: gettext("Another session uses this room at the same time.")

  defp diagnostic_message("teacher_conflict"),
    do: gettext("The teacher has another session at the same time.")

  defp diagnostic_message("cohort_conflict"),
    do: gettext("The group has another session at the same time.")

  defp diagnostic_message("unverified_cohort_overlap"),
    do:
      gettext(
        "A group and subgroup have sessions at the same time. Check whether they share students."
      )

  defp diagnostic_message("exception_outside_term"),
    do: gettext("Choose a date within the term.")

  defp diagnostic_message("exception_outside_grid"),
    do: gettext("Choose a teaching day and a time that fits the full session.")

  defp diagnostic_message("exception_on_excluded_date"),
    do: gettext("This date is marked as non-teaching. Choose another date.")

  defp diagnostic_message("orphaned_exception"),
    do: gettext("This change no longer matches a scheduled session. Review it before publishing.")

  defp diagnostic_message("unplaced_sessions"),
    do: gettext("Calculation returned an incomplete timetable. The result was not saved.")

  defp diagnostic_message("invalid_solver_output"),
    do: gettext("Calculation returned invalid data. The result was not saved.")

  defp diagnostic_message("solver_assignment_mismatch"),
    do:
      gettext(
        "Calculation returned a timetable for a different set of sessions. The result was not saved."
      )

  defp diagnostic_message("unknown_room"),
    do: gettext("Calculation used a room that no longer exists. The result was not saved.")

  defp diagnostic_message("locked_placement_moved"),
    do: gettext("Calculation moved a locked session. The result was not saved.")

  defp diagnostic_message("plan_not_found"), do: gettext("This record no longer exists.")

  defp diagnostic_message(_type), do: nil

  # For one diagnostic, show its reason. For several, show the count and a short
  # summary; the checks view contains the full list.
  defp diagnostics_message([%{message: message} = entry]) when is_binary(message),
    do: entry_message(entry)

  defp diagnostics_message(errors) do
    count = length(errors)

    summary =
      ngettext(
        "%{count} rule violation must be resolved first.",
        "%{count} rule violations must be resolved first.",
        count
      )

    details =
      errors
      |> Enum.map(&entry_message/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(3)

    Enum.join([summary | details], " ")
  end

  @doc "Translate form and flash errors through the same catalogue without changing API errors."
  def translate_validation({message, opts}) do
    {message, opts} = normalize_validation(message, opts)

    if count = opts[:count] do
      Gettext.dngettext(NeuZeitWeb.Gettext, "errors", message, message, count, opts)
    else
      Gettext.dgettext(NeuZeitWeb.Gettext, "errors", message, opts)
    end
  end

  # A few legacy validators interpolate values before returning their errors.
  # Recover translation bindings at the presentation boundary; API payloads keep
  # their existing text. Unknown messages retain the original explanation.
  defp normalize_validation(message, opts) do
    cond do
      match =
          Regex.run(
            ~r/^term must keep at least (\d+) weeks; existing sessions or placements use week (\d+)$/,
            message
          ) ->
        [_, minimum, week] = match

        {"term must keep at least %{minimum} weeks; existing sessions or placements use week %{week}",
         Keyword.merge(opts, minimum: minimum, week: week)}

      match = Regex.run(~r/^is outside the configured slot grid \(1\.\.(\d+)\)$/, message) ->
        [_, slots] = match
        {"is outside the configured slot grid (1..%{slots})", Keyword.put(opts, :slots, slots)}

      Regex.match?(~r/^leaves no valid start for session [0-9a-f-]{36}$/, message) ->
        {"leaves no valid start for an existing session", opts}

      true ->
        {message, opts}
    end
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_validation/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(List.wrap(messages), fn
        message when is_binary(message) -> with_field(field, message)
        _nested -> with_field(field, translate_validation({"is invalid", []}))
      end)
    end)
    |> case do
      [] -> gettext("The change could not be saved.")
      messages -> Enum.join(messages, "; ")
    end
  end

  defp with_field(:base, message), do: message
  defp with_field(field, message), do: "#{field_label(field)}: #{message}"

  defp field_label(:grid), do: gettext("Days and times")
  defp field_label(:default_locale), do: gettext("Default language")
  defp field_label(:supported_locales), do: gettext("Available languages")
  defp field_label(:academic_hour_minutes), do: gettext("Minutes per academic hour")
  defp field_label(:names), do: gettext("Name")
  defp field_label(:translations), do: gettext("Translations")
  defp field_label(:name), do: gettext("Name")
  defp field_label(:title), do: gettext("Title")
  defp field_label(:code), do: gettext("Code")
  defp field_label(:term_id), do: gettext("Term")
  defp field_label(:plan_id), do: gettext("Plan")
  defp field_label(:session_id), do: gettext("Session")
  defp field_label(:course_id), do: gettext("Course")
  defp field_label(:course_component_id), do: gettext("Teaching type")
  defp field_label(:teacher_id), do: gettext("Teacher")
  defp field_label(field) when field in [:cohort_id, :cohort_ids], do: gettext("Groups")
  defp field_label(:building_id), do: gettext("Building")
  defp field_label(:new_teacher_id), do: gettext("Substitute teacher")
  defp field_label(field) when field in [:room_id, :new_room_id], do: gettext("Room")

  defp field_label(field) when field in [:delivery_mode, :new_delivery_mode],
    do: gettext("Delivery format")

  defp field_label(:allowed_room_ids), do: gettext("Allowed rooms")
  defp field_label(:slot_profile_id), do: gettext("Time profile")
  defp field_label(:week_mask), do: gettext("Teaching weeks")
  defp field_label(:duration_slots), do: gettext("Duration")
  defp field_label(:contact_hours), do: gettext("Required hours")
  defp field_label(:rounding_mode), do: gettext("Number of sessions")
  defp field_label(:remainder_parity), do: gettext("Alternating weeks")
  defp field_label(:sequence_group), do: gettext("Related blocks")
  defp field_label(:locked), do: gettext("Locked")
  defp field_label(:day), do: gettext("Day")
  defp field_label(field) when field in [:slot, :new_slot], do: gettext("Time")
  defp field_label(:starts_on), do: gettext("First day")
  defp field_label(:ends_on), do: gettext("Last day")
  defp field_label(:excluded_dates), do: gettext("Non-teaching dates")
  defp field_label(:weeks_count), do: gettext("Teaching weeks")
  defp field_label(:occurrence_date), do: gettext("Date")
  defp field_label(:new_date), do: gettext("New date")
  defp field_label(:availability), do: gettext("Availability")
  defp field_label(:cells), do: gettext("Allowed start times")
  defp field_label(:reason), do: gettext("Reason")
  defp field_label(:created_by), do: gettext("Author")
  defp field_label(:kind), do: gettext("Kind")
  defp field_label(:status), do: gettext("Status")
  defp field_label(:locale), do: gettext("Language")
  defp field_label(_field), do: gettext("Value")
end
