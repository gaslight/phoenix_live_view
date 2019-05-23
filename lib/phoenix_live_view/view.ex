defmodule Phoenix.LiveView.View do
  @moduledoc false
  import Phoenix.HTML, only: [sigil_E: 2]

  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  @max_session_age 1_209_600

  # Total length of 8 bytes when 64 encoded
  @rand_bytes 6

  @doc """
  Strips socket of redudant assign data for rendering.
  """
  def strip_for_render(%Socket{} = socket) do
    if connected?(socket) do
      %Socket{socket | assigns: %{}}
    else
      socket
    end
  end

  @doc """
  Clears the changes from the socket assigns.
  """
  def clear_changed(%Socket{} = socket) do
    %Socket{socket | changed: %{}}
  end

  @doc """
  Checks if the socket changed.
  """
  def changed?(%Socket{changed: changed}), do: changed != %{}

  @doc """
  Returns the socket's flash messages.
  """
  def get_flash(%Socket{private: private}) do
    private[:flash]
  end

  @doc """
  Puts the root fingerprint.
  """
  def put_prints(%Socket{} = socket, fingerprints) do
    %Socket{socket | fingerprints: fingerprints}
  end

  @doc """
  Returns the browser's DOM id for the socket's view.
  """
  def dom_id(%Socket{id: id}), do: id

  @doc """
  Returns the browser's DOM id for the nested socket.
  """
  def child_dom_id(%Socket{id: parent_id}, child_view, nil = _child_id) do
    parent_id <> inspect(child_view)
  end

  def child_dom_id(%Socket{id: parent_id}, child_view, child_id) do
    parent_id <> inspect(child_view) <> to_string(child_id)
  end

  @doc """
  Returns true if the socket is connected.
  """
  def connected?(%Socket{connected?: true}), do: true
  def connected?(%Socket{connected?: false}), do: false

  @doc """
  Builds a `%Phoenix.LiveView.Socket{}`.
  """
  def build_socket(endpoint, router, %{} = opts) when is_atom(endpoint) do
    {id, opts} = Map.pop_lazy(opts, :id, fn -> random_id() end)
    {{%{}, _} = assigned_new, opts} = Map.pop(opts, :assigned_new, {%{}, []})

    struct!(
      %Socket{id: id, endpoint: endpoint, router: router, private: %{assigned_new: assigned_new}},
      opts
    )
  end

  @doc """
  Builds a nested child `%Phoenix.LiveView.Socket{}`.
  """
  def build_nested_socket(%Socket{endpoint: endpoint, router: router} = parent, child_id, view) do
    id = child_dom_id(parent, view, child_id)

    build_socket(endpoint, router, %{
      id: id,
      parent_pid: self(),
      assigned_new: {parent.assigns, []}
    })
  end

  @doc """
  Prunes the assigned_new information from the socket.
  """
  def prune_assigned_new(%Socket{private: private} = socket) do
    %Socket{socket | private: Map.delete(private, :assigned_new)}
  end

  @doc """
  Annotates the socket for redirect.
  """
  def put_redirect(%Socket{stopped: nil} = socket, to) do
    %Socket{socket | stopped: {:redirect, %{to: to}}}
  end

  def put_redirect(%Socket{stopped: reason} = _socket, _to) do
    raise ArgumentError, "socket already prepared to stop for #{inspect(reason)}"
  end

  @doc """
  Annotates the socket for live redirect.
  """
  def put_live_redirect(%Socket{} = socket, to) do
    %Socket{socket | private: Map.put(socket.private, :live_redirect, to)}
  end

  def get_live_redirect(%Socket{} = socket) do
    socket.private[:live_redirect]
  end

  def drop_live_redirect(%Socket{} = socket) do
    %Socket{socket | private: Map.delete(socket.private, :live_redirect)}
  end

  @doc """
  Renders the view into a `%Phoenix.LiveView.Rendered{}` struct.
  """
  def render(%Socket{} = socket, view) do
    assigns = Map.put(socket.assigns, :socket, strip_for_render(socket))

    case view.render(assigns) do
      %Phoenix.LiveView.Rendered{} = rendered ->
        rendered

      other ->
        raise RuntimeError, """
        expected #{inspect(view)}.render/1 to return a %Phoenix.LiveView.Rendered{} struct

        Ensure your render function uses ~L, or your eex template uses the .leex extension.

        Got:

            #{inspect(other)}

        """
    end
  end

  @doc """
  Verifies the session token.

  Returns the decoded map of session data or an error.

  ## Examples

      iex> verify_session(AppWeb.Endpoint, encoded_token, static_token)
      {:ok, %{} = decoeded_session}

      iex> verify_session(AppWeb.Endpoint, "bad token", "bac static")
      {:error, :invalid}

      iex> verify_session(AppWeb.Endpoint, "expired", "expired static")
      {:error, :expired}
  """
  def verify_session(endpoint, session_token, static_token) do
    with {:ok, session} <- verify_token(endpoint, session_token),
         {:ok, static} <- verify_static_token(endpoint, static_token) do
      {:ok, Map.merge(session, static)}
    end
  end

  defp verify_static_token(_endpoint, nil), do: {:ok, %{assigned_new: []}}
  defp verify_static_token(endpoint, token), do: verify_token(endpoint, token)

  defp verify_token(endpoint, token) do
    case Phoenix.Token.verify(endpoint, salt(endpoint), token, max_age: @max_session_age) do
      {:ok, term} -> {:ok, term}
      {:error, _} = error -> error
    end
  end

  @doc """
  Signs the socket's flash into a token if it has been set.
  """
  def sign_flash(%Socket{}, nil), do: nil

  def sign_flash(%Socket{endpoint: endpoint}, %{} = flash) do
    LiveView.Flash.sign_token(endpoint, salt(endpoint), flash)
  end

  @doc """
  Raises error message for invalid view mount.
  """
  def raise_invalid_mount(other, view) do
    raise ArgumentError, """
    invalid result returned from #{inspect(view)}.mount/2.

    Expected {:ok, socket}, got: #{inspect(other)}
    """
  end

  @doc """
  Renders a live view without spawning a LiveView server.

  * `conn` - the Plug.Conn struct form the HTTP request
  * `view` - the LiveView module

  ## Options

    * `:session` - the required map of session data
    * `:container` - the optional tuple for the HTML tag and DOM attributes to
      be used for the LiveView container. For example: `{:li, style: "color: blue;"}`
  """
  def static_render(%Plug.Conn{} = conn, view, opts) do
    session = Keyword.fetch!(opts, :session)
    {tag, extended_attrs} = opts[:container] || {:div, []}

    case static_mount(conn, view, session) do
      {:ok, socket, session_token} ->
        attrs = [
          {:id, dom_id(socket)},
          {:data, phx_view: inspect(view), phx_session: session_token} | extended_attrs
        ]

        html = ~E"""
        <%= Phoenix.HTML.Tag.content_tag(tag, attrs) do %>
          <%= render(socket, view) %>
        <% end %>
        """

        {:ok, html}

      {:stop, reason} ->
        {:stop, reason}
    end
  catch
    :throw, {:stop, reason} -> {:stop, reason}
  end

  @doc """
  Renders only the static container of the Liveview.

  Accepts same options as `static_render/3`.
  """
  def static_render_container(%Plug.Conn{} = conn, view, opts) do
    session = Keyword.fetch!(opts, :session)
    {tag, extended_attrs} = opts[:container] || {:div, []}
    router = Phoenix.Controller.router_module(conn)
    socket =
      conn
      |> Phoenix.Controller.endpoint_module()
      |> build_socket(router, %{view: view, assigned_new: {conn.assigns, []}})

    session_token = sign_root_session(socket, view, session)

    attrs = [
      {:id, dom_id(socket)},
      {:data, phx_view: inspect(view), phx_session: session_token} | extended_attrs
    ]

    tag
    |> Phoenix.HTML.Tag.content_tag(attrs, do: nil)
    |> Phoenix.HTML.safe_to_string()
  end

  @doc """
  Renders a nested live view without spawning a server.

  * `parent` - the parent `%Phoenix.LiveView.Socket{}`
  * `view` - the child LiveView module

  Accepts the same options as `static_render/3`.
  """
  def nested_static_render(%Socket{} = parent, view, opts) do
    session = Keyword.fetch!(opts, :session)
    {_tag, _attrs} = container = opts[:container] || {:div, []}
    child_id = opts[:child_id]

    if connected?(parent) do
      connected_nested_static_render(parent, view, session, container, child_id)
    else
      disconnected_nested_static_render(parent, view, session, container, child_id)
    end
  end

  def configured_signing_salt!(endpoint) when is_atom(endpoint) do
    endpoint.config(:live_view)[:signing_salt] ||
      raise ArgumentError, """
      no signing salt found for #{inspect(endpoint)}.

      Add the following LiveView configuration to your config/config.exs:

          config :my_app, MyAppWeb.Endpoint,
              ...,
              live_view: [signing_salt: "#{random_encoded_bytes()}"]

      """
  end

  @doc """
  Returns the internal or external matched LiveView route info for the given uri
  """
  def live_link_info(%Socket{view: view, router: router}, uri) do
    %URI{host: host, path: path, query: query} = URI.parse(uri)
    query_params = if query, do: Plug.Conn.Query.decode(query), else: %{}

    case Phoenix.Router.route_info(router, "GET", path, host) do
      {%Phoenix.Router.Route{plug: Phoenix.LiveView.Plug, opts: ^view}, path_params} ->
        {:internal, Map.merge(query_params, path_params)}

      {%Phoenix.Router.Route{plug: _, opts: _external_view}, _params} ->
        :external

      :error -> :error
    end
  end

  defp disconnected_nested_static_render(parent, view, session, container, child_id) do
    {tag, extended_attrs} = container

    case nested_static_mount(parent, view, session, child_id) do
      {:ok, socket, static_token} ->
        attrs = [
          {:id, socket.id},
          {:data,
           phx_view: inspect(view),
           phx_session: "",
           phx_static: static_token,
           phx_parent_id: parent.id}
          | extended_attrs
        ]

        html = ~E"""
        <%= Phoenix.HTML.Tag.content_tag(tag, attrs) do %>
          <%= render(socket, view) %>
        <% end %>
        """

        {:ok, html}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  defp connected_nested_static_render(parent, view, session, container, child_id) do
    {tag, extended_attrs} = container
    socket = build_nested_socket(parent, child_id, view)
    session_token = sign_child_session(socket, view, session)

    attrs = [
      {:id, socket.id},
      {:data,
       phx_parent_id: dom_id(parent),
       phx_view: inspect(view),
       phx_session: session_token,
       phx_static: ""}
      | extended_attrs
    ]

    html = ~E"""
    <%= Phoenix.HTML.Tag.content_tag(tag, "", attrs) %>
    """

    {:ok, html}
  end

  defp nested_static_mount(%Socket{} = parent, view, session, child_id) do
    socket = build_nested_socket(parent, child_id, view)

    session
    |> view.mount(socket)
    |> case do
      {:ok, %Socket{} = new_socket} ->
        {:ok, new_socket, sign_static_token(new_socket)}

      {:stop, socket} ->
        {:stop, socket.stopped}

      other ->
        raise_invalid_mount(other, view)
    end
  end

  defp static_mount(%Plug.Conn{} = conn, view, session) do
    router = Phoenix.Controller.router_module(conn)

    conn
    |> Phoenix.Controller.endpoint_module()
    |> build_socket(router, %{view: view, assigned_new: {conn.assigns, []}})
    |> do_static_mount(view, session, conn.params)
  end

  defp do_static_mount(socket, view, session, params) do
    with {:ok, %Socket{} = mounted_socket} <- view.mount(session, socket),
         {:noreply, %Socket{} = new_socket} <- mount_handle_params(mounted_socket, view, params) do

        session_token = sign_root_session(socket, view, session)
        {:ok, new_socket, session_token}

    else
      {:stop, socket} ->
        {:stop, socket.stopped}

      other ->
        raise_invalid_mount(other, view)
    end
  end

  defp mount_handle_params(socket, view, params) do
    if function_exported?(view, :handle_params, 2) do
      view.handle_params(params, socket)
    else
      {:noreply, socket}
    end
  end

  defp sign_root_session(%Socket{id: dom_id, router: router} = socket, view, session) do
    sign_token(socket.endpoint, salt(socket), %{
      id: dom_id,
      view: view,
      router: router,
      parent_pid: nil,
      session: session
    })
  end

  defp sign_child_session(%Socket{id: dom_id, router: router} = socket, view, session) do
    sign_token(socket.endpoint, salt(socket), %{
      id: dom_id,
      view: view,
      router: router,
      parent_pid: self(),
      session: session
    })
  end

  defp sign_static_token(%Socket{id: dom_id} = socket) do
    sign_token(socket.endpoint, salt(socket), %{
      id: dom_id,
      assigned_new: assigned_new_keys(socket)
    })
  end

  defp salt(%Socket{endpoint: endpoint}) do
    salt(endpoint)
  end

  defp salt(endpoint) when is_atom(endpoint) do
    configured_signing_salt!(endpoint)
  end

  defp random_encoded_bytes do
    @rand_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  defp random_id, do: "phx-" <> random_encoded_bytes()

  defp sign_token(endpoint_mod, salt, data) do
    Phoenix.Token.sign(endpoint_mod, salt, data)
  end

  defp assigned_new_keys(socket) do
    {_, keys} = socket.private.assigned_new
    keys
  end
end
