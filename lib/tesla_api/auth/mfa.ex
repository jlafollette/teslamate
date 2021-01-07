defmodule TeslaApi.Auth.MFA do
  use Tesla

  require Logger

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 15_000

  plug Tesla.Middleware.BaseUrl, "https://auth.tesla.com"
  plug Tesla.Middleware.Headers, [{"x-requested-with", "com.teslamotors.tesla"}]
  plug Tesla.Middleware.JSON

  alias TeslaApi.Error

  @web_client_id "ownerapi"
  @client_id "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384"
  @client_secret "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3"

  defmodule Ctx do
    defstruct [:state, :code_verifier, :transaction_id, :headers, :devices]
  end

  def login(email, password) do
    state = random_string(15)
    code_verifier = random_code_verifier()

    with {:ok, form_data} <- load_form(state, code_verifier),
         {:ok, env = %Tesla.Env{}} <- submit_form(form_data, email, password),
         {:ok, {redirect_uri, code}} <- parse_location_header(env, state),
         {:ok, access_token} <- get_web_token(code, code_verifier, redirect_uri, state),
         {:ok, auth} <- get_api_tokens(access_token) do
      {:ok, auth}
    end
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, %Error{reason: e, message: "An unexpected error occurred"}}
  end

  def login(device_id, mfa_passcode, %Ctx{} = ctx) do
    with {:ok, env} <- verify_passcode(device_id, mfa_passcode, ctx),
         {:ok, {redirect_uri, code}} <- parse_location_header(env, ctx.state),
         {:ok, access_token} <- get_web_token(code, ctx.code_verifier, redirect_uri, ctx.state),
         {:ok, auth} <- get_api_tokens(access_token) do
      {:ok, auth}
    end
  rescue
    e ->
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, %Error{reason: e, message: "An unexpected error occurred"}}
  end

  def login(email, password, mfa_passcode) when is_binary(mfa_passcode) do
    with {:ok, {:mfa, [%{"id" => id} | _], ctx}} <- login(email, password) do
      login(id, mfa_passcode, ctx)
    end
  end

  defp load_form(state, code_verifier) do
    params = [
      client_id: @web_client_id,
      redirect_uri: "https://auth.tesla.com/void/callback",
      response_type: "code",
      scope: "openid email offline_access",
      code_challenge: challenge(code_verifier),
      code_challenge_method: "S265",
      state: state
    ]

    case get("/oauth2/v3/authorize", query: params) do
      {:ok, %Tesla.Env{status: 200, headers: resp_headers, body: resp_body}} ->
        cookies =
          resp_headers
          |> Enum.filter(&match?({"set-cookie", _}, &1))
          |> Enum.map(fn {_, cookie} -> cookie |> String.split(";") |> hd() end)
          |> Enum.join("; ")

        form =
          Floki.parse_document!(resp_body)
          |> Floki.find("form input")
          |> Map.new(fn input ->
            [key] = input |> Floki.attribute("name")
            value = input |> Floki.attribute("value") |> List.first()
            {key, value}
          end)

        {:ok, {form, cookies, state, code_verifier}}

      {:ok, %Tesla.Env{status: 200} = env} ->
        {:error, %Error{reason: :invalid_credentials, message: "Invalid credentials", env: env}}

      error ->
        handle_error(error, :authorization_request_failed)
    end
  end

  defp submit_form({form, cookies, state, code_verifier}, username, password) do
    transaction_id = Map.fetch!(form, "transaction_id")

    encoded_form =
      form
      |> Map.replace!("identity", username)
      |> Map.replace!("credential", password)
      |> URI.encode_query()

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Cookie", cookies}
    ]

    case post("/oauth2/v3/authorize", encoded_form, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: body} = env} ->
        if String.contains?(body, "/oauth2/v3/authorize/mfa/verify") do
          headers = [{"referer", env.url}, {"cookie", cookies}]

          with {:ok, devices} <- list_devices(transaction_id, headers) do
            ctx = %Ctx{
              state: state,
              code_verifier: code_verifier,
              transaction_id: transaction_id,
              headers: headers,
              devices: devices
            }

            {:ok, {:mfa, devices, ctx}}
          end
        else
          {:error, %Error{reason: :mfa_input_not_found, env: env}}
        end

      {:ok, %Tesla.Env{status: 302} = env} ->
        {:ok, env}

      {:ok, %Tesla.Env{status: 401} = env} ->
        message = "Invalid email address and password combination"
        {:error, %Error{reason: :invalid_credentials, message: message, env: env}}

      error ->
        handle_error(error, :authorization_failed)
    end
  end

  defp list_devices(transaction_id, headers) do
    params = [transaction_id: transaction_id]

    case get("/oauth2/v3/authorize/mfa/factors", query: params, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: %{"data" => devices}}} ->
        {:ok, devices}

      error ->
        handle_error(error, :mfa_factor_lookup_failed)
    end
  end

  defp verify_passcode(device_id, mfa_passcode, %Ctx{} = ctx) do
    params = [transaction_id: ctx.transaction_id]

    data = %{
      transaction_id: ctx.transaction_id,
      factor_id: device_id,
      passcode: mfa_passcode
    }

    case post("/oauth2/v3/authorize/mfa/verify", data, headers: ctx.headers) do
      {:ok, %Tesla.Env{status: 200, body: body} = env} ->
        case body do
          %{"data" => %{"approved" => true, "valid" => true}} ->
            case get("/oauth2/v3/authorize", query: params, headers: ctx.headers) do
              {:ok, %Tesla.Env{status: 302} = env} ->
                {:ok, env}

              error ->
                handle_error(error)
            end

          %{"data" => %{}} ->
            error = %Error{
              reason: :mfa_passcode_invalid,
              message: "Incorrect verfification code",
              env: env
            }

            {:error, error}
        end

      error ->
        handle_error(error, :mfa_verification_failed)
    end
  end

  defp parse_location_header(%Tesla.Env{status: 302} = env, state) do
    {query, uri} =
      env
      |> Tesla.get_header("location")
      |> URI.parse()
      |> Map.get_and_update!(:query, &{&1, nil})

    %{"code" => code, "state" => ^state} = URI.decode_query(query)

    {:ok, {URI.to_string(uri), code}}
  end

  defp get_web_token(code, code_verifier, redirect_uri, state) do
    data = %{
      grant_type: "authorization_code",
      client_id: @web_client_id,
      code: code,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri
    }

    case post("/oauth2/v3/token", data) do
      {:ok, %Tesla.Env{status: 200, body: %{"access_token" => access_token, "state" => ^state}}} ->
        {:ok, access_token}

      error ->
        handle_error(error, :web_token_error)
    end
  end

  defp get_api_tokens(access_token) do
    data = %{
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      client_id: @client_id,
      client_secret: @client_secret
    }

    headers = [{"Authorization", "Bearer #{access_token}"}]

    case post("https://owner-api.teslamotors.com/oauth/token", data, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        auth = %TeslaApi.Auth{
          token: body["access_token"],
          type: body["token_type"],
          expires_in: body["expires_in"],
          refresh_token: body["refresh_token"],
          created_at: body["created_at"]
        }

        {:ok, auth}

      error ->
        handle_error(error, :api_token_error)
    end
  end

  defp handle_error(response, reason \\ :unknown)

  defp handle_error({:ok, %Tesla.Env{} = env}, reason) do
    message =
      case env.body do
        %{"error" => %{"message" => message}} when is_binary(message) ->
          message

        body when is_binary(body) ->
          case Floki.parse_document(body) do
            {:error, _} -> body
            {:ok, _} -> nil
          end

        _ ->
          nil
      end

    {:error, %Error{reason: reason, message: message, env: env}}
  end

  defp handle_error({:error, reason}, _reason) when is_atom(reason) do
    {:error, %Error{reason: reason}}
  end

  defp handle_error({:error, error}, reason) do
    {:error, %Error{reason: reason, message: error}}
  end

  defp random_code_verifier do
    random_string(86) |> base64_url_encode()
  end

  defp challenge(value) do
    value
    |> (&:crypto.hash(:sha256, &1)).()
    |> base64_url_encode()
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> base64_url_encode()
    |> binary_part(0, length)
  end

  defp base64_url_encode(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end
end
