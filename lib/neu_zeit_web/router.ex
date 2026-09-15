defmodule NeuZeitWeb.Router do
  use NeuZeitWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NeuZeitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug NeuZeitWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NeuZeitWeb do
    pipe_through :browser

    get "/", PageController, :home
    post "/locale", LocaleController, :update

    live_session :default, on_mount: [NeuZeitWeb.Locale, NeuZeitWeb.NavigationContext] do
      live "/terms", TermLive.Index, :index
      live "/settings", SettingsLive.Index, :index
      live "/teaching-types", TeachingTypeLive.Index, :index
      live "/teaching-types/new", TeachingTypeLive.Index, :new
      live "/teaching-types/:id/edit", TeachingTypeLive.Index, :edit
      live "/terms/new", TermLive.Index, :new
      live "/terms/:id/edit", TermLive.Index, :edit
      live "/terms/:id", TermLive.Show, :show

      live "/rooms", RoomLive.Index, :index
      live "/rooms/new", RoomLive.Index, :new_room
      live "/rooms/buildings/new", RoomLive.Index, :new_building
      live "/rooms/buildings/:id/edit", RoomLive.Index, :edit_building
      live "/rooms/:id/edit", RoomLive.Index, :edit_room

      live "/courses", CourseLive.Index, :index
      live "/courses/new", CourseLive.Index, :new
      live "/courses/:id/edit", CourseLive.Index, :edit
      live "/courses/:id", CourseLive.Show, :show

      live "/people", PeopleLive.Index, :index

      live "/terms/:term_id/slot-profiles", SlotProfileLive.Index, :index
      live "/terms/:term_id/slot-profiles/new", SlotProfileLive.Index, :new
      live "/terms/:term_id/slot-profiles/:id/edit", SlotProfileLive.Index, :edit

      live "/terms/:term_id/availability", AvailabilityLive.Index, :index
      live "/terms/:term_id/availability/:teacher_id", AvailabilityLive.Index, :show

      live "/terms/:term_id/settings", TermLive.Settings, :index

      live "/terms/:term_id/workload", WorkloadLive.Index, :index
      live "/terms/:term_id/workload/new", WorkloadLive.Index, :new
      live "/terms/:term_id/workload/:id/edit", WorkloadLive.Index, :edit

      live "/terms/:term_id/sessions", SessionLive.Index, :index
      live "/terms/:term_id/sessions/new", SessionLive.Index, :new
      live "/terms/:term_id/sessions/:id/edit", SessionLive.Index, :edit

      live "/terms/:term_id/plans", PlanLive.Index, :index
      live "/terms/:term_id/plans/:id/rename", PlanLive.Index, :rename
      live "/terms/:term_id/plans/:id", PlanLive.Show, :show

      live "/terms/:term_id/calendar", CalendarLive.Index, :index

      live "/terms/:term_id/exceptions", ExceptionLive.Index, :index
      live "/terms/:term_id/exceptions/new", ExceptionLive.Index, :new
      live "/terms/:term_id/exceptions/:id/edit", ExceptionLive.Index, :edit
    end
  end

  use NeuZeitWeb.DevRoutes

  scope "/api", NeuZeitWeb do
    pipe_through :api

    resources "/terms", TermController, except: [:new, :edit] do
      resources "/workloads", WorkloadController, except: [:new, :edit]
      get "/occurrences", ScheduleController, :occurrences
      get "/coverage", CurriculumController, :term_coverage
      get "/courses/:course_id/coverage", CurriculumController, :coverage
      post "/excluded_dates", TermController, :add_excluded_date
      delete "/excluded_dates/:date", TermController, :remove_excluded_date
      post "/slot_profiles/defaults", SlotProfileController, :create_defaults
      get "/teachers/:teacher_id/availability", TeacherAvailabilityController, :show
      put "/teachers/:teacher_id/availability", TeacherAvailabilityController, :replace
    end

    resources "/buildings", BuildingController, except: [:new, :edit]

    resources "/rooms", RoomController, except: [:new, :edit]

    resources "/courses", CourseController, except: [:new, :edit] do
      get "/translations", CourseController, :translations
      post "/translations", CourseController, :create_translation
      put "/translations/:locale", CourseController, :update_translation
      patch "/translations/:locale", CourseController, :update_translation
      delete "/translations/:locale", CourseController, :delete_translation
    end

    resources "/course_components", CourseComponentController, except: [:new, :edit]
    resources "/teaching_types", TeachingTypeController, except: [:new, :edit]

    resources "/teachers", TeacherController, except: [:new, :edit]

    resources "/cohorts", CohortController, except: [:new, :edit]

    resources "/sessions", SessionController, except: [:new, :edit]

    resources "/slot_profiles", SlotProfileController, except: [:new, :edit]

    resources "/plans", PlanController, except: [:new, :edit] do
      post "/clone", PlanController, :clone

      post "/publish", PlanController, :publish

      get "/checks", PlanController, :checks

      get "/advisories", PlanController, :advisories

      get "/quality", PlanController, :quality
      get "/coverage", CurriculumController, :plan_coverage

      post "/solve", PlanController, :solve
    end

    resources "/placements", PlacementController, except: [:new, :edit]

    resources "/schedule_exceptions", ScheduleExceptionController, except: [:new, :edit]

    match :*, "/*path", NotFoundController, :not_found
  end
end
