defmodule Tymeslot.Contracts.AgentDocsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "current docs contain the approved scheduler contract" do
    docs =
      ["AGENTS.md", "docs/agent/REQUIREMENTS.md", "docs/agent/IMPLEMENTATION_PLAN.md"]
      |> Enum.map(&File.read!(Path.join(@root, &1)))
      |> Enum.join("\n")

    required_terms = [
      "discovery-call",
      "online-consultation",
      "in-home-consultation",
      "$49",
      "$140",
      "$190",
      "setup mode",
      "ZIP",
      "follow-up",
      "cancellation requests go to Anna by email"
    ]

    for required <- required_terms do
      assert docs =~ required, "missing approved scheduler requirement: #{required}"
    end

    refute docs =~ "$120 online behavior consultation"
    refute docs =~ "In-home consultations remain manually reviewed through the website"
  end
end
