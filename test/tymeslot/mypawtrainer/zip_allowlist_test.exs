defmodule Tymeslot.MyPawTrainer.ZipAllowlistTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MyPawTrainer.ZipAllowlist
  alias Tymeslot.MyPawTrainer.ZipAllowlistAuditSchema
  alias Tymeslot.Repo

  setup do
    owner = insert(:user)
    other = insert(:user)
    %{owner: owner, other: other}
  end

  test "eligible? is true only for an active five-digit ZIP on that owner", %{owner: owner} do
    refute ZipAllowlist.eligible?(owner.id, "32084")

    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    assert ZipAllowlist.eligible?(owner.id, "32084")
    assert ZipAllowlist.eligible?(owner.id, " 32084 ")
    refute ZipAllowlist.eligible?(owner.id, "32085")
  end

  test "eligible? rejects malformed and inactive ZIPs", %{owner: owner} do
    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    refute ZipAllowlist.eligible?(owner.id, "3208")
    refute ZipAllowlist.eligible?(owner.id, "320840")
    refute ZipAllowlist.eligible?(owner.id, "32084-1234")
    refute ZipAllowlist.eligible?(owner.id, "abcde")
    refute ZipAllowlist.eligible?(owner.id, "")
    refute ZipAllowlist.eligible?(owner.id, nil)

    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: false, actor_id: owner.id)

    refute ZipAllowlist.eligible?(owner.id, "32084")
  end

  test "set_active records owner, action, ZIP, prior state, new state, and timestamp", %{
    owner: owner
  } do
    assert {:ok, added} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    assert added.owner_user_id == owner.id
    assert added.zip_code == "32084"
    assert added.active

    [add_audit] = Repo.all(from(a in ZipAllowlistAuditSchema, order_by: [asc: a.id]))
    assert add_audit.owner_user_id == owner.id
    assert add_audit.zip_code == "32084"
    assert add_audit.action == "add"
    assert add_audit.previous_active == nil
    assert add_audit.new_active == true
    assert add_audit.actor_user_id == owner.id
    assert %DateTime{} = add_audit.inserted_at

    assert {:ok, deactivated} =
             ZipAllowlist.set_active(owner.id, "32084", active: false, actor_id: owner.id)

    refute deactivated.active

    [_add, deactivate_audit] = Repo.all(from(a in ZipAllowlistAuditSchema, order_by: [asc: a.id]))
    assert deactivate_audit.action == "deactivate"
    assert deactivate_audit.previous_active == true
    assert deactivate_audit.new_active == false
    assert deactivate_audit.actor_user_id == owner.id

    assert {:ok, reactivated} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    assert reactivated.active

    [_add, _deactivate, reactivate_audit] =
      Repo.all(from(a in ZipAllowlistAuditSchema, order_by: [asc: a.id]))

    assert reactivate_audit.action == "reactivate"
    assert reactivate_audit.previous_active == false
    assert reactivate_audit.new_active == true
  end

  test "a ZIP change does not cancel existing meetings", %{owner: owner} do
    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    meeting =
      insert(:meeting,
        organizer_user: owner,
        organizer_user_id: owner.id,
        status: "confirmed",
        cancelled_at: nil
      )

    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: false, actor_id: owner.id)

    reloaded = Repo.get!(MeetingSchema, meeting.id)
    assert reloaded.status == "confirmed"
    assert is_nil(reloaded.cancelled_at)
  end

  test "a foreign owner cannot change another owner's allowlist", %{owner: owner, other: other} do
    assert {:error, :unauthorized} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: other.id)

    refute ZipAllowlist.eligible?(owner.id, "32084")
    assert Repo.all(ZipAllowlistAuditSchema) == []
  end

  test "authorize_schedule never consults the allowlist for discovery or online", %{owner: owner} do
    discovery = %{service_id: "discovery-call", user_id: owner.id}
    online = %{service_id: "online-consultation", user_id: owner.id}

    assert :ok = ZipAllowlist.authorize_schedule(discovery, nil)
    assert :ok = ZipAllowlist.authorize_schedule(online, "99999")
    assert :ok = ZipAllowlist.authorize_schedule(online, nil)
  end

  test "authorize_schedule requires an active ZIP only for in-home", %{owner: owner} do
    in_home = %{service_id: "in-home-consultation", user_id: owner.id}

    assert {:error, :service_area_unavailable} = ZipAllowlist.authorize_schedule(in_home, nil)
    assert {:error, :service_area_unavailable} = ZipAllowlist.authorize_schedule(in_home, "3208")
    assert {:error, :service_area_unavailable} = ZipAllowlist.authorize_schedule(in_home, "32084")

    assert {:ok, _row} =
             ZipAllowlist.set_active(owner.id, "32084", active: true, actor_id: owner.id)

    assert :ok = ZipAllowlist.authorize_schedule(in_home, "32084")
    assert :ok = ZipAllowlist.authorize_schedule(in_home, " 32084 ")
  end

  test "set_active rejects malformed ZIPs without writing", %{owner: owner} do
    assert {:error, :invalid_zip} =
             ZipAllowlist.set_active(owner.id, "3208", active: true, actor_id: owner.id)

    assert {:error, :invalid_zip} =
             ZipAllowlist.set_active(owner.id, "32084-1234", active: true, actor_id: owner.id)

    assert Repo.all(ZipAllowlistAuditSchema) == []
  end
end
