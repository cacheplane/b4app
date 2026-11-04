## 2026-11-01 (sign-in: Sign in with Apple on the hub)

- **D-091 The web flow's client id is a new optional `B4HUB_APPLE_SERVICES_ID`, and the native flow's is the identity token's audience.** Telling the bundle id from the Services ID by their shape would break the day either changes form. Without the variable (or `B4HUB_PUBLIC_URL`) the hub offers only the native flow. Each refresh token is sealed together with the client id it was issued to, because revoking needs that client id; the seal's associated data is the identity row's id.
