# Connections and B4 projects

The help behind each ⓘ in Settings. Every section answers one field.

## Status

Each connection and B4 project shows its state as an icon. Hover over it, or use VoiceOver, to hear it in words.

- A check in a dark circle means connected.
- A turning ring means a check is running. When the server doesn't answer, the check tries three times, a second and then three seconds apart, and the line under the name says which try it is on.
- A red "!" means it needs you: the sign-in expired, the server can't be reached, the runtime needs an update, or the plan's limit is reached. The line under the name says which.
- An empty ring means it hasn't been checked yet.

## Usage

Codex and Claude show the plan's two windows: the 5-hour window and the weekly window. Each has the share used and the time until it resets. A window turns red at 90%.

- Codex reports its windows whenever the app asks, so they're current after every check.
- Claude reports them only while it's working. The card says how old the reading is, and shows nothing until the first turn.

B4 has no plan limits. Its card shows the tokens its turns used today and this week (the week starts on Monday).

Usage stays on your Mac: the phone shows each connection's status but not its usage.

## Server

The address of your B4 server, such as `https://agents.example.com`. A server on this Mac can use `http://127.0.0.1:<port>` or `http://localhost:<port>`. Anything else must use HTTPS.

## Agent

The route your B4 server exposes for the agent, such as `/chat#agent`. Only agent routes can hold a conversation.

A connection is one server and one agent. To talk to another server or another agent, add another connection; your existing threads stay with the connection they started on.

## API key

If your B4 server checks a bearer token, enter it here. The app keeps it in your Keychain and sends it only to this connection's server.

Once saved, the key is never shown again. In Edit you can replace it or remove it. A key no other connection uses is deleted from the Keychain when you replace or remove it.

## B4 project folder

A B4 project is a B4 app on this Mac that the app runs for you. Choose the folder that holds its `b4.config`.

Attaching runs the project's code: the app runs its config and routes with Node to find its agents, and starting it runs its server. Attach only projects you trust.

## Mode

- **Dev** runs `b4 dev`, which reloads when you save a file. A reload can replace the runtime in the middle of a turn.
- **Source** runs `b4 start`, which doesn't reload.

## Port

The port the project's server listens on, on `127.0.0.1` only. Leave it empty and the app picks a free port once, when you attach the project, and keeps it.

## Env file

A file of environment variables for the project's server. It defaults to `<project>/.env` when that file exists.

The app passes the file to the server and never reads it itself.
