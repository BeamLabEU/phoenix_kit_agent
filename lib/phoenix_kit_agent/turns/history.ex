defmodule PhoenixKitAgent.Turns.History do
  @moduledoc """
  What a turn shows the model of the chat so far (spec §6.6): the `user`
  messages and the final `assistant` answers of earlier turns, newest kept
  first, up to `agent_history_chars`. Tool calls and tool results of earlier
  turns are left out — after a loss of rights the model must not see old
  data — and so are notices. The extracted text of a message's attachments
  (the user's own files) is part of that message; the attachments of one
  message share `limit` between them, so that five files cannot by themselves
  outgrow the window and push the earlier conversation out of it. A text that
  holds less than its file ends with a line that says so
  (`PhoenixKitAgent.Attachments.Extract`), and so does one cut to its share
  here: the model is not left to take part of the data for all of it.
  """

  alias PhoenixKitAgent.Attachments
  alias PhoenixKitAgent.Attachments.{Bounds, Extract}
  alias PhoenixKitAgent.Schemas.{Attachment, Message}

  @typedoc "A message as the model reads it."
  @type entry :: %{role: String.t(), content: String.t()}

  @doc """
  The model messages for a turn: the earlier `messages` of the chat (oldest
  first) and then `current`, the new user message, which is always kept. The
  earlier ones are kept from the newest back while the characters of all kept
  messages stay within `limit`; the first that does not fit ends the window.
  `attachments` are the chat's ready attachments.
  """
  @spec build([Message.t()], [Attachment.t()], entry(), pos_integer()) :: [entry()]
  def build(messages, attachments, current, limit) do
    texts = Enum.group_by(attachments, & &1.message_uuid)

    messages
    |> Enum.flat_map(&entry(&1, Map.get(texts, &1.uuid, []), limit))
    |> Enum.reverse()
    |> Enum.reduce_while({[], String.length(current.content)}, fn entry, {kept, used} ->
      used = used + String.length(entry.content)
      if used <= limit, do: {:cont, {[entry | kept], used}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Kernel.++([current])
  end

  @doc """
  The content of a user message: its text, then each attachment — the text it
  carries (cut to its share of `limit`), or, for a picture the model is shown
  as pixels, a line that names it (the pixels themselves go with the message of
  their own turn only).
  """
  @spec user_content(String.t(), [Attachment.t()], pos_integer()) :: String.t()
  def user_content(text, attachments, limit) do
    share = div(limit, max(Enum.count(attachments, &is_binary(&1.extracted_text)), 1))

    Enum.reduce(attachments, text, fn attachment, acc ->
      acc <> attachment_block(attachment, share)
    end)
  end

  defp attachment_block(%{extracted_text: text, filename: filename} = attachment, share)
       when is_binary(text) do
    shown =
      cond do
        String.length(text) > share ->
          String.slice(text, 0, share) <>
            Extract.continues("the file continues: the rest of it is not shown here")

        # A text that is short of its file and does not say so itself.
        attachment.truncated and not Extract.says_continued?(text) ->
          text <> Extract.continues("the file continues: not all of it is shown")

        true ->
          text
      end

    "\n\n[Attachment: " <> filename <> "]\n" <> shown
  end

  defp attachment_block(%{filename: filename} = attachment, _share) do
    if Attachments.pixels?(attachment),
      do: "\n\n[Attachment: " <> filename <> " - " <> pixels_line(attachment) <> "]",
      else: ""
  end

  defp pixels_line(%{kind: "pdf", pages: pages}) when is_integer(pages) do
    "a scanned document of #{Extract.count(pages, "page")}; its first #{min(pages, Bounds.get(:scan_pages))} " <>
      "are shown to you as pictures only along with the message it was sent with"
  end

  defp pixels_line(_picture),
    do: "a picture, shown to you only along with the message it was sent with"

  defp entry(%Message{role: "user", content: content}, attachments, limit)
       when is_binary(content),
       do: [%{role: "user", content: user_content(content, attachments, limit)}]

  defp entry(
         %Message{role: "assistant", content: content, tool_calls: calls},
         _attachments,
         _limit
       )
       when is_binary(content) and calls in [nil, []] do
    if String.trim(content) == "", do: [], else: [%{role: "assistant", content: content}]
  end

  defp entry(_tool_call_tool_result_or_notice, _attachments, _limit), do: []
end
