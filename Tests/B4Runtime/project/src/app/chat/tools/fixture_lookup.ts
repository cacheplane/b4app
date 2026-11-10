import { appendFile } from "node:fs/promises";

export const description = "Look up the harmless integration fixture value.";
export const display = {
  icon: "search",
  running: () => "Checking fixture data",
  done: () => "Fixture lookup complete",
};

export default async function fixtureLookup(input: { readonly query: string }) {
  const ledger = process.env.B4APP_FIXTURE_TOOL_LOG;
  if (!ledger) throw new Error("Missing fixture tool ledger");
  await appendFile(ledger, JSON.stringify(input) + "\n");
  return { answer: "fixture-value" };
}
