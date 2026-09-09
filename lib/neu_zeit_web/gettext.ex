defmodule NeuZeitWeb.Gettext do
  @moduledoc """
  Gettext backend for Russian, English and German UI text.

      use Gettext, backend: NeuZeitWeb.Gettext

  Use `gettext/1` for messages, `ngettext/3` for counts and the `errors` domain
  for validation messages. Writing rules: `.agents/skills/project-writer/SKILL.md`.
  """
  use Gettext.Backend, otp_app: :neu_zeit
end
