/**
 * @file AlertsNotifications.test.tsx
 * @description Tests for the Alerts control-center embedded in Settings: tab
 * rendering, the empty rules state, switching to the webhook Channels tab, and
 * the create-rule flow calling the alerts API with the built config. The API
 * module is mocked so no network is touched.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { AlertsNotifications } from "../AlertsNotifications";
import type { AlertRule } from "../../lib/types";

// ── Mock API ──────────────────────────────────────────────────────────────────

const rulesList = vi.fn();
const rulesCreate = vi.fn();
const alertsList = vi.fn();
const webhooksList = vi.fn();
const webhooksProviders = vi.fn();

vi.mock("../../lib/api", () => ({
  api: {
    alerts: {
      rules: {
        list: () => rulesList(),
        create: (data: unknown) => rulesCreate(data),
        update: vi.fn(() => Promise.resolve({ rule: {} })),
        remove: vi.fn(() => Promise.resolve({ ok: true })),
      },
      list: () => alertsList(),
      ack: vi.fn(() => Promise.resolve({ alert: {} })),
      ackAll: vi.fn(() => Promise.resolve({ ok: true, acknowledged: 0 })),
    },
    webhooks: {
      providers: () => webhooksProviders(),
      list: () => webhooksList(),
      create: vi.fn(),
      update: vi.fn(),
      remove: vi.fn(),
      test: vi.fn(),
      deliveries: vi.fn(),
    },
  },
}));

function renderHub() {
  return render(
    <MemoryRouter>
      <AlertsNotifications />
    </MemoryRouter>
  );
}

const emptyAlerts = { alerts: [], total: 0, unacked: 0, limit: 25, offset: 0 };

describe("AlertsNotifications", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    rulesList.mockResolvedValue({ rules: [] as AlertRule[] });
    alertsList.mockResolvedValue(emptyAlerts);
    webhooksList.mockResolvedValue({ targets: [] });
    webhooksProviders.mockResolvedValue({ providers: [] });
    rulesCreate.mockResolvedValue({ rule: {} });
  });

  it("renders the three tabs", async () => {
    renderHub();
    expect(screen.getByText("Rules")).toBeInTheDocument();
    expect(screen.getByText("Channels")).toBeInTheDocument();
    expect(screen.getByText("Activity")).toBeInTheDocument();
    await waitFor(() => expect(rulesList).toHaveBeenCalled());
  });

  it("shows the add-rule control on the Rules tab", async () => {
    renderHub();
    expect(await screen.findByText("Add rule")).toBeInTheDocument();
  });

  it("switches to the Channels tab and mounts webhook settings", async () => {
    renderHub();
    fireEvent.click(screen.getByText("Channels"));
    // WebhookSettings fetches targets + providers on mount.
    await waitFor(() => expect(webhooksList).toHaveBeenCalled());
    expect(await screen.findByText("Add Webhook")).toBeInTheDocument();
  });

  it("creates a rule with the built config", async () => {
    renderHub();
    fireEvent.click(await screen.findByText("Add rule"));

    // Rule name is required; event_pattern also needs at least one pattern field.
    fireEvent.change(screen.getByPlaceholderText("e.g. Error burst"), {
      target: { value: "Bash errors" },
    });
    fireEvent.change(screen.getByPlaceholderText("PostToolUse"), {
      target: { value: "PostToolUse" },
    });

    fireEvent.click(screen.getByText("Create rule"));

    await waitFor(() => expect(rulesCreate).toHaveBeenCalledTimes(1));
    const arg = rulesCreate.mock.calls[0]![0];
    expect(arg).toMatchObject({
      name: "Bash errors",
      rule_type: "event_pattern",
      config: { event_type: "PostToolUse", count: 1 },
    });
  });
});
