/**
 * @file Tests for statusFromEventType — regression coverage for the "waiting"
 * pill that kept blinking on already-completed tool calls (GH #3). The bug
 * was that PostToolUse (a tool call's completion event) mapped to "waiting"
 * instead of "completed", so EventGroupRow's Pre/Post status sequence never
 * reached a non-pulsing terminal state.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { describe, it, expect } from "vitest";
import { statusFromEventType } from "../event-grouping";

describe("statusFromEventType", () => {
  it("marks a tool call's start as working", () => {
    expect(statusFromEventType("PreToolUse")).toBe("working");
  });

  it("marks a tool call's completion as completed, not waiting", () => {
    expect(statusFromEventType("PostToolUse")).toBe("completed");
  });

  it("still marks a genuine turn-end (Stop) as waiting", () => {
    expect(statusFromEventType("Stop")).toBe("waiting");
  });

  it("marks subagent completion and compaction as completed", () => {
    expect(statusFromEventType("SubagentStop")).toBe("completed");
    expect(statusFromEventType("Compaction")).toBe("completed");
  });

  it("marks error-type events as error", () => {
    expect(statusFromEventType("error")).toBe("error");
    expect(statusFromEventType("APIError")).toBe("error");
  });
});
