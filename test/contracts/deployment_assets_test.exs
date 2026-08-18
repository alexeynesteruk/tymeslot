defmodule Tymeslot.Contracts.DeploymentAssetsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "ARM64 application image is non-root and exposes a healthy release on port 4000" do
    dockerfile = read!("Dockerfile.mypawtrainer")

    assert dockerfile =~
             "FROM hexpm/elixir:1.20.3-erlang-28.5.0.5-debian-trixie-20260803-slim AS build"

    assert dockerfile =~ "FROM debian:trixie-slim AS release"
    assert dockerfile =~ "DEPLOYMENT_TYPE=docker"
    assert dockerfile =~ "USER app"
    refute dockerfile =~ "USER root"
    assert dockerfile =~ "EXPOSE 4000"
    assert dockerfile =~ "HEALTHCHECK"
    assert dockerfile =~ "http://127.0.0.1:4000/healthcheck"
    assert dockerfile =~ "bin/tymeslot eval"
    assert dockerfile =~ "Ecto.Migrator.run"
    assert dockerfile =~ "bin/tymeslot start"

    refute Regex.match?(~r/COPY\s+.*(?:\.env|\.secret)/i, dockerfile)
  end

  test "image workflow builds only linux arm64 with an immutable commit SHA tag" do
    workflow = read!(".github/workflows/mypawtrainer-image.yml")

    assert workflow =~ "Dockerfile.mypawtrainer"
    assert workflow =~ "platforms: linux/arm64"
    assert workflow =~ ~S(tags: ghcr.io/alexeynesteruk/tymeslot:${{ github.sha }})
    assert workflow =~ "workflow_dispatch:"
    refute Regex.match?(~r/^on:\n  push:/m, workflow)
    refute Regex.match?(~r/tags:.*:latest/, workflow)
    refute workflow =~ "secrets."
    refute workflow =~ "ssh"
    refute workflow =~ "deploy"
  end

  test "verify workflow keeps the full suite behind an explicit verify choice" do
    workflow = read!(".github/workflows/verify.yml")
    makefile = read!("Makefile")

    assert workflow =~ "workflow_dispatch:"
    assert workflow =~ "- check"
    assert workflow =~ "- verify"
    assert workflow =~ "inputs.suite == 'verify'"
    assert makefile =~ "Laptop:"
    assert makefile =~ "GitHub:"
    assert makefile =~ "Host:"
    assert makefile =~ "make check"
  end

  test "platform interface documents runtime names and operational contracts without values" do
    platform = read!("docs/agent/PLATFORM.md")

    for name <- [
          "PHX_HOST",
          "SECRET_KEY_BASE",
          "DATABASE_URL",
          "DATABASE_HOST",
          "DATABASE_PORT",
          "DATABASE_POOL_SIZE",
          "POSTGRES_DB",
          "POSTGRES_USER",
          "POSTGRES_PASSWORD",
          "GOOGLE_CLIENT_ID",
          "GOOGLE_CLIENT_SECRET",
          "STRIPE_SECRET_KEY",
          "STRIPE_WEBHOOK_SECRET",
          "STRIPE_CONNECT_WEBHOOK_SECRET",
          "PRICE_PROJECTION_DELIVERY_ENABLED",
          "PRICE_PROJECTION_URL",
          "PRICE_PROJECTION_SECRET",
          "CRM_PROJECTION_DELIVERY_ENABLED",
          "CRM_PROJECTION_URL",
          "CRM_PROJECTION_SECRET",
          "REGISTRATION_ENABLED",
          "MEETING_PAYMENTS_ENABLED"
        ] do
      assert platform =~ "`#{name}`"
      refute Regex.match?(~r/`#{name}`\s*=\s*\S+/, platform)
    end

    assert platform =~ "`/app/data`"
    assert platform =~ "`GET /healthcheck`"
    assert platform =~ "liveness and readiness"
    assert platform =~ "one-shot migration"
    assert platform =~ "bin/tymeslot eval"
    assert platform =~ "AGPL-3.0"
    assert platform =~ "ghcr.io/alexeynesteruk/tymeslot:<40-character-git-sha>"
  end

  test "host operations assets remain outside the public application repository" do
    forbidden = [
      "docker-compose.mypawtrainer.yml",
      "compose.mypawtrainer.yml",
      "deployment/nginx/book.mypawtrainer.conf",
      "deployment/ssh_known_hosts",
      "scripts/deploy-mypawtrainer.sh",
      "scripts/rollback-mypawtrainer.sh",
      "scripts/backup-postgres.sh",
      "scripts/restore-postgres.sh",
      "systemd/tymeslot.service",
      ".github/workflows/mypawtrainer-deploy.yml"
    ]

    for path <- forbidden do
      refute File.exists?(Path.join(@root, path)), "host asset must not exist: #{path}"
    end
  end

  defp read!(path), do: File.read!(Path.join(@root, path))
end
