defmodule NeuZeitWeb.DevRoutes do
  @moduledoc false
  @enabled Application.compile_env(:neu_zeit, :dev_routes, false)

  defmacro __using__(_opts) do
    # Exclude the import before macro expansion: Storybook is not a production dependency.
    if @enabled do
      quote do
        import PhoenixStorybook.Router

        scope "/" do
          storybook_assets("/dev/storybook/assets")

          live_storybook("/dev/storybook",
            backend_module: NeuZeitWeb.Storybook,
            assets_path: "/dev/storybook/assets"
          )
        end
      end
    end
  end
end
