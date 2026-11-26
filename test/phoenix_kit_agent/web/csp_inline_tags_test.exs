defmodule PhoenixKitAgent.Web.CSPInlineTagsTest do
  @moduledoc """
  The module's markup works under a nonce Content-Security-Policy
  (`script-src 'self' 'nonce-…'`, see core's `guides/content-security-policy.md`):
  no inline event handler (no nonce covers an attribute), and no inline
  `<script>` / `<style>` without the host's nonce. Modelled on core's
  `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces
  # around `=` for the events a browser knows (a bare `on\w+ =` would also
  # match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          # A colocated hook without `runtime` is taken out of the template at
          # compile time; nothing is rendered inline. A `runtime` one is an
          # inline script and needs the nonce.
          not (opening =~ "Phoenix.LiveView.ColocatedHook" and not (opening =~ "runtime")),
          not (opening =~ "CSP.nonce(" or opening =~ "CSP.attr("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitAgent.Web.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the five runtime hooks of the chat panel are seen by the scan, with the nonce" do
    openings =
      "lib/phoenix_kit_agent/web/dock/panel.ex"
      |> tag_openings()
      |> Enum.filter(fn {opening, _} -> opening =~ "runtime" end)

    assert length(openings) == 5

    for {opening, _} <- openings,
        do: assert(opening =~ "nonce={PhoenixKitAgent.Web.CSP.nonce(:script)}")
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          handler?(line) or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, " <>
             "`Phoenix.LiveView.JS` or a hook):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern sees what it must and leaves Elixir alone" do
    for bad <- [
          ~s|<img onerror="this.remove()" />|,
          ~s|<input onfocus={@js} />|,
          ~s|<a onclick = 'go()'>|
        ],
        do: assert(handler?(bad))

    for fine <- [
          ~s|only = "x"|,
          ~s|<div phx-click="go" data-role="open">|,
          ~s|on_mount = {A, :b}|,
          ~s|<.item_table only={@only} />|
        ],
        do: refute(handler?(fine))

    assert ~s|<a href="javascript:void(0)">| =~ @js_url
  end

  # Component attributes that start with "on" and are no event: `only={…}`.
  @not_events ~r/\sonly=/

  defp handler?(line), do: String.replace(line, @not_events, " ") =~ @handler

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept:
  # documentation, HEEx comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in
  # documentation is an example, not markup.
  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
