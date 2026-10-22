defmodule PhoenixKitAgent.LibraryTest do
  @moduledoc """
  The module's hidden Storage library and the folder of each user in it.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, Libraries}
  alias PhoenixKitAgent.Library

  describe "ensure_library/0" do
    test "creates a hidden system library under the module's slug" do
      assert Libraries.get_hidden_library_by_slug(Library.slug()) == nil

      assert {:ok, library} = Library.ensure_library()

      assert library.slug == Library.slug()
      assert library.kind == "system"
      assert Libraries.hidden?(library)
      refute library.uuid in Enum.map(Libraries.list_system_libraries(), & &1.uuid)
    end

    test "returns the same library on every call" do
      {:ok, first} = Library.ensure_library()
      {:ok, second} = Library.ensure_library()

      assert first.uuid == second.uuid

      assert [_] =
               Repo.all(
                 from(l in Storage.Library, where: l.slug == ^Library.slug(), select: l.uuid)
               )
    end

    test "library/0 finds it without creating it" do
      assert Library.library() == nil
      {:ok, library} = Library.ensure_library()
      assert Library.library().uuid == library.uuid
    end
  end

  describe "ensure_user_folder/1" do
    test "makes one folder per user, named by the user's uuid, at the library root" do
      user = user_fixture()

      assert {:ok, %Folder{} = folder} = Library.ensure_user_folder(user.uuid)
      {:ok, library} = Library.ensure_library()

      assert folder.name == user.uuid
      assert folder.library_uuid == library.uuid
      assert folder.parent_uuid == nil
      assert folder.user_uuid == user.uuid

      assert {:ok, again} = Library.ensure_user_folder(user.uuid)
      assert again.uuid == folder.uuid
    end

    test "another user gets another folder" do
      {:ok, a} = Library.ensure_user_folder(user_fixture().uuid)
      {:ok, b} = Library.ensure_user_folder(user_fixture().uuid)

      refute a.uuid == b.uuid
    end

    test "user_folder/1 finds the folder without creating one" do
      user = user_fixture()

      assert Library.user_folder(user.uuid) == nil
      {:ok, folder} = Library.ensure_user_folder(user.uuid)
      assert Library.user_folder(user.uuid).uuid == folder.uuid
    end

    test "a folder of the same name in Media is not the user's folder" do
      user = user_fixture()
      {:ok, media_folder} = Storage.create_folder(%{name: user.uuid, user_uuid: user.uuid})

      {:ok, folder} = Library.ensure_user_folder(user.uuid)

      refute folder.uuid == media_folder.uuid
    end

    test "not a uuid is refused" do
      assert Library.ensure_user_folder("../etc") == {:error, :invalid_user_uuid}
      assert Library.user_folder("nope") == nil
    end
  end
end
