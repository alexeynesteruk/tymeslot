.PHONY: check verify help

# Three ways to run quality or release work, depending on where you are.
# Laptop:  make check
# GitHub:  gh workflow run Verify -f suite=check|verify
# Host:    build tymeslot:<sha> on VM 2 and recreate the existing Compose service

help:
	@printf '%s\n' \
	  'Laptop:  make check' \
	  'GitHub:  gh workflow run Verify -f suite=check|verify' \
	  'Host:    docker build -f Dockerfile.mypawtrainer -t tymeslot:<sha> && update /opt/tymeslot/.env'

check:
	mix format --check-formatted
	mix compile --warnings-as-errors

verify:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix test
