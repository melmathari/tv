defmodule Algora.Accounts do
  import Ecto.Query
  import Ecto.Changeset

  alias Algora.{Repo, Restream, Google}
  alias Algora.Accounts.{User, Identity, Destination, Entity}

  def list_users(opts) do
    Repo.all(from u in User, limit: ^Keyword.fetch!(opts, :limit))
  end

  def get_users_map(user_ids) when is_list(user_ids) do
    Repo.all(from u in User, where: u.id in ^user_ids, select: {u.id, u})
  end

  def admin?(%User{} = user) do
    user.email in Algora.config([:admin_emails])
  end

  def update_settings(%User{} = user, attrs) do
    user |> change_settings(attrs) |> Repo.update()
  end

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id), do: Repo.get(User, id)

  def get_user_by(fields), do: Repo.get_by(User, fields)

  def get_user_by!(fields), do: Repo.get_by!(User, fields)

  ## User registration

  @doc """
  Registers a user from their GitHub information.
  """
  def register_github_user(primary_email, info, emails, token) do
    if user = get_user_by_provider_email(:github, primary_email) do
      update_github_token(user, token)
    else
      info
      |> User.github_registration_changeset(primary_email, emails, token)
      |> Repo.insert()
    end
  end

  def link_restream_account(user_id, info, tokens) do
    user = get_user!(user_id)

    identity =
      from(u in User,
        join: i in assoc(u, :identities),
        where: i.provider == ^to_string(:restream) and u.id == ^user_id
      )
      |> Repo.one()

    if identity do
      update_restream_tokens(user, tokens)
    else
      {:ok, _} =
        info
        |> Identity.restream_oauth_changeset(user_id, tokens)
        |> Repo.insert()

      {:ok, Repo.preload(user, :identities, force: true)}
    end
  end

  def get_user_by_provider_email(provider, email) when provider in [:github] do
    query =
      from(u in User,
        join: i in assoc(u, :identities),
        where:
          i.provider == ^to_string(provider) and
            fragment("lower(?)", u.email) == ^String.downcase(email)
      )

    Repo.one(query)
  end

  def get_user_by_provider_id(provider, id) when provider in [:github] do
    query =
      from(u in User,
        join: i in assoc(u, :identities),
        where: i.provider == ^to_string(provider) and i.provider_id == ^id
      )

    Repo.one(query)
  end

  def change_settings(%User{} = user, attrs) do
    User.settings_changeset(user, attrs)
  end

  defp update_github_token(%User{} = user, new_token) do
    identity =
      Repo.one!(from(i in Identity, where: i.user_id == ^user.id and i.provider == "github"))

    {:ok, _} =
      identity
      |> change()
      |> put_change(:provider_token, new_token)
      |> Repo.update()

    {:ok, Repo.preload(user, :identities, force: true)}
  end

  defp update_restream_tokens(%User{} = user, %{token: token, refresh_token: refresh_token}) do
    identity =
      Repo.one!(from(i in Identity, where: i.user_id == ^user.id and i.provider == "restream"))

    {:ok, _} =
      identity
      |> change()
      |> put_change(:provider_token, token)
      |> put_change(:provider_refresh_token, refresh_token)
      |> Repo.update()

    {:ok, Repo.preload(user, :identities, force: true)}
  end

  def refresh_restream_tokens(%User{} = user) do
    identity =
      Repo.one!(from(i in Identity, where: i.user_id == ^user.id and i.provider == "restream"))

    {:ok, tokens} = Restream.refresh_access_token(identity.provider_refresh_token)
    update_restream_tokens(user, tokens)

    {:ok, tokens}
  end

  def has_restream_token?(%User{} = user) do
    query = from(i in Identity, where: i.user_id == ^user.id and i.provider == "restream")
    Repo.one(query) != nil
  end

  def update_google_token(user, %{token: access_token, refresh_token: refresh_token}) do
    identity = Repo.get_by!(Identity, user_id: user.id, provider: "google")

    Identity.changeset(identity, %{
      provider_token: access_token,
      provider_refresh_token: refresh_token
    })
    |> Repo.update()
  end

  def refresh_google_tokens(%User{} = user) do
    identity =
      Repo.one!(from(i in Identity, where: i.user_id == ^user.id and i.provider == "google"))

    case Google.refresh_access_token(identity.provider_refresh_token) do
      {:ok, tokens} ->
        update_google_token(user, tokens)
        {:ok, tokens}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def has_google_token?(%User{} = user) do
    query = from(i in Identity, where: i.user_id == ^user.id and i.provider == "google")
    Repo.one(query) != nil
  end

  def get_google_token(%User{} = user) do
    query = from(i in Identity, where: i.user_id == ^user.id and i.provider == "google")

    with identity when identity != nil <- Repo.one(query),
         {:ok, %{token: token}} <- refresh_google_tokens(user) do
      token
    else
      _ -> nil
    end
  end

  def get_restream_token(%User{} = user) do
    query = from(i in Identity, where: i.user_id == ^user.id and i.provider == "restream")

    with identity when identity != nil <- Repo.one(query),
         {:ok, %{token: token}} <- refresh_restream_tokens(user) do
      token
    else
      _ -> nil
    end
  end

  def get_restream_ws_url(%User{} = user) do
    if token = get_restream_token(user), do: Restream.websocket_url(token)
  end

  def gen_stream_key(%User{} = user) do
    user =
      Repo.one!(from(u in User, where: u.id == ^user.id))

    token = :crypto.strong_rand_bytes(32)
    hashed_token = :crypto.hash(:sha256, token)
    encoded_token = Base.url_encode64(hashed_token, padding: false)

    user
    |> change()
    |> put_change(:stream_key, encoded_token)
    |> Repo.update()
  end

  def list_destinations(user_id) do
    Repo.all(from d in Destination, where: d.user_id == ^user_id, order_by: [asc: d.id])
  end

  def list_active_destinations(user_id) do
    Repo.all(
      from d in Destination,
        where: d.user_id == ^user_id and d.active == true,
        order_by: [asc: d.id]
    )
  end

  def get_destination!(id), do: Repo.get!(Destination, id)

  def change_destination(%Destination{} = destination, attrs \\ %{}) do
    destination |> Destination.changeset(attrs)
  end

  def create_destination(user, attrs \\ %{}) do
    %Destination{}
    |> Destination.changeset(attrs)
    |> put_change(:user_id, user.id)
    |> Repo.insert()
  end

  def update_destination(%Destination{} = destination, attrs) do
    destination
    |> Destination.changeset(attrs)
    |> Repo.update()
  end

  def create_entity!(%User{} = user) do
    create_entity!(%{
      user_id: user.id,
      name: user.name,
      handle: user.handle,
      avatar_url: user.avatar_url,
      platform: "algora",
      platform_id: Integer.to_string(user.id),
      platform_meta: %{}
    })
  end

  def create_entity!(attrs) do
    case %Entity{}
         |> Entity.changeset(attrs)
         |> Repo.insert() do
      {:ok, entity} ->
        entity

      _ when attrs.id != attrs.handle ->
        create_entity!(%{attrs | handle: attrs.id})
    end
  end

  def get_entity!(id), do: Repo.get!(Entity, id)

  def get_entity(id), do: Repo.get(Entity, id)

  def get_entity_by(fields), do: Repo.get_by(Entity, fields)

  def get_or_create_entity!(%User{} = user) do
    case get_entity_by(user_id: user.id) do
      nil -> create_entity!(user)
      entity -> entity
    end
  end

  def get_or_create_entity!(%{platform: platform, platform_id: platform_id} = attrs) do
    case get_entity_by(platform: platform, platform_id: platform_id) do
      nil -> create_entity!(attrs)
      entity -> entity
    end
  end
end
