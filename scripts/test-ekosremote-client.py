#!/usr/bin/env python3
"""Interactive/scripted test client for the EkosRemote WebSocket protocol.

Requires python3-websockets (apt install python3-websockets, or pip install websockets).

Usage:
    scripts/test-ekosremote-client.py [pi-ip] [--repl]

Without --repl: runs the standard startup sequence (set_client_state, get_connection,
get_states, get_profiles) and prints whatever comes back for a few seconds.

With --repl: same startup sequence, then drops into an interactive prompt where you can
type a command name and optional JSON payload to send arbitrary messages, e.g.:
    > profile_start {"name": "Simulators"}
    > get_property {"object": "Capture", "name": "targetName"}
"""
import asyncio
import json
import sys

import websockets

DEFAULT_IP = "10.0.0.43"
PORT = 9000

STARTUP_COMMANDS = [
    ("set_client_state", {"state": True}),
    ("get_connection", {}),
    ("get_states", {}),
    ("get_profiles", {}),
]


async def reader(ws):
    async for msg in ws:
        try:
            parsed = json.loads(msg)
            print("<-", json.dumps(parsed))
        except json.JSONDecodeError:
            print(f"<- <binary {len(msg)} bytes>")


async def send(ws, command, payload):
    frame = json.dumps({"type": command, "payload": payload})
    print("->", frame)
    await ws.send(frame)


async def main():
    args = sys.argv[1:]
    repl = "--repl" in args
    args = [a for a in args if a != "--repl"]
    ip = args[0] if args else DEFAULT_IP

    uri = f"ws://{ip}:{PORT}/message/ekos"
    print(f"Connecting to {uri} ...")
    async with websockets.connect(uri, open_timeout=5) as ws:
        read_task = asyncio.create_task(reader(ws))

        for command, payload in STARTUP_COMMANDS:
            await send(ws, command, payload)
            await asyncio.sleep(0.3)

        if not repl:
            await asyncio.sleep(3)
            read_task.cancel()
            return

        print("\nREPL ready. Type: <command> [json-payload]. Ctrl-D to quit.\n")
        loop = asyncio.get_event_loop()
        while True:
            try:
                line = await loop.run_in_executor(None, input, "> ")
            except EOFError:
                break
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            command = parts[0]
            payload = json.loads(parts[1]) if len(parts) > 1 else {}
            await send(ws, command, payload)

        read_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
