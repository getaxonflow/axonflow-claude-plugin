#!/usr/bin/env bash
# Under lib/: sourced into scripts that set pipefail, so the idiom here runs
# under it even though this file sets nothing.
agent_ready() {
  curl -s http://127.0.0.1:8080/health | grep -q healthy   # EXPECT
}
