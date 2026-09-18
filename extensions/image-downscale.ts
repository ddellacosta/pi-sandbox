/**
 * Image Downscale
 *
 * Pi's built-in image handling resizes to 2000x2000 and allows up to 4.5 MB of
 * base64 (DEFAULT_MAX_BYTES). That is far too large for the Pi sandbox's
 * console transport: a ~1.5 MB PNG becomes ~2 MB of Kitty graphics escape
 * sequences, which stalls the VM and usually fails to paint at all (Pi reserves
 * the image rows but the terminal never draws the picture).
 *
 * This extension hooks `tool_result` and downscales any image content before it
 * is displayed or persisted. That keeps:
 *   - the Kitty payload small enough to render reliably,
 *   - the session JSONL small (Pi otherwise stores the full base64 image),
 *   - the model context small.
 *
 * Tune with environment variables:
 *   PI_IMAGE_MAX_WIDTH   (default 384)
 *   PI_IMAGE_MAX_HEIGHT  (default 384)
 *   PI_IMAGE_MAX_BYTES   (default 40000, base64 length)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { resizeImage } from "@earendil-works/pi-coding-agent";

const MAX_WIDTH = Number(process.env.PI_IMAGE_MAX_WIDTH ?? 384);
const MAX_HEIGHT = Number(process.env.PI_IMAGE_MAX_HEIGHT ?? 384);
const MAX_BYTES = Number(process.env.PI_IMAGE_MAX_BYTES ?? 40_000);

interface ContentBlock {
  type: string;
  data?: string;
  mimeType?: string;
  [key: string]: unknown;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", async (event) => {
    const blocks = event.content as ContentBlock[] | undefined;
    if (!Array.isArray(blocks)) return;
    if (!blocks.some((b) => b.type === "image" && b.data && b.mimeType)) return;

    let changed = false;
    const next: ContentBlock[] = [];

    for (const block of blocks) {
      if (block.type !== "image" || !block.data || !block.mimeType) {
        next.push(block);
        continue;
      }

      try {
        const bytes = new Uint8Array(Buffer.from(block.data, "base64"));
        const resized = await resizeImage(bytes, block.mimeType, {
          maxWidth: MAX_WIDTH,
          maxHeight: MAX_HEIGHT,
          maxBytes: MAX_BYTES,
        });

        if (resized && resized.data.length < block.data.length) {
          next.push({ type: "image", data: resized.data, mimeType: resized.mimeType });
          changed = true;
          continue;
        }
      } catch {
        // Any failure: keep the original image rather than losing it.
      }

      next.push(block);
    }

    if (!changed) return;
    return { content: next };
  });
}
