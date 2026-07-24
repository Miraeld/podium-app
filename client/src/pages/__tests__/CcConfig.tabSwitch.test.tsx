/**
 * @file CcConfig.tabSwitch.test.tsx
 * @description Regression test for a crash when switching between Config
 * Explorer tabs. `MdItemList` (shared by the skills/agents/commands/
 * outputStyles tabs) used to call `useState` after two conditional early
 * returns, which violates the Rules of Hooks: since the component is
 * reused at the same position across tab switches, a hook called on some
 * renders but not others desyncs React's hook order and throws (React
 * error #310). This test switches between a tab with an empty list and a
 * tab with items — the exact transition that used to crash — and asserts
 * the page keeps rendering.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { CcConfig } from "../CcConfig";
import { api } from "../../lib/api";
import type { CcMdItem, CcOverview } from "../../lib/api";

// jsdom has no ResizeObserver; the Tabs component uses one purely for
// scroll-affordance UI, unrelated to the bug under test.
class FakeResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
(globalThis as any).ResizeObserver = FakeResizeObserver;
// jsdom also has no scrollBy/getBoundingClientRect scroll geometry; the
// Tabs component only uses it for scroll-into-view UI polish.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
(Element.prototype as any).scrollBy = () => {};

vi.mock("../../lib/api", () => ({
  api: {
    ccConfig: {
      overview: vi.fn(),
      skills: vi.fn(),
      agents: vi.fn(),
      commands: vi.fn(),
      outputStyles: vi.fn(),
      plugins: vi.fn(),
      marketplaces: vi.fn(),
      mcp: vi.fn(),
      hooks: vi.fn(),
      keybindings: vi.fn(),
      settings: vi.fn(),
      memory: vi.fn(),
      statusline: vi.fn(),
      hookScripts: vi.fn(),
    },
  },
}));

function makeMdItem(overrides: Partial<CcMdItem> = {}): CcMdItem {
  return {
    scope: "user",
    name: "example",
    file: "/home/user/.claude/agents/example.md",
    size: 100,
    mtime: 0,
    truncated: false,
    frontmatter: {},
    preview: "# Example",
    ...overrides,
  };
}

const overview: CcOverview = {
  roots: {
    claudeHome: "/home/user/.claude",
    projectClaudeDir: "/repo/.claude",
    projectRoot: "/repo",
    claudeJson: "/home/user/.claude.json",
  },
  counts: {
    skills: { user: 0, project: 0 },
    agents: { user: 1, project: 0 },
    commands: { user: 0, project: 0 },
    outputStyles: { user: 0, project: 0 },
    plugins: 0,
    pluginsEnabled: 0,
    pluginsDisabled: 0,
    marketplaces: 0,
    keybindings: 0,
    mcpServers: { user: 0, project: 0 },
    hooks: {},
    memory: 0,
    settingsFiles: 0,
  },
};

describe("CcConfig — tab switching", () => {
  it("switches from an empty tab (skills) to a populated tab (agents) without crashing", async () => {
    const mockedApi = vi.mocked(api.ccConfig);
    mockedApi.overview.mockResolvedValue(overview);
    // Skills: empty list → MdItemList takes the early-return "Empty" path.
    mockedApi.skills.mockResolvedValue({ items: [] });
    // Agents: non-empty list → MdItemList falls through to the
    // `userCollapsed` state (the hook that used to be called conditionally).
    mockedApi.agents.mockResolvedValue({ items: [makeMdItem({ name: "reviewer" })] });
    mockedApi.commands.mockResolvedValue({ items: [] });
    mockedApi.outputStyles.mockResolvedValue({ items: [] });
    mockedApi.plugins.mockResolvedValue({ manifestPath: "", manifestExists: false, plugins: [] });
    mockedApi.marketplaces.mockResolvedValue({ marketplaces: [] } as never);
    mockedApi.mcp.mockResolvedValue({ user: [], projectScoped: [] });
    mockedApi.hooks.mockResolvedValue({ items: [] });
    mockedApi.keybindings.mockResolvedValue({ bindings: [] } as never);
    mockedApi.settings.mockResolvedValue({ items: [] });
    mockedApi.memory.mockResolvedValue({ items: [] });
    mockedApi.statusline.mockResolvedValue({ configured: false } as never);
    mockedApi.hookScripts.mockResolvedValue({ scripts: [] } as never);

    render(<CcConfig />);

    // Wait for the initial fetch to resolve.
    await waitFor(() => expect(mockedApi.overview).toHaveBeenCalled());

    const skillsTab = await screen.findByRole("button", { name: /skills/i });
    const agentsTab = screen.getByRole("button", { name: /agents/i });

    // Go to the empty tab first, then to the populated one — this is the
    // transition that used to throw "Rendered more hooks than during the
    // previous render" because `useState` sat after two early returns.
    fireEvent.click(skillsTab);
    await waitFor(() => expect(screen.queryByText(/reviewer/)).not.toBeInTheDocument());

    fireEvent.click(agentsTab);
    await waitFor(() => expect(screen.getByText("reviewer")).toBeInTheDocument());

    // And back again, to exercise the reverse transition too.
    fireEvent.click(skillsTab);
    await waitFor(() => expect(screen.queryByText("reviewer")).not.toBeInTheDocument());
  });
});
