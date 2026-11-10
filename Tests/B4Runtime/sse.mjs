export async function* parseEvents(body) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let pending = '';
  for await (const chunk of body) {
    pending = (pending + decoder.decode(chunk, { stream: true })).replace(/\r\n/g, '\n');
    let boundary;
    while ((boundary = pending.indexOf('\n\n')) >= 0) {
      const frame = pending.slice(0, boundary);
      pending = pending.slice(boundary + 2);
      const lines = frame.split('\n');
      const event = lines.find((line) => line.startsWith('event:'))?.slice(6).trim();
      const data = lines.filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trimStart()).join('\n');
      if (event && data) yield { event, data: JSON.parse(data) };
    }
  }
  pending += decoder.decode();
  if (pending.trim()) throw new Error(`Truncated SSE frame: ${pending}`);
}
