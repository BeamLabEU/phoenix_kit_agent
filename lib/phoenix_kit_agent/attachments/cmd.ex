defmodule PhoenixKitAgent.Attachments.Cmd do
  @moduledoc """
  Runs the external programs of attachment processing (`pdfinfo`, `pdftotext`,
  `pdftoppm` — poppler) with a time limit, and says plainly when one is not
  installed. What a program prints is never returned or logged on failure: it
  can quote the file.
  """

  alias PhoenixKitAgent.Attachments.Bounds

  @typedoc "Why a program did not give its result."
  @type failure :: :tool_missing | :timeout | :failed

  @doc "Whether the program is installed."
  @spec available?(String.t()) :: boolean()
  def available?(tool), do: System.find_executable(tool) != nil

  @doc """
  Runs `tool` with `args`. `{:ok, output}` (stdout and stderr) when it exits
  with 0.
  """
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, failure()}
  def run(tool, args) do
    case System.find_executable(tool) do
      nil -> {:error, :tool_missing}
      executable -> execute(executable, args)
    end
  end

  # `timeout` (coreutils) kills the program itself; the BEAM would otherwise
  # leave an OS process running after its task is gone.
  defp execute(executable, args) do
    {command, arguments} =
      case System.find_executable("timeout") do
        nil ->
          {executable, args}

        timeout ->
          {timeout,
           ["-k", "5", Integer.to_string(Bounds.get(:tool_timeout_s)), executable | args]}
      end

    case System.cmd(command, arguments, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 124} -> {:error, :timeout}
      {_output, _status} -> {:error, :failed}
    end
  rescue
    _ -> {:error, :failed}
  end
end
