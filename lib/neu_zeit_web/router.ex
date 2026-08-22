defmodule NeuZeitWeb.Router do
  use NeuZeitWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", NeuZeitWeb do
    pipe_through :api

    resources "/terms", TermController, except: [:new, :edit] do
      get "/occurrences", ScheduleController, :occurrences
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
      post "/translations", CourseController, :create_translation
    end

    resources "/course_components", CourseComponentController, except: [:new, :edit]

    resources "/teachers", TeacherController, except: [:new, :edit]

    resources "/cohorts", CohortController, except: [:new, :edit]

    resources "/sessions", SessionController, except: [:new, :edit]

    resources "/slot_profiles", SlotProfileController, except: [:new, :edit]

    resources "/plans", PlanController, except: [:new, :edit] do
      post "/clone", PlanController, :clone

      post "/publish", PlanController, :publish

      get "/checks", PlanController, :checks

      get "/advisories", PlanController, :advisories

      post "/solve", PlanController, :solve
    end

    resources "/placements", PlacementController, except: [:new, :edit]

    resources "/schedule_exceptions", ScheduleExceptionController, except: [:new, :edit]

    match :*, "/*path", NotFoundController, :not_found
  end
end
