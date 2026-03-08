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

  # Health check outside browser pipeline to bypass force_ssl (Fly checks hit HTTP directly)
  scope "/", AlgedoniaWeb do
    get "/health", HealthController, :index
  end

  scope "/", AlgedoniaWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/github", AuthController, :github
    get "/auth/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :delete
    get "/install.sh", InstallController, :install_script
    get "/releases/:filename", InstallController, :release
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
    get "/tickets/:ticket_ref/export/markdown", TicketExportController, :export_markdown

    live_session :default, on_mount: [AlgedoniaWeb.PresenceHook] do
      live "/monitor", MonitorLive.Index, :index

      live "/tickets", TicketLive.Index, :index
      live "/tickets/new", TicketLive.Index, :new
      live "/tickets/:ticket_ref", TicketLive.Index, :show
      live "/tickets/:ticket_ref/edit", TicketLive.Index, :edit
      live "/tickets/:ticket_ref/loops/:loop_ref", LoopLive.Show, :show

      live "/skills", SkillsLive.Index, :index
      live "/settings", SettingsLive.Index, :index
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

      post "/tickets/reorder", TicketController, :reorder
      resources "/tickets", TicketController, except: [:new, :edit]
      get "/tickets/:id/export/markdown", TicketController, :export_markdown

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
