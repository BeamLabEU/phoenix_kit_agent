defmodule PhoenixKitAgent.TranslationsTest do
  @moduledoc """
  The catalogues of `priv/gettext`: every message of the template is
  translated in every language of the set (et, ru, uk, fr, de) and in `en`,
  with the placeholders of the source text and the plural forms of the language.
  """

  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.Messages
  alias Expo.PO
  alias PhoenixKitAgent.Web.Dock.Texts

  @root Path.expand("../../priv/gettext", __DIR__)
  @languages ~w(en et ru uk fr de)
  @plurals %{"en" => 2, "et" => 2, "ru" => 3, "uk" => 3, "fr" => 2, "de" => 2}

  defp parse!(path) do
    {:ok, %Messages{messages: messages}} = PO.parse_file(path)
    Enum.reject(messages, &(Message.key(&1) == {"", nil} or &1.msgid == [""]))
  end

  defp template, do: parse!(Path.join(@root, "default.pot"))
  defp catalogue(language), do: parse!(Path.join([@root, language, "LC_MESSAGES", "default.po"]))

  defp text(parts), do: IO.iodata_to_binary(parts)

  defp placeholders(string),
    do:
      ~r/%\{(\w+)\}/
      |> Regex.scan(string, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()
      |> Enum.uniq()

  test "the set of languages is exactly the one of the catalogue module" do
    dirs = @root |> File.ls!() |> Enum.reject(&String.ends_with?(&1, ".pot")) |> Enum.sort()
    assert dirs == Enum.sort(@languages)
  end

  test "the template has messages" do
    assert length(template()) > 150
  end

  for language <- @languages do
    describe "#{language}" do
      test "has every message of the template, translated" do
        translated = Map.new(catalogue(unquote(language)), &{text(&1.msgid), &1})
        template_ids = template() |> Enum.map(&text(&1.msgid)) |> MapSet.new()

        assert MapSet.new(Map.keys(translated)) == template_ids

        for %Message.Singular{msgid: id} <- template() do
          msgstr = translated |> Map.fetch!(text(id)) |> Map.fetch!(:msgstr) |> text()
          assert msgstr != "", "#{unquote(language)}: empty translation of #{inspect(text(id))}"
        end
      end

      test "keeps the placeholders of the source text, and the plural forms of the language" do
        for message <- catalogue(unquote(language)) do
          id = text(message.msgid)

          case message do
            %Message.Singular{msgstr: msgstr} ->
              assert placeholders(text(msgstr)) == placeholders(id),
                     "#{unquote(language)}: placeholders of #{inspect(id)}"

            %Message.Plural{msgstr: forms} ->
              allowed = placeholders(id) ++ placeholders(text(message.msgid_plural))
              assert map_size(forms) == @plurals[unquote(language)]

              for {n, form} <- forms do
                assert text(form) != "", "#{unquote(language)}: empty form #{n} of #{inspect(id)}"
                assert placeholders(text(form)) -- allowed == []
              end
          end
        end
      end
    end
  end

  test "the texts of the refusals and notices come out in the language of the panel" do
    texts = fn locale ->
      Gettext.with_locale(PhoenixKitAgent.Gettext, locale, fn ->
        {Texts.refusal(:empty_message), Texts.notice("deadline")}
      end)
    end

    assert {"Write a message first.", _} = texts.("en")
    assert {"Kirjuta esmalt sõnum.", _} = texts.("et")
    assert {"Сначала напишите сообщение.", _} = texts.("ru")
    assert {"Спочатку напишіть повідомлення.", _} = texts.("uk")
    assert {"Écrivez d'abord un message.", _} = texts.("fr")
    assert {"Schreiben Sie zuerst eine Nachricht.", _} = texts.("de")
  end

  test "the labels of the permission and of the tabs are in the catalogues" do
    meta = PhoenixKitAgent.permission_metadata()

    labels = [
      meta.label,
      meta.description | Enum.flat_map(meta.sub_permissions, &[&1.label, &1.description])
    ]

    tabs = PhoenixKitAgent.admin_tabs() ++ PhoenixKitAgent.settings_tabs()
    ids = template() |> Enum.map(&text(&1.msgid)) |> MapSet.new()

    for label <- labels ++ Enum.map(tabs, & &1.label) do
      assert label in ids, "no message for #{inspect(label)}"
    end

    et =
      Gettext.with_locale(PhoenixKitAgent.Gettext, "et", fn ->
        Gettext.dgettext(PhoenixKitAgent.Gettext, "default", "Spending")
      end)

    assert et == "Kulu"
  end
end
