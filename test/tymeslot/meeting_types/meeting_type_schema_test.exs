defmodule Tymeslot.MeetingTypes.MeetingTypeSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  describe "changeset/2 with custom_fields" do
    test "defaults to empty list" do
      cs =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          "name" => "30 min chat",
          "duration_minutes" => 30,
          "user_id" => 1
        })

      assert Changeset.get_field(cs, :custom_fields) == []
    end

    test "accepts an array of field definitions" do
      attrs = %{
        "name" => "30 min chat",
        "duration_minutes" => 30,
        "user_id" => 1,
        "custom_fields" => [
          %{"type" => "short_text", "label" => "Company"},
          %{"type" => "yes_no", "label" => "Bringing laptop?"}
        ]
      }

      cs = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      assert cs.valid?
      assert length(Changeset.get_field(cs, :custom_fields)) == 2
    end

    test "invalid field definitions surface errors" do
      attrs = %{
        "name" => "x",
        "duration_minutes" => 30,
        "user_id" => 1,
        "custom_fields" => [%{"type" => "rich_text", "label" => "Bad"}]
      }

      cs = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute cs.valid?

      # Error must originate from the embedded changeset, not the parent.
      [embed_cs] = Changeset.get_change(cs, :custom_fields)
      refute embed_cs.valid?
      assert "is invalid" in errors_on(embed_cs).type
    end
  end

  describe "business rules" do
    test "prevents meetings longer than 8 hours" do
      user = insert(:user)

      attrs = %{
        name: "All Day Meeting",
        duration_minutes: 481,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be less than or equal to 480" in errors_on(changeset).duration_minutes
    end

    test "prevents zero-duration meetings" do
      user = insert(:user)

      attrs = %{
        name: "No Time Meeting",
        duration_minutes: 0,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 1" in errors_on(changeset).duration_minutes
    end

    test "prevents duplicate meeting type names per user" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Daily Standup", allow_video: false)

      {:error, changeset} =
        %MeetingTypeSchema{}
        |> MeetingTypeSchema.changeset(%{
          name: "Daily Standup",
          duration_minutes: 30,
          user_id: user.id,
          allow_video: false
        })
        |> Repo.insert()

      assert "You already have a meeting type with this name" in errors_on(changeset).user_id
    end

    test "schema allows non-divisible-by-5 durations (form layer enforces this)" do
      user = insert(:user)

      attrs = %{
        name: "Odd Duration",
        duration_minutes: 7,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      assert changeset.valid?
    end

    test "prevents more than three reminders" do
      user = insert(:user)

      attrs = %{
        name: "Reminder Packed",
        duration_minutes: 30,
        user_id: user.id,
        reminder_config: [
          %{value: 15, unit: "minutes"},
          %{value: 30, unit: "minutes"},
          %{value: 1, unit: "hours"},
          %{value: 1, unit: "days"}
        ]
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute changeset.valid?
      assert "cannot have more than 3 reminders" in errors_on(changeset).reminder_config
    end
  end

  describe "payment_required validation" do
    test "free meeting type does not require price" do
      user = insert(:user)

      attrs = %{
        name: "Free Chat",
        duration_minutes: 30,
        payment_required: false,
        user_id: user.id
      }

      changeset = MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs)
      refute Map.has_key?(errors_on(changeset), :price_cents)
    end

    test "paid meeting type requires price_cents" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).price_cents
    end

    test "rejects price below currency minimum" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 25,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute changeset.valid?
      assert "must be at least EUR 0.50" in errors_on(changeset).price_cents
    end

    test "accepts price at or above currency minimum" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 5000,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: true
        )

      refute Map.has_key?(errors_on(changeset), :price_cents)
      refute Map.has_key?(errors_on(changeset), :payment_required)
    end

    test "rejects payment_required without connected Stripe" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 5000,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: false
        )

      refute changeset.valid?
      assert "Stripe must be connected" in errors_on(changeset).payment_required
    end

    test "reports both errors when price is missing and Stripe is not connected" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs,
          currency: "eur",
          host_charges_enabled: false
        )

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).price_cents
      assert "Stripe must be connected" in errors_on(changeset).payment_required
    end

    test "defaults currency to usd when opt is omitted" do
      user = insert(:user)

      attrs = %{
        name: "Paid",
        duration_minutes: 30,
        payment_required: true,
        price_cents: 25,
        user_id: user.id
      }

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, attrs, host_charges_enabled: true)

      refute changeset.valid?
      assert "must be at least USD 0.50" in errors_on(changeset).price_cents
    end
  end

  describe "My Paw Trainer service configuration" do
    test "accepts a complete directly bookable service configuration" do
      user = insert(:user)

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Online behavior consultation",
          duration_minutes: 90,
          user_id: user.id,
          service_id: "online-consultation",
          service_price_cents: 14_000,
          service_currency: "usd",
          event_type_version: 1
        })

      assert changeset.valid?
    end

    test "rejects approval-only, unknown, incomplete, and non-USD configurations" do
      user = insert(:user)
      base = %{name: "Service", duration_minutes: 90, user_id: user.id}

      approval =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.put(base, :service_id, "online-case-management")
        )

      unknown =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, Map.put(base, :service_id, "unknown"))

      incomplete =
        MeetingTypeSchema.changeset(
          %MeetingTypeSchema{},
          Map.merge(base, %{service_id: "online-consultation", service_currency: "eur"})
        )

      assert "is not directly bookable" in errors_on(approval).service_id
      assert "is not a valid service" in errors_on(unknown).service_id
      assert "can't be blank" in errors_on(incomplete).service_price_cents
      assert "can't be blank" in errors_on(incomplete).event_type_version
      assert "is invalid" in errors_on(incomplete).service_currency
    end

    test "rejects service configuration fields without a stable service ID" do
      user = insert(:user)

      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Generic meeting",
          duration_minutes: 30,
          user_id: user.id,
          service_price_cents: 4_900,
          service_currency: "usd",
          event_type_version: 1
        })

      assert "is required when service fields are present" in errors_on(changeset).service_id
    end
  end

  describe "versioned My Paw Trainer price updates" do
    alias Tymeslot.MeetingTypes.MeetingTypeQueries

    test "owner may update a future price only at the expected version" do
      user = insert(:user)

      event_type =
        insert(:meeting_type,
          user: user,
          name: "Online behavior consultation",
          duration_minutes: 90,
          service_id: "online-consultation",
          service_price_cents: 14_000,
          service_currency: "usd",
          event_type_version: 1
        )

      assert {:ok, updated} =
               MeetingTypeQueries.update_service_price(event_type.id, user.id, 1, 15_000)

      assert updated.service_price_cents == 15_000
      assert updated.event_type_version == 2

      assert {:error, :stale_version} =
               MeetingTypeQueries.update_service_price(event_type.id, user.id, 1, 16_000)
    end

    test "foreign owner and invalid price are rejected" do
      owner = insert(:user)
      foreign = insert(:user)

      event_type =
        insert(:meeting_type,
          user: owner,
          service_id: "discovery-call",
          service_price_cents: 4_900,
          service_currency: "usd",
          event_type_version: 1
        )

      assert {:error, :not_found} =
               MeetingTypeQueries.update_service_price(event_type.id, foreign.id, 1, 5_000)

      assert {:error, :invalid_price} =
               MeetingTypeQueries.update_service_price(event_type.id, owner.id, 1, 0)
    end
  end
end
