/**
 * @file webhookGuides.ts
 * @description Official-docs URLs per webhook provider, shown alongside the
 * step-by-step setup guide in the webhook form. The steps themselves are
 * localized in the i18n `settings` namespace (`webhookGuides.<type>.steps`);
 * URLs aren't translated so they live here.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import type { WebhookType } from "../lib/types";

export const WEBHOOK_DOCS: Partial<Record<WebhookType, string>> = {
  slack: "https://api.slack.com/messaging/webhooks",
  discord: "https://support.discord.com/hc/en-us/articles/228383668",
  teams: "https://learn.microsoft.com/en-us/microsoftteams/platform/workflow",
  google_chat: "https://developers.google.com/workspace/chat/quickstart/webhooks",
  mattermost: "https://developers.mattermost.com/integrate/webhooks/incoming/",
  rocketchat: "https://docs.rocket.chat/docs/integrations",
  telegram: "https://core.telegram.org/bots#how-do-i-create-a-bot",
  pagerduty: "https://support.pagerduty.com/docs/services-and-integrations",
  opsgenie: "https://support.atlassian.com/opsgenie/docs/create-a-default-api-integration/",
  splunk_oncall: "https://help.victorops.com/knowledge-base/rest-endpoint-integration-guide/",
  zapier: "https://zapier.com/apps/webhook/integrations",
  make: "https://www.make.com/en/help/tools/webhooks",
  n8n: "https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/",
  pipedream: "https://pipedream.com/docs/workflows/triggers/",
};
