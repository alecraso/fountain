# async: false — these mutate the global :registration_enabled / :marketing_site
# app env, which config/test.exs pins for the whole suite.
defmodule FountainWeb.FrontDoorTest do
  use FountainWeb.ConnCase, async: false

  setup do
    marketing = Application.get_env(:fountain, :marketing_site)
    registration = Application.get_env(:fountain, :registration_enabled)

    on_exit(fn ->
      Application.put_env(:fountain, :marketing_site, marketing)
      Application.put_env(:fountain, :registration_enabled, registration)
    end)

    :ok
  end

  describe "GET /" do
    test "serves a plain front door and none of the pitch", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "This instance runs agents on sandboxes"
      assert body =~ ~p"/auth/login"
      assert body =~ "/docs"

      # The pitch left with the marketing pages (managoat/site). Whatever the
      # flag says, the app has no copy of it to serve.
      for site? <- [true, false] do
        Application.put_env(:fountain, :marketing_site, site?)
        body = conn |> get(~p"/") |> html_response(200)
        refute body =~ "You did not set out to run a sandbox platform."
        refute body =~ "Give your product a coding agent."
        assert body =~ "<title>#{Fountain.Brand.name()}</title>"
        refute body =~ "Claude Code, Codex and Gemini CLI behind one API"
      end
    end

    test "the card says what the instance is, not the pitch, off the marketing site", %{
      conn: conn
    } do
      Application.put_env(:fountain, :marketing_site, false)
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~
               ~s(<meta property="og:description" content="Fountain runs agents on sandboxes)

      assert body =~ ~s(<meta property="og:image:alt" content="Fountain")
    end

    # The footer groups its links now. A deployment the marketing site does not
    # front has nothing to put under Product, so the whole group goes rather
    # than leaving a heading over an empty column.
    test "keeps only the footer groups it can fill off the marketing site", %{conn: conn} do
      Application.put_env(:fountain, :marketing_site, false)
      body = conn |> get(~p"/") |> html_response(200)

      refute body =~ ~s(data-role="footer-product")
      assert body =~ ~s(data-role="footer-learn")
      assert body =~ ~s(data-role="footer-account")

      for path <- ~w(/integrations /built-with /self-hosted /faq /case-studies) do
        refute body =~ ~s(href="#{path}), "#{path} is linked on a deployment nothing serves it"
      end
    end

    test "links the marketing site's pages where it fronts the deployment", %{conn: conn} do
      # On the hosted deployment the ingress sends these paths to the static
      # site, so the manual's chrome may link them; the app never serves them.
      Application.put_env(:fountain, :marketing_site, true)
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ ~s(data-role="footer-product")

      for path <-
            ~w(/integrations /built-with /self-hosted /faq /case-studies/self-healing-infrastructure) do
        assert body =~ ~s(href="#{path}"), "#{path} is not linked"
      end

      # The app has no route for any of them: the site answers on the hosted

      # host, and everywhere else they are simply gone (they used to redirect

      # into the manual).

      for path <-
            ~w(/integrations /built-with /self-hosted /faq /launch /oss-launch /buzz-launch /code-review-bot /case-studies /case-studies/self-healing-infrastructure) do
        assert conn |> get(path) |> response(404), "#{path} is still served"
      end
    end

    test "offers registration while registration is open", %{conn: conn} do
      Application.put_env(:fountain, :registration_enabled, true)

      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/auth/register"
      assert body =~ "Create an account"
    end

    test "drops every registration link once registration is closed", %{conn: conn} do
      Application.put_env(:fountain, :registration_enabled, false)

      # Not only the page's own CTA: the shared public layout's nav and footer
      # link it too, and a link to a door the context refuses is worse than no
      # link.
      refute conn |> get(~p"/") |> html_response(200) =~ ~p"/auth/register"
    end

    test "points a signed-in visitor at the console", %{conn: conn} do
      user = insert_verified_user()

      body = conn |> login_user(user) |> get(~p"/") |> html_response(200)
      assert body =~ "Open the console"
      assert body =~ ~p"/dashboard"
      refute body =~ ~p"/auth/register"
    end
  end
end
