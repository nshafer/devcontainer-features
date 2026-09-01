#!/usr/bin/env python3
"""Tests for `devc stop` and `devc down`. No containers, and no devcontainer CLI.

The engine is a fake `docker` named by DEVC_DOCKER. It answers `ps` from a table of
containers, answers `inspect` with the labels of one of them, and writes every call
to a log. The tests read that log, so what they check is the exact command devc
sends to the engine.

Run it with `make devc-test`, or on its own:  python3 test/devc_test.py
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVC = os.path.join(ROOT, "bin", "devc")

FAKE_DOCKER = '''#!/usr/bin/env python3
import json, os, shlex, sys

args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write(shlex.join(args) + "\\n")
with open(os.environ["FAKE_STATE"], encoding="utf-8") as handle:
    containers = json.load(handle)

if args[:1] == ["compose"]:
    sys.exit(0)

if args[:1] == ["ps"]:
    wanted = [args[i + 1] for i, a in enumerate(args) if a == "--filter"]
    pairs = [w[len("label="):].split("=", 1) for w in wanted if w.startswith("label=")]
    for name, labels in containers.items():
        if all(labels.get(key) == value for key, value in pairs):
            print(name)
    sys.exit(0)

if args[:1] == ["inspect"]:
    print(json.dumps(containers.get(args[-1], {})))
    sys.exit(0)

sys.exit(0)
'''

BASE_CONFIG = '{ "image": "mcr.microsoft.com/devcontainers/base:debian" }\n'
COMPOSE_CONFIG = '{ "dockerComposeFile": "docker-compose.yml", "service": "app" }\n'
OVERRIDE = '{ "remoteUser": "devc" }\n'

failures = []


def check(name, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} {name}")
    if not condition:
        if detail:
            print("     " + detail.replace("\n", "\n     "))
        failures.append(name)


def make_workspace(root, config, override=None):
    folder = os.path.join(root, ".devcontainer")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "devcontainer.json"), "w", encoding="utf-8") as handle:
        handle.write(config)
    if override is not None:
        with open(os.path.join(folder, "devcontainer.local.json"), "w", encoding="utf-8") as handle:
            handle.write(override)
    return root


def run(workspace, containers, *args):
    """Run devc against the fake engine. Return (exit code, stdout, stderr, log)."""
    with tempfile.TemporaryDirectory() as tmp:
        fake = os.path.join(tmp, "docker")
        with open(fake, "w", encoding="utf-8") as handle:
            handle.write(FAKE_DOCKER)
        os.chmod(fake, 0o755)

        state = os.path.join(tmp, "state.json")
        with open(state, "w", encoding="utf-8") as handle:
            json.dump(containers, handle)
        log = os.path.join(tmp, "log.txt")

        env = dict(os.environ, DEVC_DOCKER=fake, FAKE_LOG=log, FAKE_STATE=state, NO_COLOR="1")
        result = subprocess.run(
            [sys.executable, DEVC, "--workspace-folder", workspace, *args],
            capture_output=True, text=True, env=env,
        )
        lines = []
        if os.path.exists(log):
            with open(log, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        return result.returncode, result.stdout, result.stderr, lines


def labels(workspace, config, project=None):
    value = {
        "devcontainer.local_folder": workspace,
        "devcontainer.config_file": os.path.join(workspace, ".devcontainer", config),
    }
    if project:
        value["com.docker.compose.project"] = project
    return value


def main():
    with tempfile.TemporaryDirectory() as home:
        # An image config, no override file. The container goes by id.
        plain = make_workspace(os.path.join(home, "plain"), BASE_CONFIG)
        state = {"c1": labels(plain, "devcontainer.json")}

        code, out, err, log = run(plain, state, "stop")
        check("stop names the base config in the filter",
              any(f"label=devcontainer.config_file={plain}/.devcontainer/devcontainer.json" in line
                  for line in log), "\n".join(log))
        check("stop stops the container by id", "stop c1" in log, "\n".join(log))
        check("stop exits 0", code == 0, err)

        code, out, err, log = run(plain, state, "down")
        check("down removes the container by id", "rm -f c1" in log, "\n".join(log))

        # A compose config. The project label decides, and not the config file.
        comp = make_workspace(os.path.join(home, "comp"), COMPOSE_CONFIG)
        state = {"c2": labels(comp, "devcontainer.json", project="comp_devcontainer")}

        code, out, err, log = run(comp, state, "stop")
        check("compose stop goes through compose",
              "compose -p comp_devcontainer stop" in log, "\n".join(log))
        check("compose stop touches no container by id",
              not any(line.startswith("stop ") for line in log), "\n".join(log))

        code, out, err, log = run(comp, state, "down")
        check("compose down goes through compose",
              "compose -p comp_devcontainer down" in log, "\n".join(log))
        check("compose down keeps the volumes",
              "--volumes" not in " ".join(log), "\n".join(log))

        code, out, err, log = run(comp, state, "down", "--volumes")
        check("down --volumes removes the volumes",
              "compose -p comp_devcontainer down --volumes" in log, "\n".join(log))

        code, out, err, log = run(comp, state, "stop", "--volumes")
        check("stop rejects --volumes", code == 2 and "--volumes" in err, err)

        # Two services of one project, and one call for the project.
        state = {
            "c2": labels(comp, "devcontainer.json", project="comp_devcontainer"),
            "c3": labels(comp, "devcontainer.json", project="comp_devcontainer"),
        }
        code, out, err, log = run(comp, state, "down")
        check("one compose call for two services of a project",
              sum(1 for line in log if line.startswith("compose -p")) == 1, "\n".join(log))

        # An override file, so the label holds the generated config.
        over = make_workspace(os.path.join(home, "over"), BASE_CONFIG, OVERRIDE)
        generated = os.path.join(over, ".devcontainer", "local", "devcontainer.json")
        state = {"c4": labels(over, os.path.join("local", "devcontainer.json"))}

        code, out, err, log = run(over, state, "stop")
        check("an override file points the filter at the generated config",
              any(f"label=devcontainer.config_file={generated}" in line for line in log),
              "\n".join(log))
        check("stop finds the container of the generated config", "stop c4" in log, "\n".join(log))
        check("stop writes no generated config", not os.path.exists(generated))

        # The same workspace, a container from another config. devc stops nothing.
        state = {"c5": labels(over, os.path.join("gpu", "devcontainer.json"))}
        code, out, err, log = run(over, state, "stop")
        check("a container of another config is left alone", code == 1 and "stop c5" not in log, err)
        check("the message names the config it found",
              "gpu/devcontainer.json" in err and "--all-configs" in err, err)

        code, out, err, log = run(over, state, "stop", "--all-configs")
        check("--all-configs stops it", code == 0 and "stop c5" in log, "\n".join(log))
        check("--all-configs drops the config filter",
              not any("label=devcontainer.config_file" in line for line in log), "\n".join(log))

        # Nothing to stop at all.
        code, out, err, log = run(over, {}, "down")
        check("an empty workspace exits 0", code == 0, err)
        check("an empty workspace says so", "No container" in out, out)

        # An unknown flag stops the run rather than reaching the engine.
        code, out, err, log = run(over, {}, "down", "--force")
        check("an unknown flag is rejected", code == 2 and "--force" in err, err)

    print()
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        return 1
    print("devc tests ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
