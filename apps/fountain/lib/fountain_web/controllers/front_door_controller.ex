defmodule FountainWeb.FrontDoorController do
  @moduledoc """
  The public pages the app serves itself: `/`, `/terms` and `/privacy`.

  `/` is a plain front door: what this instance is, the way in, and a link
  to the manual. No pitch, no price, no trial. The hosted deployment's
  marketing pages live in [managoat/site](https://github.com/managoat/site)
  and sit in front of this route at the ingress, so a reader of managoat.com
  never reaches it; every other deployment of Fountain is not the project and
  gets no copy that claims otherwise (`Fountain.Marketing`).

  The legal pages render the operator's identity, or nothing at all
  (`Fountain.Legal`).
  """
  use FountainWeb, :controller

  def home(conn, _params) do
    render(conn, :instance, layout: {FountainWeb.Layouts, :public})
  end

  def terms(conn, _params) do
    render_legal(conn, :terms)
  end

  def privacy(conn, _params) do
    render_legal(conn, :privacy)
  end

  # The legal identity is the operator's, set via LEGAL_* env vars (#517) —
  # see Fountain.Legal for the unconfigured behaviour (neutral 404 on a
  # billing-disabled instance, loud placeholders on a billing-enabled one).
  defp render_legal(conn, page) do
    case Fountain.Legal.content() do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:legal_unpublished, layout: {FountainWeb.Layouts, :public})

      legal ->
        render(conn, page, layout: {FountainWeb.Layouts, :public}, legal: legal)
    end
  end
end
