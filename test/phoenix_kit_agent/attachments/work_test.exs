defmodule PhoenixKitAgent.Attachments.WorkTest do
  @moduledoc """
  The scratch space of attachment processing: private, never reused, removed by
  whoever made it, and swept when something left it behind.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitAgent.Attachments.Work

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "a directory is private, new each time, and gone after with_dir" do
    {:ok, a} = Work.create()
    {:ok, b} = Work.create()
    on_exit(fn -> Work.remove(a) && Work.remove(b) end)

    assert a != b
    assert Path.dirname(a) == Work.root()
    assert mode(a) == 0o700
    assert mode(Work.root()) == 0o700

    seen = Work.with_dir(fn dir -> {dir, File.dir?(dir)} end)
    assert {dir, true} = seen
    refute File.exists?(dir)
  end

  test "a directory is removed with what is in it, also when the work raised" do
    dir =
      try do
        Work.with_dir(fn dir ->
          File.write!(Path.join(dir, "original.pdf"), "x")
          send(self(), {:dir, dir})
          raise "boom"
        end)
      rescue
        RuntimeError ->
          assert_received {:dir, dir}
          dir
      end

    refute File.exists?(dir)
  end

  test "a process that adopted a directory makes its own inside it, and they go with it" do
    {:ok, job} = Work.create()

    task =
      Task.async(fn ->
        Work.adopt(job)
        {:ok, inner} = Work.create()
        File.write!(Path.join(inner, "page-1.png"), "x")
        inner
      end)

    inner = Task.await(task)
    assert Path.dirname(inner) == job
    assert mode(inner) == 0o700

    Work.remove(job)
    refute File.exists?(inner)
  end

  test "what a killed worker left behind is swept once it is older than a job may take" do
    {:ok, old} = Work.create()
    {:ok, fresh} = Work.create()
    File.write!(Path.join(old, "original.pdf"), "a user's file")
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    on_exit(fn -> Work.remove(fresh) end)

    assert Work.sweep() >= 1

    refute File.exists?(old)
    assert File.dir?(fresh)
  end
end
