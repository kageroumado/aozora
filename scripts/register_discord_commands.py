#!/usr/bin/env python3
"""Register Aozora slash commands with the Discord API.

Usage:
    DISCORD_BOT_TOKEN=... DISCORD_APP_ID=... \\
    python3 register_discord_commands.py [--global] [--guild GUILD_ID] [--list] [--clear]

Guild commands propagate instantly; --global commands take up to 1 hour.
Credentials are read from the DISCORD_BOT_TOKEN and DISCORD_APP_ID
environment variables (never hardcode them here).
"""

import argparse
import json
import os
import sys
import urllib.request

BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN") or sys.exit("Set DISCORD_BOT_TOKEN")
APP_ID = os.environ.get("DISCORD_APP_ID") or sys.exit("Set DISCORD_APP_ID")
API_BASE = "https://discord.com/api/v10"
HEADERS = {
    "Authorization": f"Bot {BOT_TOKEN}",
    "Content-Type": "application/json",
    "User-Agent": "DiscordBot (Aozora, 1.0)",
}

COMMANDS = [
    {
        "name": "status",
        "description": "Show daemon status — what the agent is doing right now",
        "type": 1,
    },
    {
        "name": "restart",
        "description": "Restart the Aozora daemon",
        "type": 1,
    },
    {
        "name": "memory",
        "description": "Search and explore conversation memory",
        "type": 1,
        "options": [
            {
                "name": "action",
                "description": "What to do: search, grep, describe, expand",
                "type": 3,
                "required": True,
                "choices": [
                    {"name": "search", "value": "search"},
                    {"name": "grep", "value": "grep"},
                    {"name": "describe", "value": "describe"},
                    {"name": "expand", "value": "expand"},
                ],
            },
            {
                "name": "query",
                "description": "Search query, regex pattern, or node ID(s)",
                "type": 3,
                "required": True,
            },
            {
                "name": "limit",
                "description": "Max results (default 10)",
                "type": 4,
                "required": False,
                "min_value": 1,
                "max_value": 25,
            },
        ],
    },
    {
        "name": "identity",
        "description": "Show current identity claims",
        "type": 1,
    },
    {
        "name": "mirror",
        "description": "Show mirror claims for a user",
        "type": 1,
        "options": [
            {
                "name": "user",
                "description": "User key (default: user)",
                "type": 3,
                "required": False,
            },
        ],
    },
    {
        "name": "config",
        "description": "View or modify configuration",
        "type": 1,
        "options": [
            {
                "name": "action",
                "description": "What to do",
                "type": 3,
                "required": True,
                "choices": [
                    {"name": "show", "value": "show"},
                    {"name": "get", "value": "get"},
                    {"name": "set", "value": "set"},
                    {"name": "reset", "value": "reset"},
                    {"name": "keys", "value": "keys"},
                ],
            },
            {
                "name": "key",
                "description": "Config key (e.g. context.budget)",
                "type": 3,
                "required": False,
            },
            {
                "name": "value",
                "description": "New value (for set)",
                "type": 3,
                "required": False,
            },
        ],
    },
]


def api_request(url: str, method: str = "GET", data: bytes | None = None) -> dict | list:
    headers = dict(HEADERS)
    if method == "GET":
        headers.pop("Content-Type", None)
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def register_commands(url: str, label: str) -> None:
    data = json.dumps(COMMANDS).encode("utf-8")
    try:
        result = api_request(url, "PUT", data)
        print(f"Registered {len(result)} commands ({label})")
        for cmd in result:
            opts = cmd.get("options", [])
            opt_str = ""
            if opts:
                opt_names = [o["name"] for o in opts]
                opt_str = f" [{', '.join(opt_names)}]"
            print(f"  /{cmd['name']}{opt_str}")
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"Failed to register ({label}): {e.code}")
        print(f"  {body[:500]}")
        sys.exit(1)


def list_commands(url: str, label: str) -> None:
    result = api_request(url)
    print(f"Current commands ({label}): {len(result)}")
    for cmd in result:
        print(f"  /{cmd['name']} (id: {cmd['id']})")


def main():
    parser = argparse.ArgumentParser(description="Register Aozora Discord slash commands")
    parser.add_argument("--global", dest="use_global", action="store_true",
                        help="Register global commands")
    parser.add_argument("--guild", default=os.environ.get("DISCORD_GUILD_ID"),
                        help="Guild ID (default: $DISCORD_GUILD_ID)")
    parser.add_argument("--list", action="store_true", help="List current commands")
    parser.add_argument("--clear", action="store_true", help="Clear all commands")
    args = parser.parse_args()

    if not args.use_global and not args.guild:
        parser.error("Provide --guild GUILD_ID (or set DISCORD_GUILD_ID), or use --global")

    if args.use_global:
        url = f"{API_BASE}/applications/{APP_ID}/commands"
        label = "global"
    else:
        url = f"{API_BASE}/applications/{APP_ID}/guilds/{args.guild}/commands"
        label = f"guild {args.guild}"

    if args.list:
        list_commands(url, label)
        return

    if args.clear:
        api_request(url, "PUT", b"[]")
        print(f"Cleared all commands ({label})")
        return

    register_commands(url, label)


if __name__ == "__main__":
    main()
