defmodule TeslaApi.Auth do
  use Tesla

  require Logger

  alias TeslaApi.Error

  @web_client_id "ownerapi"
  @client_id "81527cff06843c8634fdc09e8ac0abefb46ac849f38fe1e431c2ef2106796384"
  @client_secret "c7257eb71a564034f9419ee651c7d0e5f7aa6bfbd18bafb5c5c033b093bb2fa3"
  @redirect_uri "https://auth.tesla.com/void/callback"

  @version Mix.Project.config()[:version]
  @default_headers [
    {"user-agent", "TeslaMate/#{@version}"},
    {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"},
    {"Accept-Language", "en-US,de-DE;q=0.5"}
  ]

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 60_000

  plug TeslaApi.Middleware.FollowRedirects, except: [@redirect_uri]
  plug Tesla.Middleware.BaseUrl, "https://auth.tesla.com"
  plug Tesla.Middleware.Headers, @default_headers
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Logger, debug: true, log_level: &log_level/1

  defstruct [:token, :type, :expires_in, :refresh_token, :created_at]

  def refresh(%__MODULE__{} = auth) do
    with {:ok, %{access_token: _} = tokens} <-
           refresh_oauth_access_token(auth.token, auth.refresh_token),
         {:ok, auth} <- get_api_tokens(tokens) do
      {:ok, auth}
    else
      error ->
        handle_error(error, :token_refresh)
    end
  end

  defp refresh_oauth_access_token(access_token, refresh_token) do
    data = %{
      grant_type: "refresh_token",
      scope: "openid email offline_access",
      client_id: @web_client_id,
      refresh_token: refresh_token
    }

    base_url =
      case access_token do
        "cn-" <> _ -> "https://auth.tesla.cn"
        _qts -> nil
      end

    case post("#{base_url}/oauth2/v3/token", data) do
      {:ok,
       %Tesla.Env{
         status: 200,
         body: %{"access_token" => access_token, "refresh_token" => refresh_token}
       }} ->
        {:ok, %{access_token: access_token, refresh_token: refresh_token}}

      error ->
        error
    end
  end

  def login(email, password) do
    state = random_string(15)
    code_verifier = random_code_verifier()

    params = [
      client_id: @web_client_id,
      redirect_uri: @redirect_uri,
      response_type: "code",
      scope: "openid email offline_access",
      code_challenge: challenge(code_verifier),
      code_challenge_method: "S256",
      state: state,
      login_hint: email
    ]

    with {:ok, {form, captcha, cookies, base_url}} <- load_form(params) do
      callback = fn captcha_code ->
        try do
          form =
            form
            |> Map.replace!("identity", email)
            |> Map.replace!("credential", password)

          form =
            if captcha == nil or captcha_code == nil do
              form
            else
              Map.replace!(form, "captcha", captcha_code)
            end

          with {:ok, %Tesla.Env{} = env} <-
                 submit_form(form, cookies, state, code_verifier, base: base_url),
               {:ok, {redirect_uri, code}} <- parse_location_header(env, state),
               {:ok, tokens} <-
                 get_web_token(code, code_verifier, redirect_uri, state, base: base_url),
               {:ok, auth} <- get_api_tokens(tokens) do
            {:ok, auth}
          end
        rescue
          e ->
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            {:error, %Error{reason: e, message: "An unexpected error occurred"}}
        end
      end

      case captcha do
        nil ->
          callback.(:no_captcha)

        captcha ->
          {:ok, {:captcha, captcha, callback}}
      end
    end
  end

  defp load_form(params, cookies \\ nil) do
    headers =
      case cookies do
        nil -> []
        cookies -> [{"Cookie", cookies}]
      end

    case get("/oauth2/v3/authorize", query: params, headers: headers) do
      {:ok, %Tesla.Env{status: 200, headers: resp_headers, body: resp_body} = env} ->
        document = Floki.parse_document!(resp_body)

        cookies =
          resp_headers
          |> Enum.filter(&match?({"set-cookie", _}, &1))
          |> Enum.map(fn {_, cookie} -> cookie |> String.split(";") |> hd() end)
          |> Enum.join("; ")

        base_url =
          URI.parse(env.url)
          |> Map.put(:path, nil)
          |> Map.put(:query, nil)
          |> URI.to_string()

        form =
          document
          |> Floki.find("form input")
          |> Map.new(fn input ->
            [key] = input |> Floki.attribute("name")
            value = input |> Floki.attribute("value") |> List.first()
            {key, value}
          end)

        case Floki.find(document, "[data-id=\"captcha\"]") do
          [] ->
            {:ok, {form, nil, cookies, base_url}}

          [captcha] ->
            [path] = Floki.attribute(captcha, "src")

            with {:ok, captcha} <- load_captcha_image(path, cookies) do
              {:ok, {form, captcha, cookies, base_url}}
            end
        end

      error ->
        handle_error(error, :authorization_request_failed)
    end
  end

  defp load_captcha_image(path, cookies) do
    case get(path, headers: [{"Cookie", cookies}]) do
      {:ok, %Tesla.Env{status: 200, body: captcha}} ->
        case Floki.parse_fragment(captcha) do
          {:ok, [{"svg", _, _}]} ->
            {:ok, captcha}

          {:error, reason} ->
            Logger.error("Invalid captcha: #{reason}")
            {:error, %Error{reason: :invalid_captcha}}
        end

      error ->
        handle_error(error, :captcha_could_not_be_loaded)
    end
  end

  defp submit_form(form, cookies, state, code_verifier, opts) do
    transaction_id = Map.fetch!(form, "transaction_id")
    encoded_form = URI.encode_query(form)

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Cookie", cookies}
    ]

    case post("#{opts[:base]}/oauth2/v3/authorize", encoded_form, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: body} = env} ->
        cond do
          String.contains?(body, "Captcha does not match") ->
            {:error, %Error{reason: :captcha_does_not_match, env: env}}

          String.contains?(body, "Your account has been locked") ->
            {:error, %Error{reason: :account_locked, env: env}}

          String.contains?(body, "/oauth2/v3/authorize/mfa/verify") ->
            headers = [{"referer", env.url}, {"cookie", cookies}]

            with {:ok, devices} <- list_devices(transaction_id, headers) do
              callback = fn device_id, mfa_passcode ->
                try do
                  with {:ok, env} <-
                         verify_passcode(device_id, mfa_passcode, transaction_id, headers),
                       {:ok, {redirect_uri, code}} <- parse_location_header(env, state),
                       {:ok, tokens} <-
                         get_web_token(code, code_verifier, redirect_uri, state),
                       {:ok, auth} <- get_api_tokens(tokens) do
                    {:ok, auth}
                  end
                rescue
                  e ->
                    Logger.error(Exception.format(:error, e, __STACKTRACE__))
                    {:error, %Error{reason: e, message: "An unexpected error occurred"}}
                end
              end

              {:ok, {:mfa, devices, callback}}
            end

          true ->
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

  defp verify_passcode(device_id, mfa_passcode, transaction_id, headers) do
    params = [transaction_id: transaction_id]

    data = %{
      transaction_id: transaction_id,
      factor_id: device_id,
      passcode: mfa_passcode
    }

    case post("/oauth2/v3/authorize/mfa/verify", data, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: body} = env} ->
        case body do
          %{"data" => %{"approved" => true, "valid" => true}} ->
            case get("/oauth2/v3/authorize", query: params, headers: headers) do
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

  defp get_web_token(code, code_verifier, redirect_uri, state, opts \\ []) do
    data = %{
      grant_type: "authorization_code",
      client_id: @web_client_id,
      code: code,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri
    }

    case post("#{opts[:base]}/oauth2/v3/token", data) do
      {:ok,
       %Tesla.Env{
         status: 200,
         body: %{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "state" => ^state
         }
       }} ->
        {:ok, %{access_token: access_token, refresh_token: refresh_token}}

      error ->
        handle_error(error, :web_token_error)
    end
  end

  defp get_api_tokens(%{access_token: access_token, refresh_token: refresh_token}) do
    data = %{
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      client_id: @client_id,
      client_secret: @client_secret
    }

    headers = [{"Authorization", "Bearer #{access_token}"}]

    case post("https://owner-api.teslamotors.com/oauth/token", data, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        auth = %__MODULE__{
          token: body["access_token"],
          type: body["token_type"],
          expires_in: body["expires_in"],
          refresh_token: refresh_token,
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

  defp log_level(%Tesla.Env{} = env) when env.status >= 400, do: :error
  defp log_level(%Tesla.Env{}), do: :info
end
