# Uploads a built place to Roblox and runs a Luau script against it via the
# Open Cloud Luau execution API, streaming the logs back and exiting non-zero
# if the task fails.
#
# Usage: python3 scripts/upload_and_run_task.py <place file> <task script file>
# Env:   ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID
#
# Adapted from Roblox/place-ci-cd-demo (MIT License, Copyright (c) 2024 Roblox).

import json
import os
import sys
import urllib.request

from luau_execution_task import createTask, getTaskLogs, pollForTaskCompletion

ROBLOX_API_KEY = os.environ["ROBLOX_API_KEY"]
ROBLOX_UNIVERSE_ID = os.environ["ROBLOX_UNIVERSE_ID"]
ROBLOX_PLACE_ID = os.environ["ROBLOX_PLACE_ID"]


def read_file(file_path):
    with open(file_path, "rb") as file:
        return file.read()


def upload_place(binary_path, universe_id, place_id, do_publish=False):
    print("Uploading place to Roblox")
    version_type = "Published" if do_publish else "Saved"
    request_headers = {
        "x-api-key": ROBLOX_API_KEY,
        "Content-Type": "application/octet-stream",
        "Accept": "application/json",
    }

    url = f"https://apis.roblox.com/universes/v1/{universe_id}/places/{place_id}/versions?versionType={version_type}"

    buffer = read_file(binary_path)
    req = urllib.request.Request(
        url, data=buffer, headers=request_headers, method="POST"
    )

    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode("utf-8"))
        place_version = data.get("versionNumber")

        print(f"Uploaded place version {place_version}")
        return place_version


def run_luau_task(universe_id, place_id, place_version, script_file):
    print("Executing Luau task")
    script_contents = read_file(script_file).decode("utf8")

    task = createTask(
        ROBLOX_API_KEY, script_contents, universe_id, place_id, place_version
    )
    task = pollForTaskCompletion(ROBLOX_API_KEY, task["path"])
    logs = getTaskLogs(ROBLOX_API_KEY, task["path"])

    print(logs)

    if task["state"] == "COMPLETE":
        print("Luau task completed successfully")
        exit(0)
    else:
        print("Luau task failed", file=sys.stderr)
        if task.get("error"):
            print(json.dumps(task["error"]), file=sys.stderr)
        exit(1)


if __name__ == "__main__":
    binary_file = sys.argv[1]
    script_file = sys.argv[2]

    place_version = upload_place(binary_file, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID)
    run_luau_task(ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID, place_version, script_file)