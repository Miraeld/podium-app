/**
 * @file ExternalLink.tsx
 * @description Central helper for cross-origin links so every external link
 * in the app opens consistently: new tab, no opener/referrer leak back to
 * the origin window.
 * @author Gael Robin <robin.gael@gmail.com>
 */

import type { AnchorHTMLAttributes, ReactNode } from "react";

interface ExternalLinkProps extends Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "target" | "rel"> {
  href: string;
  children: ReactNode;
}

export function ExternalLink({ href, children, ...rest }: ExternalLinkProps) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer" {...rest}>
      {children}
    </a>
  );
}
