defmodule AlgedoniaWeb.InstallController do
  @moduledoc """
  Serves the daemon install script and proxies binary downloads from Supabase Storage.
  """
  use AlgedoniaWeb, :controller

  @valid_filename ~r/^ag_(darwin|linux)_(arm64|amd64)\.tar\.gz$/

  def install_script(conn, _params) do
    host = AlgedoniaWeb.Endpoint.url()

    script = """
    #!/bin/sh
    set -e

    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
      darwin) OS="darwin" ;;
      linux)  OS="linux" ;;
      *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
    esac

    case "$ARCH" in
      x86_64|amd64) ARCH="amd64" ;;
      arm64|aarch64) ARCH="arm64" ;;
      *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac

    FILENAME="ag_${OS}_${ARCH}.tar.gz"
    DOWNLOAD_URL="#{host}/releases/${FILENAME}"
    INSTALL_DIR="${HOME}/.local/bin"

    echo "Downloading ag for ${OS}/${ARCH}..."
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$DOWNLOAD_URL" | tar xz -C "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/ag"

    echo ""
    echo "ag installed to $INSTALL_DIR/ag"
    echo ""

    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
      echo "Add $INSTALL_DIR to your PATH:"
      echo "  export PATH=\\\"$INSTALL_DIR:\\$PATH\\\""
      echo ""
    fi

    echo "Next, connect to your server:"
    echo "  ag login"
    echo ""
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script)
  end

  def release(conn, %{"filename" => filename}) do
    if Regex.match?(@valid_filename, filename) do
      proxy_from_supabase(conn, filename)
    else
      conn
      |> put_status(:not_found)
      |> text("Not found")
    end
  end

  defp proxy_from_supabase(conn, filename) do
    bucket_url = daemon_releases_bucket_url()
    url = "#{bucket_url}/#{filename}"

    case Req.get(url, into: :self) do
      {:ok, %Req.Response{status: 200} = resp} ->
        conn =
          conn
          |> put_resp_content_type("application/gzip")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
          |> send_chunked(200)

        stream_response(conn, resp)

      {:ok, %Req.Response{status: status}} ->
        conn
        |> put_status(status)
        |> text("Release not found")

      {:error, _reason} ->
        conn
        |> put_status(:bad_gateway)
        |> text("Failed to fetch release")
    end
  end

  defp stream_response(conn, resp) do
    Enum.reduce_while(resp.body, conn, fn chunk, conn ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp daemon_releases_bucket_url do
    Application.get_env(:algedonia, :daemon_releases)[:supabase_bucket_url] ||
      raise "daemon_releases supabase_bucket_url not configured"
  end
end
