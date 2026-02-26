defmodule AlgedoniaWeb.Router do
  use AlgedoniaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlgedoniaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug :accepts, ["json"]
    plug AlgedoniaWeb.Plugs.ApiAuth
  end

  scope "/", AlgedoniaWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/github", AuthController, :github
    get "/auth/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :delete
  end

  scope "/", AlgedoniaWeb do
    pipe_through [:browser, AlgedoniaWeb.Plugs.RequireUser]

    live_session :onboarding, on_mount: [AlgedoniaWeb.OnboardingHook] do
      live "/onboarding", OnboardingLive, :index
    end
  end

  scope "/w/:workspace", AlgedoniaWeb do
    pipe_through [:browser, AlgedoniaWeb.Plugs.RequireUser, AlgedoniaWeb.Plugs.RequireWorkspace]

    get "/", PageController, :workspace_home

    live_session :default, on_mount: [AlgedoniaWeb.PresenceHook] do
      live "/monitor", MonitorLive.Index, :index
      live "/loops/:loop_id", LoopLive.Show, :show

      live "/tickets", TicketLive.Index, :index
      live "/tickets/new", TicketLive.Index, :new
      live "/tickets/:id", TicketLive.Index, :show
      live "/tickets/:id/edit", TicketLive.Index, :edit

      live "/dags/:ticket_id", DagLive.Show, :show
    end
  end

  scope "/api", AlgedoniaWeb do
    pipe_through :api

    post "/auth/device/code", AuthController, :device_code
    post "/auth/device/poll", AuthController, :device_poll
  end

  scope "/api", AlgedoniaWeb.Api do
    pipe_through :api_auth

    post "/terminal/verify", TerminalController, :verify
    get "/workspaces", WorkspaceController, :index

    scope "/w/:workspace" do
      pipe_through AlgedoniaWeb.Plugs.ApiWorkspace

      resources "/tickets", TicketController, except: [:new, :edit]

      resources "/tickets/:ticket_id/comments", CommentController,
        only: [:index, :create, :update, :delete]
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:algedonia, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AlgedoniaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
