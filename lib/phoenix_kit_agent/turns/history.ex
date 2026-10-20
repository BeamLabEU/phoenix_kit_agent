defmodule PhoenixKitAgent.Turns.History do
  @moduledoc """
  What a turn shows the model of the chat so far (spec §6.6): the `user`
  messages and the final `assistant` answers of earlier turns, newest kept
  first, up to `agent_history_chars`. Tool calls and tool results of earlier
  turns are left out — after a loss of rights the model must not see old
  data — and so are notices. The extracted text of a message's attachments
  (the user's own files) is part of that message.
  """

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
    |> Enum.flat_map(&entry(&1, Map.get(texts, &1.uuid, [])))
    |> Enum.reverse()
    |> Enum.reduce_while({[], String.length(current.content)}, fn entry, {kept, used} ->
      used = used + String.length(entry.content)
      if used <= limit, do: {:cont, {[entry | kept], used}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Kernel.++([current])
  end

  @doc "The content of a user message: its text, then the text of each attachment."
  @spec user_content(String.t(), [Attachment.t()]) :: String.t()
  def user_content(text, attachments) do
    attachments
    |> Enum.filter(&is_binary(&1.extracted_text))
    |> Enum.reduce(text, fn attachment, acc ->
      acc <> "\n\n[Attachment: " <> attachment.filename <> "]\n" <> attachment.extracted_text
    end)
  end

  defp entry(%Message{role: "user", content: content}, attachments) when is_binary(content),
    do: [%{role: "user", content: user_content(content, attachments)}]

  defp entry(%Message{role: "assistant", content: content, tool_calls: calls}, _attachments)
       when is_binary(content) and calls in [nil, []] do
    if String.trim(content) == "", do: [], else: [%{role: "assistant", content: content}]
  end

  defp entry(_tool_call_tool_result_or_notice, _attachments), do: []
end
