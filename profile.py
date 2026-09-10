#!/usr/bin/env python3
# PYTHON_ARGCOMPLETE_OK
"""Manages run-remote.sh profiles: JSON files under ~/.local/hack/profiles/,
selectable via `run-remote.sh --profile <name>`."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import argcomplete

VALID_SYNC_LABELS = {"default", "site-package", "push-only"}
PROFILE_DIR = Path.home() / ".local" / "hack" / "profiles"
SECRETS_DIR = PROFILE_DIR / "secrets"

SINGULAR_KEYS = {"venv", "host", "home", "local-home"}
REPEATABLE_KEYS = {"env", "secret", "sync", "include", "dependency", "command"}
VALID_KEYS = SINGULAR_KEYS | REPEATABLE_KEYS

CREATE_USAGE = (
    "%(prog)s <profile-name> [key=value ...] [-- CMD [args...]]\n\n"
    "  venv=NAME              Remote venv name\n"
    "  env=VAR=value          Extra remote env var (repeatable, or comma-separated: env=A=1,B=2)\n"
    "  secret=VAR=value       Extra remote env var kept out of the (git-tracked) profile JSON --\n"
    "                         written to profiles/secrets/<name>.txt (gitignored) instead, and\n"
    "                         merged into the remote env at runtime same as env= (repeatable,\n"
    "                         or comma-separated: secret=A=1,B=2). Given secret= wholly replaces\n"
    "                         the profile's secrets file, same as env=.\n"
    "  host=ALIAS             SSH alias\n"
    "  home=PATH              Remote project root\n"
    "  local-home=PATH        Project directory on this machine (defaults to CWD)\n"
    "  include=NAME           Merge in another profile's keys first (repeatable/comma-separated)\n"
    "  sync=PATH[:LABEL]      Sync map entry, label one of default/site-package/push-only\n"
    "                         (repeatable/comma-separated)\n"
    "  dependency=DIR:UPSTREAM_DIR:HOOK\n"
    "                         Rebuild DIR with HOOK (a shell command) whenever\n"
    "                         UPSTREAM_DIR's HEAD moves (repeatable/comma-separated)\n"
    "  command=ARG            Default remote command argv element (repeatable/comma-separated)\n"
    "  -- CMD [args...]       Default remote command (overrides command=)"
)


def list_profile_names():
    if not PROFILE_DIR.is_dir():
        return []
    return sorted(p.stem for p in PROFILE_DIR.glob("*.json"))


def profile_name_completer(prefix, **_kwargs):
    return [name for name in list_profile_names() if name.startswith(prefix)]


def split_command(argv):
    # argparse's own "--" handling (a pre-REMAINDER special case, unrelated
    # to REMAINDER's usual "everything from here on is literal" behavior)
    # silently swallows a single leading "--" before REMAINDER ever sees it
    # -- confirmed: `create foo -- python x.py` yields rest=['python',
    # 'x.py'], indistinguishable from a bare (no "--") invocation. Splitting
    # argv ourselves, before argparse touches it, sidesteps that entirely.
    if "--" in argv:
        i = argv.index("--")
        return argv[:i], argv[i + 1:]
    return argv, []


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="profile.py")
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    create = subparsers.add_parser(
        "mk",
        usage=CREATE_USAGE,
        help="Create a new profile (refuses if one already exists)",
    )
    create.add_argument("profile_name")
    # subcommand + profile_name are the only true positionals -- everything
    # else is a bare key=value token (no `--flag` prefix needed). The literal
    # `--` (as in git/kubectl) marking where the default command begins is
    # split out of argv before argparse ever runs (see split_command), so by
    # the time REMAINDER sees "rest" it's just kv tokens, never "--" itself.
    create.add_argument("rest", nargs=argparse.REMAINDER, metavar="[key=value ...]")

    mod = subparsers.add_parser(
        "mod",
        usage=CREATE_USAGE,
        help="Create a profile, or update an existing one's changed keys",
    )
    mod.add_argument("profile_name").completer = profile_name_completer
    mod.add_argument("rest", nargs=argparse.REMAINDER, metavar="[key=value ...]")

    subparsers.add_parser("ls", help="List profile names")

    show = subparsers.add_parser("get", help="Print a profile's resolved JSON")
    show.add_argument("profile_name").completer = profile_name_completer

    delete = subparsers.add_parser("rm", help="Delete a profile")
    delete.add_argument("profile_name").completer = profile_name_completer

    argcomplete.autocomplete(parser)
    return parser.parse_args(argv)


def parse_kv_tokens(tokens):
    singular = {}
    repeatable = {key: [] for key in REPEATABLE_KEYS}
    for token in tokens:
        key, sep, value = token.partition("=")
        if not sep:
            print(f"ERROR: expected key=value, got '{token}'", file=sys.stderr)
            sys.exit(1)
        if key not in VALID_KEYS:
            print(f"ERROR: unrecognized key '{key}' "
                  f"(must be one of {', '.join(sorted(VALID_KEYS))})", file=sys.stderr)
            sys.exit(1)
        if key in SINGULAR_KEYS:
            singular[key] = value
        else:
            repeatable[key].extend(value.split(","))
    return singular, repeatable


def build_env(env_args):
    env = {}
    for kv in env_args:
        k, _, v = kv.partition("=")
        env[k] = v
    return env


def build_sync(sync_args):
    sync = {}
    for kv in sync_args:
        path, sep, label = kv.partition(":")
        if not sep:
            label = "default"
        if label not in VALID_SYNC_LABELS:
            print(f"ERROR: invalid sync label '{label}' "
                  f"(must be {', '.join(sorted(VALID_SYNC_LABELS))})", file=sys.stderr)
            sys.exit(1)
        sync[path] = label
    return sync


def build_dependencies(dependency_args):
    dependencies = {}
    for spec in dependency_args:
        sync_dir, sep1, rest = spec.partition(":")
        upstream_dir, sep2, hook = rest.partition(":")
        if not sep1 or not sep2:
            print(f"ERROR: expected dependency=DIR:UPSTREAM_DIR:HOOK, got '{spec}'", file=sys.stderr)
            sys.exit(1)
        dependencies.setdefault(sync_dir, {})[upstream_dir] = hook
    return dependencies


def profile_path(name):
    return PROFILE_DIR / f"{name}.json"


def secrets_path(name):
    return SECRETS_DIR / f"{name}.txt"


def write_secrets(name, secret_args):
    SECRETS_DIR.mkdir(parents=True, exist_ok=True)
    path = secrets_path(name)
    lines = []
    for kv in secret_args:
        k, sep, v = kv.partition("=")
        if not sep:
            print(f"ERROR: expected secret=KEY=VALUE, got 'secret={kv}'", file=sys.stderr)
            sys.exit(1)
        lines.append(f"{k}={v}")
    path.write_text("".join(f"{line}\n" for line in lines))
    return path


def load_profile(name):
    path = profile_path(name)
    if not path.is_file():
        print(f"ERROR: profile '{name}' not found at {path}", file=sys.stderr)
        sys.exit(1)
    return json.loads(path.read_text())


def load_profile_if_exists(name):
    path = profile_path(name)
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def build_own(kv_tokens, command):
    singular, repeatable = parse_kv_tokens(kv_tokens)

    # venv/env/sync are only written when explicitly given -- an omitted key
    # lets an `include`d profile's value show through the latest-wins merge
    # instead of being clobbered by an implicit default. `secret` never goes
    # into `own` at all -- it's written to its own gitignored file by the
    # caller, never merged into the JSON dict.
    own = {}
    if singular.get("venv"):
        own["venv"] = singular["venv"]
    if repeatable["env"]:
        own["env"] = build_env(repeatable["env"])
    if singular.get("host"):
        own["host"] = singular["host"]
    if singular.get("home"):
        own["home"] = singular["home"]
    if singular.get("local-home"):
        own["local-home"] = singular["local-home"]
    # `-- CMD args...` wins over `command=` if both are given, since it's
    # the more explicit form (and can express args containing commas, which
    # command= can't since it splits on them).
    if command:
        own["command"] = command
    elif repeatable["command"]:
        own["command"] = repeatable["command"]
    if repeatable["sync"]:
        own["sync"] = build_sync(repeatable["sync"])
    if repeatable["dependency"]:
        own["dependencies"] = build_dependencies(repeatable["dependency"])
    return own, repeatable["include"], repeatable["secret"]


def write_profile(name, merged):
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    path = profile_path(name)
    path.write_text(json.dumps(merged, indent=2) + "\n")
    return path


def cmd_mk(args):
    path = profile_path(args.profile_name)
    if path.is_file():
        print(f"ERROR: profile '{args.profile_name}' already exists at {path} "
              f"(use 'mod' to update it)", file=sys.stderr)
        sys.exit(1)

    own, includes, secrets = build_own(args.rest, args.command)

    # A brand-new profile starts from an empty base -- `include=` merges in
    # (simple top-level dict update, latest-wins per key, e.g. `env` is
    # replaced wholesale rather than deep-merged) first, and this profile's
    # own explicit keys merge in last so they win over anything included.
    merged = {}
    for inc in includes:
        merged.update(load_profile(inc))
    merged.update(own)

    path = write_profile(args.profile_name, merged)
    print(f"Wrote profile '{args.profile_name}' at {path}")

    if secrets:
        secrets_file = write_secrets(args.profile_name, secrets)
        print(f"Wrote {len(secrets)} secret(s) to {secrets_file}")


def cmd_mod(args):
    # No key=value/include/command args at all -- open the profile's raw
    # JSON in an editor instead of doing a no-op merge.
    if not args.rest and not args.command:
        path = profile_path(args.profile_name)
        PROFILE_DIR.mkdir(parents=True, exist_ok=True)
        if not path.is_file():
            path.write_text("{}\n")
        editor = os.environ.get("EDITOR", "vim")
        subprocess.call([editor, str(path)])
        return

    own, includes, secrets = build_own(args.rest, args.command)

    # A profile that already exists is updated in place, not replaced -- any
    # key this invocation doesn't touch (no matching key=value, no include=
    # redefining it) keeps its previous value. `include=` then merges in on
    # top of that, and this profile's own explicit keys merge in last so
    # they win over both the existing file and anything included.
    merged = load_profile_if_exists(args.profile_name)
    for inc in includes:
        merged.update(load_profile(inc))
    merged.update(own)

    existed = profile_path(args.profile_name).is_file()
    path = write_profile(args.profile_name, merged)

    verb = "Updated" if existed else "Wrote"
    print(f"{verb} profile '{args.profile_name}' at {path}")

    if secrets:
        secrets_file = write_secrets(args.profile_name, secrets)
        print(f"Wrote {len(secrets)} secret(s) to {secrets_file}")


def cmd_ls(_args):
    for name in list_profile_names():
        print(name)


def cmd_get(args):
    profile = load_profile(args.profile_name)
    print(json.dumps(profile, indent=2))


def cmd_rm(args):
    path = profile_path(args.profile_name)
    if not path.is_file():
        print(f"ERROR: profile '{args.profile_name}' not found at {path}", file=sys.stderr)
        sys.exit(1)
    path.unlink()
    print(f"Deleted profile '{args.profile_name}' at {path}")


def main():
    argv, command = split_command(sys.argv[1:])
    args = parse_args(argv)
    args.command = command
    {
        "mk": cmd_mk,
        "mod": cmd_mod,
        "ls": cmd_ls,
        "get": cmd_get,
        "rm": cmd_rm,
    }[args.subcommand](args)


if __name__ == "__main__":
    main()
