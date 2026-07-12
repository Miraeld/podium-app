/**
 * @file changelog.tsx
 * @description Minimal, dependency-free renderer for GitHub release-notes
 * markdown (headings, bullet lists, bold/italic/code spans, links, plain
 * paragraphs). Deliberately not a full markdown engine — release notes are a
 * narrow, predictable subset of markdown, and pulling in `react-markdown` +
 * `remark`/`rehype` for a changelog popup is not worth the bundle weight.
 * Renders directly to JSX (no `dangerouslySetInnerHTML`), so there's no XSS
 * surface even though the content comes from GitHub's API.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import type { ReactNode } from "react";

/** Renders inline markdown (bold, italic, code, links) within a line of text. */
function renderInline(text: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  // Order matters: code spans first (so ** inside `code` isn't touched),
  // then links, then bold, then italic.
  const tokens = text.split(/(`[^`]+`|\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*|\*[^*]+\*)/g);
  tokens.forEach((token, i) => {
    if (!token) return;
    const key = `${keyPrefix}-${i}`;
    if (token.startsWith("`") && token.endsWith("`")) {
      nodes.push(
        <code key={key} className="px-1 py-0.5 rounded bg-surface-3 text-[0.85em] font-mono">
          {token.slice(1, -1)}
        </code>
      );
    } else if (token.startsWith("[") && token.includes("](")) {
      const match = token.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (match) {
        nodes.push(
          <a
            key={key}
            href={match[2]}
            target="_blank"
            rel="noreferrer noopener"
            className="text-accent hover:underline"
          >
            {match[1]}
          </a>
        );
      } else {
        nodes.push(token);
      }
    } else if (token.startsWith("**") && token.endsWith("**")) {
      nodes.push(
        <strong key={key} className="font-semibold text-gray-900 dark:text-gray-100">
          {token.slice(2, -2)}
        </strong>
      );
    } else if (token.startsWith("*") && token.endsWith("*")) {
      nodes.push(<em key={key}>{token.slice(1, -1)}</em>);
    } else {
      nodes.push(token);
    }
  });
  return nodes;
}

/**
 * Renders a markdown changelog body as a list of block-level React elements.
 * Supports: `#`/`##`/`###` headings, `-`/`*` bullet lists, blank-line
 * paragraph breaks, and inline formatting within each line.
 */
export function renderChangelog(markdown: string): ReactNode {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let listBuffer: string[] = [];

  const flushList = (key: string) => {
    if (listBuffer.length === 0) return;
    blocks.push(
      <ul key={key} className="list-disc list-inside space-y-1 my-1.5 pl-1">
        {listBuffer.map((item, i) => (
          <li key={i} className="text-sm text-gray-700 dark:text-gray-300">
            {renderInline(item, `li-${key}-${i}`)}
          </li>
        ))}
      </ul>
    );
    listBuffer = [];
  };

  lines.forEach((raw, idx) => {
    const line = raw.trim();
    const key = `b-${idx}`;

    if (line === "") {
      flushList(`${key}-list`);
      return;
    }

    const headingMatch = line.match(/^(#{1,3})\s+(.*)$/);
    if (headingMatch) {
      flushList(`${key}-list`);
      const level = headingMatch[1]!.length;
      const content = renderInline(headingMatch[2]!, key);
      if (level === 1) {
        blocks.push(
          <h4 key={key} className="text-sm font-semibold text-gray-900 dark:text-gray-100 mt-3 first:mt-0">
            {content}
          </h4>
        );
      } else {
        blocks.push(
          <h5 key={key} className="text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-400 mt-3 first:mt-0">
            {content}
          </h5>
        );
      }
      return;
    }

    const bulletMatch = line.match(/^[-*]\s+(.*)$/);
    if (bulletMatch) {
      listBuffer.push(bulletMatch[1]!);
      return;
    }

    flushList(`${key}-list`);
    blocks.push(
      <p key={key} className="text-sm text-gray-700 dark:text-gray-300 my-1">
        {renderInline(line, key)}
      </p>
    );
  });

  flushList("tail-list");
  return blocks;
}
