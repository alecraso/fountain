defmodule Fountain.Marketing do
  @moduledoc """
  Whether the project's marketing site fronts this deployment.

  The marketing pages are a static site of their own
  ([managoat/site](https://github.com/managoat/site)), served on the hosted
  deployment's host by the ingress: `/`, `/integrations`, `/self-hosted` and
  the rest reach nginx there and never this app. What the app still decides is
  whether its own public chrome should link to them. The manual's header and
  footer (`layouts/public.html.heex`) carry Integrations, Built with,
  Self-host, Questions and the repository when this is on, and the Open Graph
  card carries the pitch (`FountainWeb.OpenGraph`).

  Off unless `MARKETING_SITE=true` (config/runtime.exs), so a self-host is
  right by default: a link to a page nothing serves is a dead end, and nobody
  running Fountain for their own team is selling credit for it. The hosted
  deployment opts in — the same shape, for the same reason, as `CREDITS_ENABLED`
  (#336).

  Deliberately *not* `Fountain.Credits.enabled?/0`, the closest existing flag.
  Billing says "this instance charges money", which an operator running
  Fountain commercially inside their own company may well turn on. That must
  not hand their manual a nav full of somebody else's product pages.

  Until 2026-09 this flag also chose what `/` served and the app rendered the
  pitch itself; `available?/1` gated the copy on the installed extensions
  (#1525). Both left with the templates.
  """

  @doc "Whether the marketing site fronts this deployment, so the public chrome links to it."
  @spec site?() :: boolean()
  def site?, do: Application.get_env(:fountain, :marketing_site, false)
end
