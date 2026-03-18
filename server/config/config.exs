# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

terminal_image_drop_max_bytes =
  case Integer.parse(System.get_env("ALGEDONIA_TERMINAL_IMAGE_DROP_MAX_BYTES") || "") do
    {value, ""} when value > 0 -> value
    _ -> 10 * 1_024 * 1_024
  end

config :algedonia,
  ecto_repos: [Algedonia.Repo],
  generators: [timestamp_type: :utc_datetime],
  default_coding_agent: :codex,
  overview_model: "claude-haiku-4-5-20251001",
  terminal_ws_base_url: "ws://127.0.0.1:8765/terminal/ws",
  terminal_image_drop_max_bytes: terminal_image_drop_max_bytes

# Configure the endpoint
config :algedonia, AlgedoniaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AlgedoniaWeb.ErrorHTML, json: AlgedoniaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Algedonia.PubSub,
  live_view: [signing_salt: "wZ7y67Yh"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :algedonia, Algedonia.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  algedonia: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  algedonia: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
