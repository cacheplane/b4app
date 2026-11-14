import { appendFile } from "node:fs/promises";

export const description = "A tool the fixture project's permissions refuse; it must never run.";
export const display = {
  icon: "lock",
  running: () => "Running the guarded tool",
  done: () => "Guarded tool complete",
};

export default async function fixtureGuarded(input: { readonly query: string }) {
  const ledger = process.env.B4APP_FIXTURE_TOOL_LOG;
  if (!ledger) throw new Error("Missing fixture tool ledger");
  await appendFile(ledger, JSON.stringify({ guarded: input }) + "\n");
  return { answer: "guarded-value" };
}
