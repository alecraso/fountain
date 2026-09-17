defmodule FountainWeb.HelpLive.Show do
  @moduledoc """
  In-app docs. Each topic is a markdown file under `priv/help/<slug>.md`,
  rendered via `Managoat.Docs.Markdown` (MDEx). Default topic is `quickstart`. The `/api/docs`
  Swagger UI is linked out separately as the API reference.

  Topic order + display names are hard-coded here so the nav stays
  curated rather than just listing whatever happens to be in the
  directory.
  """

  use FountainWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :topics, Fountain.Help.topics())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    slug = params["topic"] || "quickstart"
    topic = Enum.find(Fountain.Help.topics(), fn {s, _} -> s == slug end)

    case topic do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "No such help topic: #{slug}")
         |> push_navigate(to: ~p"/help")}

      {slug, title} ->
        body = load_topic(slug)

        {:noreply,
         socket
         |> assign(:slug, slug)
         |> assign(:title, title)
         |> assign(:body_html, render_markdown(body))
         |> assign(:page_title, "Help · " <> title)}
    end
  end

  # sobelow_skip ["Traversal.FileModule"] — slug is allowlisted against
  # Fountain.Help.topics() in handle_params before this is called.
  defp load_topic(slug) do
    path = Path.join([:code.priv_dir(:fountain) |> to_string(), "help", slug <> ".md"])

    case File.read(path) do
      {:ok, body} -> body
      {:error, _} -> "# Topic not found\n\nNo content at `#{path}`."
    end
  end

  # Help topics are repo-controlled markdown (the trusted corpus), so they
  # render through the trusted path — same scrubbing as agent output (#323),
  # plus a sanitized <svg>/<figure> subset so authored diagrams draw.
  defp render_markdown(text), do: Managoat.Docs.Markdown.to_trusted_html(text)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6">
      <aside class="w-48 shrink-0">
        <div class="text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium mb-2 px-2">
          Help topics
        </div>
        <nav class="space-y-1">
          <%= for {slug, title} <- @topics do %>
            <.link
              navigate={~p"/help/#{slug}"}
              class={[
                "block rounded px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]",
                @slug == slug && "bg-[var(--color-bg-2)] font-medium",
                @slug != slug && "text-[var(--color-text-secondary)]"
              ]}
            >
              {title}
            </.link>
          <% end %>
          <a
            href="/docs"
            target="_blank"
            class="block rounded px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)] text-[var(--color-text-secondary)]"
          >
            Full documentation ↗
          </a>
          <a
            href="/api/docs"
            target="_blank"
            class="block rounded px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)] text-[var(--color-text-secondary)]"
          >
            API reference (Swagger) ↗
          </a>
          <a
            href="/llms.txt"
            target="_blank"
            class="block rounded px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)] text-[var(--color-text-secondary)]"
          >
            For LLMs (/llms.txt) ↗
          </a>
        </nav>
      </aside>

      <article class="flex-1 max-w-3xl bg-[var(--color-bg-1)] border border-[var(--color-border)] rounded-lg shadow-sm p-8">
        <%!-- Same class set as /docs (docs_html/show.html.heex), including the
        `dark:` variants the Typography plugin needs — see the comment there
        for why the `[&_pre_code]:` resets are needed. --%>
        <div class={[
          "prose prose-zinc dark:prose-invert max-w-none",
          "prose-headings:font-semibold prose-headings:tracking-tight",
          "prose-a:text-blue-600 dark:prose-a:text-indigo-400",
          "prose-pre:bg-[var(--color-code-bg)] prose-pre:text-[var(--color-code-text)] prose-pre:text-xs",
          "prose-code:text-zinc-800 prose-code:bg-zinc-100 dark:prose-code:text-zinc-200 dark:prose-code:bg-zinc-800",
          "prose-code:px-1 prose-code:py-0.5 prose-code:rounded prose-code:font-normal",
          "prose-code:before:content-none prose-code:after:content-none",
          "[&_pre_code]:bg-transparent [&_pre_code]:text-inherit [&_pre_code]:p-0 [&_pre_code]:rounded-none",
          "prose-blockquote:not-italic prose-blockquote:font-normal",
          "[&_blockquote_p]:before:content-none [&_blockquote_p]:after:content-none"
        ]}>
          {Phoenix.HTML.raw(@body_html)}
        </div>
      </article>
    </div>
    """
  end
end
