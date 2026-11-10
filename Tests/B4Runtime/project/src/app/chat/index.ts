import { agent } from "@b4run/sdk";

const endpoint = new URL(process.env.OPENAI_BASE_URL ?? "");
if (endpoint.hostname !== "127.0.0.1" || endpoint.protocol !== "http:") {
  throw new Error("The fixture route requires an explicit loopback model endpoint.");
}

export default agent({
  model: "gpt-4.1-mini",
  provider: "openai",
  systemPrompt: "You are a deterministic integration-test agent. Follow the fixture instructions.",
  retry: { maxAttempts: 1 },
  tools: { allow: ["fixture_lookup"] },
});
